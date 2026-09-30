import AppKit
import ControlCenterCore
import SwiftUI

/// The Control Center's sections, in sidebar order. Ids match the Electron
/// renderer's `ViewId` so stored preferences and translations line up.
enum ViewID: String, CaseIterable, Identifiable {
  case dashboard, usage, status, models, local, harness, context, settings
  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .dashboard: return "square.grid.2x2"
    case .usage: return "gauge.with.dots.needle.33percent"
    case .status: return "waveform.path.ecg"
    case .models: return "shippingbox"
    case .local: return "internaldrive"
    case .harness: return "curlybraces"
    case .context: return "brain"
    case .settings: return "gearshape"
    }
  }

  var experimental: Bool { self == .harness }

  var fallbackLabel: String {
    switch self {
    case .dashboard: return "Dashboard"
    case .usage: return "Usage"
    case .status: return "Status"
    case .models: return "Models"
    case .local: return "Local"
    case .harness: return "Harness"
    case .context: return "Context Manager"
    case .settings: return "Settings"
    }
  }
}

/// Each independently loaded source. A page shows a skeleton for a source
/// until its latest read settles, successful or not.
enum DataSource: String, CaseIterable {
  case snapshot, providers, presence, health, accountUsage, accountPool, providerUsage
}

enum AppTheme: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
}

struct Toast: Equatable, Identifiable {
  enum Tone { case neutral, success, danger }
  let id = UUID()
  var tone: Tone
  var message: String
}

/// A request for the Models page to scroll to and highlight one region.
struct ModelFocusRequest: Equatable {
  var region: String
  var id: Int
}

/// A request for the Usage page, from the tray's notch or reset reminder.
struct UsageFocusRequest: Equatable {
  var id: Int
  var sourceID: String?
  var allowance: Bool
}

/// Hands bridge operation events to the model without capturing it before
/// initialization completes.
private final class OperationRelay: @unchecked Sendable {
  weak var model: AppModel?
}

/// The window's state and every router read and action, ported from
/// `App.tsx`. Pages observe this object and never talk to the bridge
/// directly, so one refresh and one operation indicator serve all of them.
@MainActor
final class AppModel: ObservableObject {
  static let activeMlxStates: Set<String> = ["preparing", "downloading", "loading", "starting-server", "verifying", "publishing"]
  private static let themeKey = "model-router-control-center-theme"
  private static let viewKey = "model-router-control-center-view"
  private static let languageKey = "codex-router-language"

  let api: RouterControl

  // Router data. Every value is the router's JSON, read leniently by pages.
  @Published var snapshot: JSONValue?
  @Published var health: JSONValue?
  @Published var providers: JSONValue?
  @Published var accountUsage: JSONValue?
  @Published var accountPool: JSONValue?
  @Published var chatgptSession: JSONValue?
  @Published var providerUsage: JSONValue?
  @Published var presence: JSONValue?
  @Published private(set) var dataReady: Set<DataSource> = []
  @Published private(set) var readErrors: [DataSource: String] = [:]
  @Published private(set) var refreshing = false
  @Published var loadError: String?
  @Published var operation: OperationEvent?
  @Published var toast: Toast?

  // Navigation.
  @Published private(set) var view: ViewID
  @Published private(set) var history: [ViewID]
  @Published private(set) var historyIndex = 0
  @Published var modelFocusRequest: ModelFocusRequest?
  @Published var usageFocusRequest: UsageFocusRequest?
  @Published var searchOpen = false
  @Published var sidebarOpen = true

  // Presentation.
  @Published var theme: AppTheme {
    didSet {
      UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
      applyTheme()
    }
  }
  @Published var language: String {
    didSet {
      UserDefaults.standard.set(language, forKey: Self.languageKey)
      t = Translator(language: language)
    }
  }
  @Published private(set) var t: Translator

  /// Whether the window can be seen. Health polling pauses while it cannot,
  /// as the renderer's did while `document.visibilityState` was hidden.
  var windowVisible = false {
    didSet { if windowVisible && !oldValue { Task { await refreshHealth() } } }
  }

  private var readGenerations: [DataSource: Int] = [:]
  private var healthPollInFlight = false
  private var downloadPollInFlight = false
  private var previousActivityState: String?
  private var timers: [Timer] = []
  private var downloadTimer: Timer?
  private var toastTask: Task<Void, Never>?
  private var modelFocusSequence = 0
  private var usageFocusSequence = 0

