import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  MAX_REQUEST_BYTES,
  NATIVE_BRIDGE_PROTOCOL,
  createNativeBridge,
  createPlatformShell,
} from "../apps/control-center/electron/native-bridge.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BRIDGE = path.join(ROOT, "apps", "control-center", "electron", "native-bridge.mjs");

function fakeRegistrar(register) {
  let captured;
  const registerIpcHandlers = (options) => {
    captured = options;
    register(options);
    return { whenMutationsIdle: () => Promise.resolve() };
  };
  return { registerIpcHandlers, options: () => captured };
}

function collector() {
  const lines = [];
  return {
    write: (chunk) => {
      for (const line of chunk.split("\n")) if (line) lines.push(JSON.parse(line));
    },
    lines,
  };
}

test("native bridge exposes registered operations except the window verbs", async () => {
  const out = collector();
  const { registerIpcHandlers } = fakeRegistrar(({ ipcMain }) => {
    ipcMain.handle("router-control:getProviders", async () => ({ providers: [] }));
    ipcMain.handle("router-control:minimizeWindow", async () => ({ ok: true }));
    ipcMain.handle("router-control:closeWindow", async () => ({ ok: true }));
    ipcMain.handle("router-control:toggleMaximizeWindow", async () => ({ ok: true }));
    ipcMain.handle("unrelated:channel", async () => "never");
  });
  const bridge = createNativeBridge({ registerIpcHandlers, write: out.write });
  assert.deepEqual(bridge.methods, ["getProviders"]);
  bridge.announce();
  assert.deepEqual(out.lines[0], { event: "ready", protocol: NATIVE_BRIDGE_PROTOCOL, methods: ["getProviders"] });
  await bridge.dispatch(JSON.stringify({ id: 4, method: "closeWindow" }));
  assert.deepEqual(out.lines.at(-1), { id: 4, ok: false, error: "Unknown Control Center operation." });
});

test("native bridge forwards params verbatim and relays results and errors", async () => {
  const out = collector();
  const seen = [];
  const { registerIpcHandlers } = fakeRegistrar(({ ipcMain }) => {
    ipcMain.handle("router-control:saveProviderCredential", async (_event, input) => {
      seen.push(input);
      return undefined;
    });
    ipcMain.handle("router-control:setPresence", async () => {
      throw new Error("Presence mode must be one of: always, follow-codex.");
    });
  });
  const bridge = createNativeBridge({ registerIpcHandlers, write: out.write });
  await bridge.dispatch(JSON.stringify({
    id: 1,
    method: "saveProviderCredential",
    params: { providerId: "opencode-go", credential: "secret-value" },
  }));
  assert.deepEqual(seen, [{ providerId: "opencode-go", credential: "secret-value" }]);
  // An undefined handler result still produces a well-formed JSON response.
  assert.deepEqual(out.lines.at(-1), { id: 1, ok: true, result: null });
  await bridge.dispatch(JSON.stringify({ id: 2, method: "setPresence", params: { mode: "sometimes" } }));
  assert.deepEqual(out.lines.at(-1), {
    id: 2,
    ok: false,
    error: "Presence mode must be one of: always, follow-codex.",
  });
});

test("native bridge rejects malformed, oversized, and non-object requests", async () => {
  const out = collector();
  let calls = 0;
  const { registerIpcHandlers } = fakeRegistrar(({ ipcMain }) => {
    ipcMain.handle("router-control:getHealth", async () => { calls += 1; return {}; });
  });
  const bridge = createNativeBridge({ registerIpcHandlers, write: out.write });
  await bridge.dispatch("{not json");
  assert.equal(out.lines.at(-1).error, "Request is not valid JSON.");
  await bridge.dispatch(JSON.stringify({ id: -1, method: "getHealth" }));
  assert.equal(out.lines.at(-1).error, "Request id must be a non-negative integer.");
  await bridge.dispatch(JSON.stringify({ id: 1, method: "getHealth", params: ["array"] }));
  assert.equal(out.lines.at(-1).error, "Operation parameters must be an object.");
  await bridge.dispatch(JSON.stringify({ id: 2, method: "__proto__" }));
  assert.equal(out.lines.at(-1).error, "Unknown Control Center operation.");
  await bridge.dispatch(JSON.stringify({ id: 3, method: "getHealth", pad: "x".repeat(MAX_REQUEST_BYTES) }));
  assert.equal(out.lines.at(-1).error, "Request is too large.");
  assert.equal(calls, 0);
});

