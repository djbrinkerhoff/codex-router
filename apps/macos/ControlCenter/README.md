# Codex Router Control Center for macOS

The native SwiftUI Control Center that `Codex Router.app` embeds as
`Contents/Resources/Control Center.app`. It replaces the Electron window on
macOS; Windows and Linux keep `apps/control-center`.

## How it is put together

- `Sources/ControlCenterCore` is Foundation only: the lenient `JSONValue`
  model, the `BridgeClient` that talks to the operation layer, the typed
  `RouterControl` API, the lifecycle record, navigation parsing, formatting,
  and the string catalogs generated from the renderer's locales.
- `Sources/ControlCenter` is the AppKit/SwiftUI app: `AppDelegate` owns the
  window, the Dock tile, and the lifecycle record; `AppModel` owns every read,
  poll, and action; `Pages/` holds one view per section.
- Router operations are not implemented here. The app starts
  `apps/control-center/electron/native-bridge.mjs` with Node and calls the same
  `ipc.mjs` handlers the Electron window calls. See "The macOS Control Center
  is native, and its operations are Electron's" in `AGENTS.md`.

## Develop

```sh
swift test                       # core unit tests
swift run ControlCenter          # a window against the checkout's router
node scripts/generate-strings.mjs   # after editing apps/control-center/src/locales
```

A development build finds the bridge in the checkout it was built from (or
under `CODEX_ROUTER_SOURCE_ROOT`) and Node on `CODEX_ROUTER_NODE_BIN` or the
usual install directories.

## Package

`scripts/build-macos-control-center.sh OUTPUT.app SHORT BUILD VERSION PROTOCOL`
builds the bundle; `scripts/build-macos-tray-app.sh` calls it and signs the
result inside the outer app.