  init(api: RouterControl? = nil) {
    let defaults = UserDefaults.standard
    let storedTheme = defaults.string(forKey: Self.themeKey).flatMap(AppTheme.init(rawValue:)) ?? .system
    let storedView = defaults.string(forKey: Self.viewKey)
    let initialView: ViewID = storedView == "providers" ? .models : (storedView.flatMap(ViewID.init(rawValue:)) ?? .dashboard)
    let catalogs = StringCatalogs.shared
    let storedLanguage = defaults.string(forKey: Self.languageKey)
    let initialLanguage = storedLanguage.flatMap { catalogs.isLanguage($0) ? $0 : nil }
      ?? catalogs.resolveLanguage(Locale.preferredLanguages.first)
    self.theme = storedTheme
    self.language = initialLanguage
    self.t = Translator(language: initialLanguage, catalogs: catalogs)
    self.view = initialView
    self.history = [initialView]
    let relay = OperationRelay()
    self.api = api ?? RouterControl(bridge: BridgeClient(
      launch: { try RouterLocator.bridgeLaunch() },
      onOperation: { event in
        Task { @MainActor in relay.model?.operation = event }
      }
    ))
    relay.model = self
    applyTheme()
    startPolling()
    Task { await refreshAll() }
  }

  func shutdown() {
    for timer in timers { timer.invalidate() }
    timers.removeAll()
    downloadTimer?.invalidate()
    downloadTimer = nil
    api.stop()
  }

  // MARK: Derived values

  /// `snapshot.targets.codex`, the one client-specific target the window
  /// renders (native GPT details and the current task default).
  var target: JSONValue? { snapshot?["targets"]?["codex"] }

  func isReady(_ source: DataSource) -> Bool { dataReady.contains(source) }

  var firstReadError: String? {
    for source in DataSource.allCases { if let message = readErrors[source] { return message } }
    return nil
  }

  var downloadActive: Bool {
    let settings = target?["modelSettings"]
    let local = settings?["localModels"]?["download"]?["status"]?.string == "downloading"
    let mlx = Self.activeMlxStates.contains(settings?["localModels"]?["mlx"]?["operation"]?["status"]?.string ?? "idle")
    let vision = settings?["visionBridge"]?["download"]?["status"]?.string == "downloading"
    return local || mlx || vision
  }

  func readableError(_ error: Error) -> String {
    if let error = error as? ControlCenterError, !error.message.isEmpty { return error.message }
    let description = error.localizedDescription
    return description.isEmpty ? t("app.error.operationIncomplete") : description
  }

  // MARK: Reads

  private func settle(
    _ source: DataSource,
    _ request: @escaping () async throws -> JSONValue,
    commit: @escaping (JSONValue) -> Void,
    recover: ((Error) -> JSONValue)? = nil
  ) async {
    let generation = (readGenerations[source] ?? 0) + 1
    readGenerations[source] = generation
    do {
      let value = try await request()
      guard readGenerations[source] == generation else { return }
      commit(value)
      readErrors.removeValue(forKey: source)
    } catch {
      guard readGenerations[source] == generation else { return }
      if let recover { commit(recover(error)) }
      readErrors[source] = readableError(error)
    }
    // "Ready" means the latest attempt settled, not that it succeeded.
    if readGenerations[source] == generation { dataReady.insert(source) }
  }

  private func offlineHealth(_ error: Error) -> JSONValue {
    [
      "ok": false,
      "error": .string(readableError(error)),
      "activity": ["state": "offline", "active": [], "activeCount": 0],
    ]
  }

  func refreshHealth() async {
    guard !healthPollInFlight, windowVisible else { return }
    healthPollInFlight = true
    defer { healthPollInFlight = false }
    await settle(
      .health,
      { [api] in try await api.getHealth() },
      commit: { [weak self] in self?.commitHealth($0) },
      recover: { [weak self] in self?.offlineHealth($0) ?? .null }
    )
  }

  private func commitHealth(_ value: JSONValue) {
    health = value
    // The router appends the usage event before it clears a finished request
    // from health, so this transition is the cue to refresh the totals.
    guard let state = value["activity"]?["state"]?.string else { return }
    let finished = previousActivityState == "generating" && state != "generating" && state != "offline"
    previousActivityState = state
    if finished {
      Task {
        await refreshCore()
        await refreshUsage()
      }
    }
  }