test("native bridge turns renderer operation broadcasts into events", async () => {
  const out = collector();
  const { registerIpcHandlers, options } = fakeRegistrar(() => {});
  createNativeBridge({ registerIpcHandlers, write: out.write });
  const [window] = options().BrowserWindow.getAllWindows();
  window.webContents.send("router-control:operation", { id: "a", status: "started", message: "setPresence started" });
  window.webContents.send("router-control:navigate", { destination: "usage" });
  assert.deepEqual(out.lines, [
    { event: "operation", payload: { id: "a", status: "started", message: "setPresence started" } },
  ]);
  assert.equal(options().BrowserWindow.fromWebContents({}), undefined);
  assert.equal(options().senderGuard({}), true);
});

test("platform shell uses the macOS opener without a shell and refuses elsewhere", async () => {
  const calls = [];
  const spawnImpl = (command, args, options) => {
    calls.push({ command, args, options });
    const child = new EventEmitter();
    queueMicrotask(() => child.emit("exit", args[0].includes("fail") ? 1 : 0));
    return child;
  };
  const shell = createPlatformShell({ platform: "darwin", spawnImpl });
  await shell.openExternal("https://opencode.ai/docs");
  assert.equal(await shell.openPath("/Applications/Codex.app"), "");
  assert.match(await shell.openPath("/fail"), /status 1/);
  assert.deepEqual(calls.map((call) => [call.command, call.args, call.options.shell]), [
    ["/usr/bin/open", ["https://opencode.ai/docs"], false],
    ["/usr/bin/open", ["/Applications/Codex.app"], false],
    ["/usr/bin/open", ["/fail"], false],
  ]);
  const linux = createPlatformShell({ platform: "linux", spawnImpl });
  await assert.rejects(linux.openExternal("https://example.com"), /unavailable/);
});

test("native bridge process announces the real ipc.mjs operation set over stdio", async () => {
  const child = spawn(process.execPath, [BRIDGE], { stdio: ["pipe", "pipe", "pipe"] });
  let buffer = "";
  const lines = [];
  const settled = new Promise((resolve, reject) => {
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf("\n")) >= 0) {
        lines.push(JSON.parse(buffer.slice(0, index)));
        buffer = buffer.slice(index + 1);
        if (lines.length === 1) {
          child.stdin.write(`${JSON.stringify({ id: 7, method: "noSuchOperation" })}\n`);
        } else if (lines.length === 2) {
          child.stdin.end();
        }
      }
    });
    child.once("error", reject);
    child.once("exit", (code) => resolve(code));
  });
  assert.equal(await settled, 0);
  const [ready, refusal] = lines;
  assert.equal(ready.event, "ready");
  assert.equal(ready.protocol, NATIVE_BRIDGE_PROTOCOL);
  for (const method of [
    "getSnapshot", "getProviders", "getHarnesses", "getContextSessions",
    "saveProviderCredential", "setupHarness", "updateHarness", "openExternal",
  ]) assert.ok(ready.methods.includes(method), `${method} is exposed`);
  for (const method of ["minimizeWindow", "toggleMaximizeWindow", "closeWindow"]) {
    assert.ok(!ready.methods.includes(method), `${method} stays native`);
  }
  assert.deepEqual(refusal, { id: 7, ok: false, error: "Unknown Control Center operation." });
});
