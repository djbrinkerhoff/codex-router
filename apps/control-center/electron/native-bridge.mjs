#!/usr/bin/env node
// Headless host for the Control Center's main-process operations.
//
// The native macOS Control Center (apps/macos/ControlCenter) is a SwiftUI
// window with no JavaScript engine of its own. Rather than re-implementing the
// operation layer in Swift -- the fixed argv contracts, the mutation queue,
// the version-skew gate, the credential-over-stdin rule, the harness and
// context-session readers -- it spawns this process and calls the very same
// handlers `registerIpcHandlers` installs for the Electron renderer. One
// implementation, two windows.
//
// Wire format: newline-delimited JSON over stdio, parent process only.
//   request   {"id": 1, "method": "getProviders", "params": {...}}
//   response  {"id": 1, "ok": true, "result": ...}
//             {"id": 1, "ok": false, "error": "message"}
//   event     {"event": "ready", "protocol": 1, "methods": [...]}
//             {"event": "operation", "payload": {...}}
//
// The method set is exactly the names ipc.mjs registered, minus the three
// window verbs the native window owns itself. There is no generic command,
// shell, or module-path method: a caller can only reach an operation the
// Electron preload could already reach, with the same validated payload.
import { spawn } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

export const NATIVE_BRIDGE_PROTOCOL = 1;
export const MAX_REQUEST_BYTES = 1024 * 1024;
const WINDOW_METHODS = new Set(["minimizeWindow", "toggleMaximizeWindow", "closeWindow"]);
const CHANNEL_PREFIX = "router-control:";
const METHOD_NAME = /^[A-Za-z][A-Za-z0-9]{0,63}$/;

/**
 * Electron's `shell` for a process with no Electron. Only the two calls
 * ipc.mjs makes are provided, and both go through the platform opener with
 * `shell: false`, which is what Electron itself does on macOS.
 */
export function createPlatformShell({ platform = process.platform, spawnImpl = spawn } = {}) {
  const opener = platform === "darwin" ? "/usr/bin/open" : undefined;
  const open = (target) => new Promise((resolve) => {
    if (!opener) {
      resolve("Opening files and links is unavailable on this platform.");
      return;
    }
    let child;
    try {
      child = spawnImpl(opener, [target], { shell: false, stdio: "ignore", detached: false });
    } catch (error) {
      resolve(error instanceof Error ? error.message : "The system opener failed.");
      return;
    }
    child.once("error", (error) => resolve(error?.message || "The system opener failed."));
    child.once("exit", (code) => resolve(code === 0 ? "" : `The system opener exited with status ${code}.`));
  });
  return Object.freeze({
    async openExternal(url) {
      const failure = await open(String(url));
      if (failure) throw new Error(failure);
    },
    openPath: (target) => open(String(target)),
  });
}

function jsonSafe(value) {
  if (value === undefined) return null;
  return value;
}

function errorMessage(error) {
  const message = error instanceof Error ? error.message : typeof error === "string" ? error : "";
  return (message || "Operation failed.").slice(0, 500);
}

/**
 * Build a bridge over an injectable handler registrar. Exported for tests,
 * which pass a fake `registerIpcHandlers` and in-memory streams.
 */
