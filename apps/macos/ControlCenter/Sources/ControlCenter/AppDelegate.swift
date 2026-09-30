import AppKit
import ControlCenterCore
import SwiftUI

/// One Control Center per bundle identifier, like Electron's single-instance
/// lock. LaunchServices already routes `open` to a running instance; these
/// cover direct binary launches from scripts.
enum SingleInstance {
  static let bundleIdentifier = "io.github.codex-router.control-center"

  static func others() -> [NSRunningApplication] {
    let current = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .filter { $0.processIdentifier != current && !$0.isTerminated }
  }

  static func anotherInstanceIsRunning() -> Bool {
    Bundle.main.bundleIdentifier == bundleIdentifier && !others().isEmpty
  }

  /// `--quit-for-update`: the tray rebuild asks the running window to leave
  /// before it swaps the bundle.
  static func terminateOtherInstances() {
    for application in others() { application.terminate() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let launchArguments: [String]
  private let lifecycleFile: URL
  /// The macOS tray owns the menu-bar item and the process lifetime; this
  /// window only represents the product in the Dock while it is alive.
  private let embedded: Bool
  private let trayOnly: Bool
  private var window: NSWindow?
  private var model: AppModel?
  private var ready = false
  private var visible = false
  private var pendingNavigation: NavigationRequest?

  init(launchArguments: [String], environment: [String: String], home: URL) {
    self.launchArguments = launchArguments
    self.lifecycleFile = LifecycleState.path(environment: environment, home: home)
    self.embedded = environment["CODEX_ROUTER_EMBEDDED_CONTROL_CENTER"] == "1" || AppDelegate.insideTrayBundle()
    self.trayOnly = launchArguments.contains("--tray-only")
    self.pendingNavigation = NavigationRequest(arguments: launchArguments)
    super.init()
  }

  /// `Codex Router.app/Contents/Resources/Control Center.app`.
  static func insideTrayBundle() -> Bool {
    let components = Bundle.main.bundleURL.standardizedFileURL.pathComponents
    guard components.count >= 4 else { return false }
    let tail = Array(components.suffix(4))
    return ["Codex Router.app", "Model Router.app"].contains(tail[0])
      && tail[1] == "Contents" && tail[2] == "Resources" && tail[3] == "Control Center.app"
  }

  // MARK: Lifecycle record

  private func publishLifecycle() {
    do {
      try LifecycleState.write(to: lifecycleFile, ready: ready, visible: visible)
    } catch {
      FileHandle.standardError.write(Data("Could not publish Control Center lifecycle state: \(error.localizedDescription)\n".utf8))
    }
  }

  // MARK: NSApplicationDelegate

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Replace a stale record as soon as this process owns the window role.
    publishLifecycle()
    NSApp.setActivationPolicy(embedded ? .accessory : .regular)
    NSApp.mainMenu = MainMenu.build(target: self)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = AppModel()
    self.model = model
    createWindow(model: model)
    // "Ready" means the whole native boundary exists: the window, its
    // SwiftUI content, and the model that will reach the bridge. The bridge
    // itself starts on the first read, as the Electron renderer's first IPC
    // call started its handlers.
    ready = true
    publishLifecycle()
    if let navigation = pendingNavigation {
      pendingNavigation = nil
      model.open(navigation)
      showWindow()
    } else if !trayOnly {
      showWindow()
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let navigation = urls.lazy.compactMap(NavigationRequest.init(url:)).first else { return }
    if let model {
      model.open(navigation)
      showWindow()
    } else {
      pendingNavigation = navigation
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing hides; the tray (or the Dock tile) brings the window back.
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    model?.shutdown()
    ready = false
    visible = false
    publishLifecycle()
  }

  // MARK: Window

  private func createWindow(model: AppModel) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Codex Router"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.minSize = NSSize(width: 960, height: 640)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("CodexRouterControlCenter")
    if !window.setFrameUsingName("CodexRouterControlCenter") { window.center() }
    window.contentView = NSHostingView(rootView: RootView().environmentObject(model))
    window.delegate = self
    self.window = window
  }

  func showWindow() {
    guard let window else { return }
    // The tray is an LSUIElement with no Dock tile of its own. While this
    // process lives it represents the product in the Dock and Command-Tab,
    // including while the window is merely hidden.
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    setVisible(true)
  }

  private func setVisible(_ value: Bool) {
    guard visible != value else { return }
    visible = value
    model?.windowVisible = value
    publishLifecycle()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    setVisible(false)
    return false
  }

  func windowDidMiniaturize(_ notification: Notification) {
    model?.windowVisible = false
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    model?.windowVisible = true
  }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let window else { return }
    model?.windowVisible = window.occlusionState.contains(.visible)
  }

  // MARK: Menu actions

  @objc func showControlCenter(_ sender: Any?) { showWindow() }
  @objc func refreshAll(_ sender: Any?) { Task { await model?.refreshAll() } }
  @objc func goBack(_ sender: Any?) { model?.back() }
  @objc func goForward(_ sender: Any?) { model?.forward() }
  @objc func showSearch(_ sender: Any?) { model?.searchOpen = true }
}

/// The application menu. Standard Edit items keep copy/paste working in
/// credential and search fields.
enum MainMenu {
  @MainActor
  static func build(target: AppDelegate) -> NSMenu {
    let menu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Codex Router", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Codex Router", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Control Center", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    menu.addItem(editItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let refresh = viewMenu.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refreshAll(_:)), keyEquivalent: "r")
    refresh.target = target
    let search = viewMenu.addItem(withTitle: "Search Sections…", action: #selector(AppDelegate.showSearch(_:)), keyEquivalent: "k")
    search.target = target
    viewMenu.addItem(.separator())
    let back = viewMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
    back.target = target
    let forward = viewMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
    forward.target = target
    viewItem.submenu = viewMenu
    menu.addItem(viewItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(.separator())
    let show = windowMenu.addItem(withTitle: "Control Center", action: #selector(AppDelegate.showControlCenter(_:)), keyEquivalent: "0")
    show.target = target
    windowItem.submenu = windowMenu
    menu.addItem(windowItem)
    NSApp.windowsMenu = windowMenu

    return menu
  }
}
