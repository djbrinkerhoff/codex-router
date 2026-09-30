// swift-tools-version: 5.10
import PackageDescription

// The native macOS Control Center. It replaces the Electron window that used
// to be embedded in `Codex Router.app` and keeps that window's contracts: the
// `io.github.codex-router.control-center` bundle, the `Codex Router`
// executable name, `--query-lifecycle`, and the `codex-router://` navigation
// requests the tray sends. Router operations go through
// `apps/control-center/electron/native-bridge.mjs`, so the Swift and Electron
// windows share one operation layer instead of two.
let package = Package(
  name: "ControlCenter",
  defaultLocalization: "en",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ControlCenter", targets: ["ControlCenter"]),
  ],
  targets: [
    // Foundation only, so the bridge protocol, lifecycle file, navigation
    // parsing, formatting, and translations are unit-tested without AppKit.
    .target(
      name: "ControlCenterCore",
      path: "Sources/ControlCenterCore",
      resources: [.copy("Resources/Strings")]
    ),
    .executableTarget(
      name: "ControlCenter",
      dependencies: ["ControlCenterCore"],
      path: "Sources/ControlCenter"
    ),
    .testTarget(
      name: "ControlCenterCoreTests",
      dependencies: ["ControlCenterCore"],
      path: "Tests/ControlCenterCoreTests"
    ),
  ]
)