  func refreshCore() async {
    // Unstructured tasks inherit the main actor, so every commit below runs
    // there; the reads themselves are concurrent requests to the bridge.
    let reads: [Task<Void, Never>] = [
      Task { [self] in await self.settle(.snapshot, { [api] in try await api.getSnapshot() }, commit: { [weak self] in self?.commitSnapshot($0) }) },
      Task { [self] in await self.settle(.providers, { [api] in try await api.getProviders() }, commit: { [weak self] in self?.providers = $0 }) },
      Task { [self] in await self.settle(.presence, { [api] in try await api.getPresence() }, commit: { [weak self] in self?.presence = $0 }) },
      Task { [self] in
        await self.settle(
          .health,
          { [api] in try await api.getHealth() },
          commit: { [weak self] in self?.commitHealth($0) },
          recover: { [weak self] in self?.offlineHealth($0) ?? .null }
        )
      },
      Task { await self.readAccountPool() },
      Task { await self.readChatGptSession() },
    ]
    for read in reads { await read.value }
  }

  private func commitSnapshot(_ value: JSONValue) {
    snapshot = value
    updateDownloadPolling()
  }

  /// Account switching is additive; an older router without these reads
  /// must not hold any page region in a loading state.
  private func readAccountPool() async {
    if api.supports("getChatGptAccountPool") == false {
      dataReady.insert(.accountPool)
      return
    }
    await settle(.accountPool, { [api] in try await api.getChatGptAccountPool() }, commit: { [weak self] in self?.accountPool = $0 })
  }

  private func readChatGptSession() async {
    guard api.supports("getChatGptSession") != false else { return }
    if let value = try? await api.getChatGptSession() { chatgptSession = value }
  }

  func refreshUsage() async {
    let reads: [Task<Void, Never>] = [
      Task { [self] in await self.settle(.accountUsage, { [api] in try await api.getAccountUsage() }, commit: { [weak self] in self?.accountUsage = $0 }) },
      Task { [self] in await self.settle(.providerUsage, { [api] in try await api.getProviderUsage() }, commit: { [weak self] in self?.providerUsage = $0 }) },
    ]
    for read in reads { await read.value }
  }

  func refreshAll() async {
    refreshing = true
    loadError = nil
    let core = Task { await self.refreshCore() }
    let usage = Task { await self.refreshUsage() }
    await core.value
    await usage.value
    refreshing = false
  }

  /// Merges download progress into the rendered snapshot without refetching
  /// the whole snapshot every four seconds.
  func refreshDownloadProgress() async {
    guard !downloadPollInFlight, let settings = target?["modelSettings"] else { return }
    downloadPollInFlight = true
    defer { downloadPollInFlight = false }
    let localActive = settings["localModels"]?["download"]?["status"]?.string == "downloading"
      || Self.activeMlxStates.contains(settings["localModels"]?["mlx"]?["operation"]?["status"]?.string ?? "idle")
    let visionActive = settings["visionBridge"]?["download"]?["status"]?.string == "downloading"
    var localModels: JSONValue?
    if localActive { localModels = try? await api.getLocalModels() }
    var visionBridge: JSONValue?
    if visionActive { visionBridge = try? await api.getVisionBridge() }
    guard var current = snapshot, current["targets"]?["codex"]?["modelSettings"] != nil else { return }
    if let localModels {
      current = current.setting(localModels, at: ["targets", "codex", "modelSettings", "localModels"])
    }
    if let visionBridge {
      current = current.setting(visionBridge, at: ["targets", "codex", "modelSettings", "visionBridge"])
    }
    snapshot = current
    updateDownloadPolling()
  }

  // MARK: Polling