export function createNativeBridge({
  registerIpcHandlers,
  write,
  shell = createPlatformShell(),
  registerOptions = {},
}) {
  if (typeof registerIpcHandlers !== "function") throw new TypeError("registerIpcHandlers is required.");
  if (typeof write !== "function") throw new TypeError("write is required.");
  const handlers = new Map();
  const send = (message) => write(`${JSON.stringify(message)}\n`);
  const sinkWindow = Object.freeze({
    isDestroyed: () => false,
    webContents: Object.freeze({
      send(channel, payload) {
        if (channel !== `${CHANNEL_PREFIX}operation`) return;
        send({ event: "operation", payload: jsonSafe(payload) });
      },
    }),
  });
  const lifecycle = registerIpcHandlers({
    ...registerOptions,
    ipcMain: {
      handle(channel, handler) {
        if (typeof channel !== "string" || !channel.startsWith(CHANNEL_PREFIX)) return;
        const name = channel.slice(CHANNEL_PREFIX.length);
        if (WINDOW_METHODS.has(name)) return;
        handlers.set(name, handler);
      },
    },
    BrowserWindow: Object.freeze({
      getAllWindows: () => [sinkWindow],
      fromWebContents: () => undefined,
    }),
    shell,
    // Only the parent process holds these pipes; there is no renderer frame
    // to authenticate.
    senderGuard: () => true,
  });
  const methods = [...handlers.keys()].sort();

  async function dispatch(line) {
    if (Buffer.byteLength(line, "utf8") > MAX_REQUEST_BYTES) {
      send({ id: null, ok: false, error: "Request is too large." });
      return;
    }
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      send({ id: null, ok: false, error: "Request is not valid JSON." });
      return;
    }
    const id = request?.id;
    if (!Number.isSafeInteger(id) || id < 0) {
      send({ id: null, ok: false, error: "Request id must be a non-negative integer." });
      return;
    }
    const method = request.method;
    if (typeof method !== "string" || !METHOD_NAME.test(method) || !handlers.has(method)) {
      send({ id, ok: false, error: "Unknown Control Center operation." });
      return;
    }
    const params = request.params;
    if (params !== undefined && params !== null && (typeof params !== "object" || Array.isArray(params))) {
      send({ id, ok: false, error: "Operation parameters must be an object." });
      return;
    }
    try {
      const result = await handlers.get(method)({ sender: null, senderFrame: null }, params ?? undefined);
      send({ id, ok: true, result: jsonSafe(result) });
    } catch (error) {
      send({ id, ok: false, error: errorMessage(error) });
    }
  }

  return Object.freeze({
    methods,
    dispatch,
    announce() {
      send({ event: "ready", protocol: NATIVE_BRIDGE_PROTOCOL, methods });
    },
    whenIdle: () => lifecycle?.whenMutationsIdle?.() ?? Promise.resolve(),
  });
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--resources-path") {
      options.resourcesPath = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${argv[index]}`);
    }
  }
  return options;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  // The packaged app's resource directory plays the role Electron's
  // process.resourcesPath does: command-runner.mjs reads its router-root
  // marker, and ipc.mjs prefers its router-src copy of read-only helpers.
  if (options.resourcesPath !== undefined) {
    const resolved = path.resolve(String(options.resourcesPath));
    if (!existsSync(resolved) || !statSync(resolved).isDirectory()) {
      throw new Error("--resources-path must name an existing directory.");
    }
    process.resourcesPath = resolved;
  }
  // stdout carries the protocol. Anything the operation layer logs goes to
  // stderr, where the parent keeps it out of the UI.
  const protocolWrite = process.stdout.write.bind(process.stdout);
  console.log = console.error;
  console.info = console.error;
  console.debug = console.error;
  const { registerIpcHandlers } = await import("./ipc.mjs");
  const bridge = createNativeBridge({ registerIpcHandlers, write: protocolWrite });
  const pending = new Set();
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on("line", (line) => {
    if (!line.trim()) return;
    const task = bridge.dispatch(line).finally(() => pending.delete(task));
    pending.add(task);
  });
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    // A closed pipe means the window went away. Let a mutation that already
    // started finish its rollback-safe sequence rather than abandoning it.
    await Promise.allSettled([...pending]);
    await bridge.whenIdle();
    process.exit(0);
  };
  input.on("close", () => void close());
  process.on("SIGTERM", () => void close());
  bridge.announce();
}

const invokedDirectly = process.argv[1]
  && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (invokedDirectly) {
  main().catch((error) => {
    process.stderr.write(`Control Center bridge failed: ${errorMessage(error)}\n`);
    process.exit(1);
  });
}
