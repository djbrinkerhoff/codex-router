import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

// The native macOS Control Center (apps/macos/ControlCenter) has no
// JavaScript engine, so nothing in the Electron test suite reaches it. These
// checks hold the two contracts it shares with the Electron window: the
// operation set, and the display copy.

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const NATIVE = path.join(ROOT, "apps", "macos", "ControlCenter");
const ELECTRON = path.join(ROOT, "apps", "control-center", "electron");
const WINDOW_VERBS = new Set(["minimizeWindow", "toggleMaximizeWindow", "closeWindow"]);

function swiftSources(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const candidate = path.join(directory, entry.name);
    if (entry.isDirectory()) return swiftSources(candidate);
    return entry.name.endsWith(".swift") ? [candidate] : [];
  });
}

function preloadOperations() {
  const preload = readFileSync(path.join(ELECTRON, "preload.cjs"), "utf8");
  return new Set([...preload.matchAll(/call\("([A-Za-z]+)"/g)].map((match) => match[1]));
}

function nativeOperations() {
  const control = readFileSync(
    path.join(NATIVE, "Sources", "ControlCenterCore", "RouterControl.swift"),
    "utf8",
  );
  return new Set([...control.matchAll(/call\("([A-Za-z]+)"/g)].map((match) => match[1]));
}

test("the native RouterControl offers exactly the preload's router operations", () => {
  const preload = preloadOperations();
  const native = nativeOperations();
  const expected = [...preload].filter((name) => !WINDOW_VERBS.has(name)).sort();
  assert.deepEqual([...native].sort(), expected);
});

test("every native operation is one ipc.mjs registers for the bridge", () => {
  const ipc = readFileSync(path.join(ELECTRON, "ipc.mjs"), "utf8");
  const registered = new Set(
    [...ipc.matchAll(/handle(?:Action)?\("([A-Za-z]+)"/g)].map((match) => match[1]),
  );
  for (const name of nativeOperations()) {
    assert.ok(registered.has(name), `${name} is registered by ipc.mjs`);
  }
});

test("native pages call only RouterControl, never a process or the file system", () => {
  const app = path.join(NATIVE, "Sources", "ControlCenter");
  for (const file of swiftSources(app)) {
    const source = readFileSync(file, "utf8");
    const relative = path.relative(ROOT, file);
    assert.doesNotMatch(source, /\bProcess\(\)|NSTask|posix_spawn|\/bin\/sh|\/usr\/bin\/env/, `${relative} spawns nothing`);
    assert.doesNotMatch(source, /\.call\("/, `${relative} uses the typed RouterControl methods`);
    // Credentials cross the bridge once, through saveProviderCredential or
    // addCustomEndpoint; a page must never print or persist one.
    assert.doesNotMatch(source, /UserDefaults[^\n]*(?:credential|apiKey|secret)/i, `${relative} persists no credential`);
    assert.doesNotMatch(source, /\bprint\([^\n]*(?:credential|apiKey|secret)/i, `${relative} logs no credential`);
  }
});

test("native string catalogs match the renderer's locale modules", () => {
  const result = spawnSync(
    process.execPath,
    [path.join(NATIVE, "scripts", "generate-strings.mjs"), "--check"],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
});

test("the native bundle keeps the Electron window's lifecycle contract", () => {
  const plist = readFileSync(path.join(NATIVE, "Resources", "Info.plist"), "utf8");
  assert.match(plist, /<key>CFBundleIdentifier<\/key>\s*<string>io\.github\.codex-router\.control-center<\/string>/);
  assert.match(plist, /<key>CFBundleExecutable<\/key>\s*<string>Codex Router<\/string>/);
  const main = readFileSync(path.join(NATIVE, "Sources", "ControlCenter", "ControlCenterMain.swift"), "utf8");
  assert.match(main, /LifecycleState\.queryArgument/);
  assert.match(main, /--quit-for-update/);
  const delegate = readFileSync(path.join(NATIVE, "Sources", "ControlCenter", "AppDelegate.swift"), "utf8");
  assert.match(delegate, /--tray-only/);
  assert.match(delegate, /CODEX_ROUTER_EMBEDDED_CONTROL_CENTER/);
  const lifecycle = readFileSync(path.join(NATIVE, "Sources", "ControlCenterCore", "LifecycleState.swift"), "utf8");
  assert.match(lifecycle, /queryArgument = "--query-lifecycle"/);
  assert.match(lifecycle, /control-center-lifecycle\.json/);
  assert.match(lifecycle, /MODEL_ROUTER_CONTROL_CENTER_STATE/);
  const build = readFileSync(path.join(ROOT, "scripts", "build-macos-control-center.sh"), "utf8");
  assert.match(build, /cp "\$binary_dir\/ControlCenter" "\$contents\/MacOS\/Codex Router"/);
  assert.match(build, /bridge\/apps\/control-center\/electron\/native-bridge\.mjs/);
  assert.match(build, /generate-strings\.mjs" --check/);
});