  private func startPolling() {
    let health = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refreshHealth() }
    }
    // Provider usage reparses the retained ledger in a fresh control
    // process; five minutes bounds that cost as the ledger grows. Startup,
    // manual refresh, and post-action refresh stay immediate.
    let usage = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refreshUsage() }
    }
    let core = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.refreshCore() }
    }
    for timer in [health, usage, core] {
      RunLoop.main.add(timer, forMode: .common)
      timers.append(timer)
    }
  }

  /// Starts or stops the four-second download poll to match the snapshot.
  func updateDownloadPolling() {
    if downloadActive, downloadTimer == nil {
      let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.refreshDownloadProgress() }
      }
      RunLoop.main.add(timer, forMode: .common)
      downloadTimer = timer
    } else if !downloadActive, let timer = downloadTimer {
      timer.invalidate()
      downloadTimer = nil
    }
  }

  // MARK: Actions

  /// Runs one router action with the same feedback the Electron renderer
  /// gave: an operation indicator, a toast, and a refresh afterwards, also
  /// after a failure, because some transactions persist their local decision
  /// before a later republish step fails.
  func runAction(_ label: String, _ action: @escaping () async throws -> JSONValue) async {
    operation = OperationEvent(action: label, status: .started, message: label)
    let result: JSONValue
    do {
      result = try await action()
    } catch {
      let message = readableError(error)
      showToast(.danger, message)
      operation = OperationEvent(action: label, status: .failed, message: message)
      await refreshCore()
      await refreshUsage()
      return
    }
    if result["alreadyAuthenticated"]?.bool == true || result["pending"]?.bool == true {
      let message: String
      if result["alreadyAuthenticated"]?.bool == true {
        message = t("app.toast.alreadySignedIn", ["action": label])
      } else if result["inProgress"]?.bool == true {
        message = t("app.toast.alreadyOpenInBrowser", ["action": label])
      } else {
        message = t("app.toast.openedInBrowser", ["action": label])
      }
      showToast(.neutral, message)
      await refreshCore()
      operation = OperationEvent(action: label, status: .completed, message: message)
      return
    }
    if result["accepted"]?.bool == true {
      // Detached tray work can outlive this window; spawn acceptance is not
      // success, so the operation stays "started".
      let message = t("app.toast.actionStarted", ["action": label])
      showToast(.neutral, message)
      operation = OperationEvent(action: label, status: .started, message: message)
      return
    }
    let completed = t("app.toast.actionCompleted", ["action": label])
    showToast(.success, completed)
    await refreshCore()
    await refreshUsage()
    operation = OperationEvent(action: label, status: .completed, message: completed)
    updateDownloadPolling()
  }

  /// Fire-and-forget wrapper for button handlers.
  func perform(_ label: String, _ action: @escaping (RouterControl) async throws -> JSONValue) {
    let api = self.api
    Task { await runAction(label) { try await action(api) } }
  }

  func showToast(_ tone: Toast.Tone, _ message: String) {
    toast = Toast(tone: tone, message: message)
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  // MARK: Navigation

  var canGoBack: Bool { historyIndex > 0 }
  var canGoForward: Bool { historyIndex < history.count - 1 }

  func navigate(_ next: ViewID, modelFocus: String? = nil) {
    if next == .models, let modelFocus {
      modelFocusSequence += 1
      modelFocusRequest = ModelFocusRequest(region: modelFocus, id: modelFocusSequence)
    }
    guard next != view else { return }
    history = Array(history.prefix(historyIndex + 1)) + [next]
    historyIndex = history.count - 1
    setView(next)
  }

  func back() { move(-1) }
  func forward() { move(1) }

  private func move(_ direction: Int) {
    let index = historyIndex + direction
    guard history.indices.contains(index) else { return }
    historyIndex = index
    setView(history[index])
  }

  private func setView(_ next: ViewID) {
    view = next
    UserDefaults.standard.set(next.rawValue, forKey: Self.viewKey)
  }

  /// A tray navigation request: Usage, optionally focused on one source or
  /// on the allowance resets.
  func open(_ request: NavigationRequest) {
    if request.destination == .usageResets || request.sourceID != nil {
      usageFocusSequence += 1
      usageFocusRequest = UsageFocusRequest(
        id: usageFocusSequence,
        sourceID: request.sourceID,
        allowance: request.destination == .usageResets
      )
    } else {
      usageFocusRequest = nil
    }
    navigate(.usage)
  }

  func label(for view: ViewID) -> String {
    let value = t("nav.\(view.rawValue)")
    return value == "nav.\(view.rawValue)" ? view.fallbackLabel : value
  }

  func description(for view: ViewID) -> String {
    t("nav.\(view.rawValue).desc")
  }

  // MARK: Theme

  private func applyTheme() {
    switch theme {
    case .system: NSApp?.appearance = nil
    case .light: NSApp?.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
    }
  }

  var isDark: Bool {
    switch theme {
    case .light: return false
    case .dark: return true
    case .system:
      return NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
  }
}
