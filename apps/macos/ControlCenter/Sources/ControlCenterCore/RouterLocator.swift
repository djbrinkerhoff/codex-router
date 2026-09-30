import Foundation

/// Finds the Node runtime and the bridge script a native Control Center runs.
///
/// A desktop app does not inherit the login shell's PATH, so the same
/// user-level install directories the tray searches are put ahead of it.
public enum RouterLocator {
  /// Where the router's own state lives. Mirrors `stateDir` in
  /// `src/paths.mjs` and `RouterStateDirectory` in the tray.
  public static func stateDirectory(environment: [String: String], home: URL) -> URL {
    let configured = ["MODEL_ROUTER_STATE_DIR", "CODEX_ROUTER_STATE_DIR", "KIMI_CODEX_STATE_DIR"]
      .compactMap { environment[$0] }
      .first { !$0.isEmpty }
    if let configured { return URL(fileURLWithPath: configured, isDirectory: true) }
    let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? home.appendingPathComponent(".codex", isDirectory: true)
    return codexHome.appendingPathComponent("codex-router", isDirectory: true)
  }

  /// PATH for child processes: user-level install locations first, then
  /// whatever the app inherited, without duplicates.
  public static func searchPath(environment: [String: String], home: URL) -> [String] {
    let preferred = [
      home.appendingPathComponent(".npm-global/bin").path,
      home.appendingPathComponent(".local/bin").path,
      home.appendingPathComponent(".volta/bin").path,
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ]
    let inherited = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      .split(separator: ":")
      .map(String.init)
      .filter { !$0.isEmpty }
    var seen = Set<String>()
    return (preferred + inherited).filter { seen.insert($0).inserted }
  }

  /// The Node executable: an explicit `CODEX_ROUTER_NODE_BIN` (the value the
  /// installer records for the service), then the search path.
  public static func nodeExecutable(
    environment: [String: String],
    home: URL,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    if let explicit = environment["CODEX_ROUTER_NODE_BIN"], explicit.hasPrefix("/"), isExecutable(explicit) {
      return URL(fileURLWithPath: explicit)
    }
    for directory in searchPath(environment: environment, home: home) {
      let candidate = (directory as NSString).appendingPathComponent("node")
      if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
    }
    return nil
  }

  /// The bridge a packaged app ships beside its own copy of the operation
  /// layer, so the window and the operations it calls are one version.
  public static func bundledBridge(resources: URL?, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL? {
    guard let resources else { return nil }
    let script = resources
      .appendingPathComponent("bridge", isDirectory: true)
      .appendingPathComponent("apps/control-center/electron/native-bridge.mjs")
    return fileExists(script.path) ? script : nil
  }

  /// A development build run from a checkout (`swift run`) uses the
  /// checkout's bridge. The explicit source-root overrides win, then the
  /// checkout this package sits in.
  public static func checkoutBridge(
    environment: [String: String],
    executable: URL,
    fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
  ) -> URL? {
    var roots: [URL] = []
    for key in ["CODEX_ROUTER_SOURCE_ROOT", "MODEL_ROUTER_SOURCE_ROOT"] {
      if let value = environment[key], !value.isEmpty { roots.append(URL(fileURLWithPath: value, isDirectory: true)) }
    }
    // .../apps/macos/ControlCenter/.build/<triple>/<config>/ControlCenter
    var directory = executable.deletingLastPathComponent()
    for _ in 0..<8 {
      roots.append(directory)
      directory = directory.deletingLastPathComponent()
    }
    for root in roots {
      // `swift run` starts the binary by a relative path. A relative URL
      // keeps resolving against the launching directory, which the bridge's
      // own working directory is not, so hand the child an absolute one.
      let script = root.appendingPathComponent("apps/control-center/electron/native-bridge.mjs")
        .absoluteURL.standardizedFileURL
      if fileExists(script.path) { return script }
    }
    return nil
  }

  /// The complete launch description, or an error a person can act on.
  public static func bridgeLaunch(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    resources: URL? = Bundle.main.resourceURL,
    executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
  ) throws -> BridgeLaunch {
    guard let node = nodeExecutable(environment: environment, home: home) else {
      throw ControlCenterError(
        "Node.js 22.19 or newer was not found. Install Node.js, or set CODEX_ROUTER_NODE_BIN, then reopen Codex Router."
      )
    }
    let packaged = bundledBridge(resources: resources)
    guard let script = packaged ?? checkoutBridge(environment: environment, executable: executable) else {
      throw ControlCenterError("The Control Center bridge is missing. Rebuild Codex Router.")
    }
    var childEnvironment = environment
    childEnvironment["PATH"] = searchPath(environment: environment, home: home).joined(separator: ":")
    // Never let an inherited Electron flag change how Node reads its argv.
    childEnvironment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
    childEnvironment.removeValue(forKey: "NODE_OPTIONS")
    return BridgeLaunch(
      node: node,
      script: script,
      resourcesPath: packaged == nil ? nil : resources,
      environment: childEnvironment,
      workingDirectory: script.deletingLastPathComponent()
    )
  }
}
