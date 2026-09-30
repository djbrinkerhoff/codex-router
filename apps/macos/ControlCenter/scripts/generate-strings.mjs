#!/usr/bin/env node
// Generates the native Control Center's string catalogs from the Electron
// renderer's locale modules, so both windows speak from one source of truth.
//
//   node apps/macos/ControlCenter/scripts/generate-strings.mjs          write
//   node apps/macos/ControlCenter/scripts/generate-strings.mjs --check  verify
//
// The locale modules are TypeScript; Node 22.18+ strips their types on
// import. test/control-center-native-strings.test.mjs runs --check so a
// renderer copy change that was not regenerated fails CI.
import { mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..", "..", "..", "..");
const RENDERER = path.join(ROOT, "apps", "control-center", "src");
export const OUTPUT = path.join(HERE, "..", "Sources", "ControlCenterCore", "Resources", "Strings");

function stable(value) {
  return `${JSON.stringify(value, null, 1)}\n`;
}

export async function renderCatalogs() {
  const { messageCatalogs, LANGUAGE_OPTIONS } = await import(pathToFileURL(path.join(RENDERER, "i18n.ts")).href);
  const { backendMessageKeys, backendMessagePatterns } = await import(
    pathToFileURL(path.join(RENDERER, "backend-messages.ts")).href
  );
  const files = new Map();
  for (const option of LANGUAGE_OPTIONS) {
    const catalog = messageCatalogs[option.id];
    const sorted = Object.fromEntries(Object.keys(catalog).sort().map((key) => [key, catalog[key]]));
    files.set(`${option.id}.json`, stable(sorted));
  }
  files.set("languages.json", stable(LANGUAGE_OPTIONS.map((option) => ({
    id: option.id,
    label: option.label,
    locale: option.locale,
    rtl: "dir" in option && option.dir === "rtl",
  }))));
  for (const { pattern } of backendMessagePatterns) {
    if (pattern.flags) throw new Error(`Backend pattern ${pattern} uses flags the native port does not read.`);
  }
  files.set("backend.json", stable({
    keys: Object.fromEntries(Object.keys(backendMessageKeys).sort().map((key) => [key, backendMessageKeys[key]])),
    patterns: backendMessagePatterns.map(({ pattern, key }) => ({ source: pattern.source, key })),
  }));
  return files;
}

async function main() {
  const check = process.argv.includes("--check");
  const files = await renderCatalogs();
  const stale = [];
  if (!check) mkdirSync(OUTPUT, { recursive: true });
  for (const [name, contents] of files) {
    const target = path.join(OUTPUT, name);
    const current = existsSync(target) ? readFileSync(target, "utf8") : undefined;
    if (current === contents) continue;
    if (check) stale.push(name);
    else writeFileSync(target, contents);
  }
  const extra = existsSync(OUTPUT)
    ? readdirSync(OUTPUT).filter((name) => name.endsWith(".json") && !files.has(name))
    : [];
  if (check && (stale.length || extra.length)) {
    process.stderr.write(
      `Native Control Center strings are out of date (${[...stale, ...extra].join(", ")}). `
        + "Run node apps/macos/ControlCenter/scripts/generate-strings.mjs.\n",
    );
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error?.stack || error}\n`);
    process.exit(1);
  });
}
