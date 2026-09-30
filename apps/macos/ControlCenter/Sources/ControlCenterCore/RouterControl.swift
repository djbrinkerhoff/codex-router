import Foundation

/// The router operations a Control Center page may call.
///
/// This is `preload.cjs` for the native window: each method builds exactly
/// the payload the Electron preload builds for the same name, and nothing
/// else can be sent. Validation, argv construction, the mutation queue, and
/// the version-skew gate all stay in `ipc.mjs` behind the bridge.
public final class RouterControl: @unchecked Sendable {
  public typealias Params = [String: JSONValue]
  private let bridge: BridgeClient

  public init(bridge: BridgeClient) {
    self.bridge = bridge
  }

  public func supports(_ method: String) -> Bool? { bridge.supports(method) }

  public func stop() { bridge.stop() }

  @discardableResult
  public func call(_ method: String, _ params: Params? = nil) async throws -> JSONValue {
    try await bridge.call(method, params)
  }

  // MARK: Reads

  public func getSnapshot() async throws -> JSONValue { try await call("getSnapshot") }
  public func getChatGptSession() async throws -> JSONValue { try await call("getChatGptSession") }
  public func getChatGptAccountPool() async throws -> JSONValue { try await call("getChatGptAccountPool") }
  public func getHealth() async throws -> JSONValue { try await call("getHealth") }
  public func getProviders() async throws -> JSONValue { try await call("getProviders") }
  public func discoverProviderModels(_ providerId: String, refresh: Bool = false) async throws -> JSONValue {
    try await call("discoverProviderModels", ["providerId": .string(providerId), "refresh": .bool(refresh)])
  }
  public func getAccountUsage() async throws -> JSONValue { try await call("getAccountUsage") }
  public func getProviderUsage() async throws -> JSONValue { try await call("getProviderUsage") }
  public func getLocalModels() async throws -> JSONValue { try await call("getLocalModels") }
  public func getVisionBridge() async throws -> JSONValue { try await call("getVisionBridge") }
  public func getToolResultAging() async throws -> JSONValue { try await call("getToolResultAging") }
  public func getDoctor() async throws -> JSONValue { try await call("getDoctor") }
  public func getPresence() async throws -> JSONValue { try await call("getPresence") }
  public func getHarnesses() async throws -> JSONValue { try await call("getHarnesses") }
  public func getAgentBridges() async throws -> JSONValue { try await call("getAgentBridges") }
  public func getContextSessions() async throws -> JSONValue { try await call("getContextSessions") }
  public func refreshAll() async throws -> JSONValue { try await call("refreshAll") }

  // MARK: Providers and credentials

  public func repairInstall() async throws -> JSONValue { try await call("repairInstall") }
  public func setProviderEnabled(_ providerId: String, _ enabled: Bool) async throws -> JSONValue {
    try await call("setProviderEnabled", ["providerId": .string(providerId), "enabled": .bool(enabled)])
  }
  public func addProviderModels(_ providerId: String, _ modelIds: [String]) async throws -> JSONValue {
    try await call("addProviderModels", ["providerId": .string(providerId), "modelIds": JSONValue(modelIds)])
  }
  public func connectProvider(_ providerId: String) async throws -> JSONValue {
    try await call("connectProvider", ["providerId": .string(providerId)])
  }
  /// The credential crosses the bridge's stdin once and reaches the router's
  /// `control credential` child over its stdin. It never enters argv.
  public func saveProviderCredential(_ providerId: String, _ credential: String) async throws -> JSONValue {
    try await call("saveProviderCredential", ["providerId": .string(providerId), "credential": .string(credential)])
  }
  public enum EndpointAdapter: String, Sendable { case openaiChat = "openai-chat", openaiResponses = "openai-responses" }
  public func addCustomEndpoint(displayName: String, baseUrl: String, adapter: EndpointAdapter, credential: String?) async throws -> JSONValue {
    var params: Params = [
      "displayName": .string(displayName),
      "baseUrl": .string(baseUrl),
      "adapter": .string(adapter.rawValue),
    ]
    if let credential { params["credential"] = .string(credential) }
    return try await call("addCustomEndpoint", params)
  }
  public func editCustomEndpoint(_ providerId: String, displayName: String, baseUrl: String, adapter: EndpointAdapter) async throws -> JSONValue {
    try await call("editCustomEndpoint", [
      "displayName": .string(displayName),
      "baseUrl": .string(baseUrl),
      "adapter": .string(adapter.rawValue),
      "providerId": .string(providerId),
    ])
  }
  public func removeCustomEndpointModels(_ providerId: String, _ slugs: [String]) async throws -> JSONValue {
    try await call("removeCustomEndpointModels", ["providerId": .string(providerId), "slugs": JSONValue(slugs)])
  }
  public func removeLocalModels(_ slugs: [String]) async throws -> JSONValue {
    try await call("removeLocalModels", ["slugs": JSONValue(slugs)])
  }
  public func addCustomEndpointModel(_ providerId: String, _ modelId: String) async throws -> JSONValue {
    try await call("addCustomEndpointModel", ["providerId": .string(providerId), "modelId": .string(modelId)])
  }
  public func removeProviderCredential(_ providerId: String) async throws -> JSONValue {
    try await call("removeProviderCredential", ["providerId": .string(providerId)])
  }

  // MARK: Subagents and picker

  public func setSubagentMode(_ mode: String) async throws -> JSONValue {
    try await call("setSubagentMode", ["mode": .string(mode)])
  }
  public func setSubagentModel(_ slug: String, _ enabled: Bool) async throws -> JSONValue {
    try await call("setSubagentModel", ["slug": .string(slug), "enabled": .bool(enabled)])
  }
  public func setSubagentEffort(_ slug: String, _ effort: String) async throws -> JSONValue {
    try await call("setSubagentEffort", ["slug": .string(slug), "effort": .string(effort)])
  }
  public func certifySubagentModels(_ slugs: [String]) async throws -> JSONValue {
    try await call("certifySubagentModels", ["slugs": JSONValue(slugs)])
  }
  public func setSubagentSelection(selectAll: Bool) async throws -> JSONValue {
    try await call("setSubagentSelection", ["selectAll": .bool(selectAll)])
  }
  public func setPickerModel(_ slug: String, visible: Bool) async throws -> JSONValue {
    try await call("setPickerModel", ["slug": .string(slug), "visible": .bool(visible)])
  }
  public func setPickerModels(showAll: Bool) async throws -> JSONValue {
    try await call("setPickerModels", ["showAll": .bool(showAll)])
  }

  // MARK: Local runtime and vision

  public func installLocalModel(_ tag: String, force: Bool = false) async throws -> JSONValue {
    try await call("installLocalModel", ["tag": .string(tag), "force": .bool(force), "yes": true])
  }
  public func installLocalMlx() async throws -> JSONValue { try await call("installLocalMlx", ["yes": true]) }
  public func cancelLocalMlx() async throws -> JSONValue { try await call("cancelLocalMlx") }
  public func uninstallLocalModel(_ tag: String) async throws -> JSONValue {
    try await call("uninstallLocalModel", ["tag": .string(tag)])
  }
  public func setLocalModelEnabled(_ tag: String, _ enabled: Bool) async throws -> JSONValue {
    try await call("setLocalModelEnabled", ["tag": .string(tag), "enabled": .bool(enabled)])
  }
  public func benchmarkLocalModel(_ tag: String) async throws -> JSONValue {
    try await call("benchmarkLocalModel", ["tag": .string(tag)])
  }
  /// `start` or `update`.
  public func controlLocalRuntime(_ action: String) async throws -> JSONValue {
    try await call("controlLocalRuntime", ["action": .string(action)])
  }
  public func setVisionBridgeEnabled(_ enabled: Bool) async throws -> JSONValue {
    try await call("setVisionBridgeEnabled", ["enabled": .bool(enabled)])
  }
  public func setVisionBridgeEngine(_ engine: String, effort: String? = nil) async throws -> JSONValue {
    var params: Params = ["engine": .string(engine)]
    if let effort { params["effort"] = .string(effort) }
    return try await call("setVisionBridgeEngine", params)
  }
  public func setVisionBridgeEffort(_ effort: String) async throws -> JSONValue {
    try await call("setVisionBridgeEffort", ["effort": .string(effort)])
  }
  public func downloadVisionModel(_ tag: String) async throws -> JSONValue {
    try await call("downloadVisionModel", ["tag": .string(tag)])
  }
  public func useLocalVisionModel(_ tag: String) async throws -> JSONValue {
    try await call("useLocalVisionModel", ["tag": .string(tag)])
  }
  public func benchmarkVisionModel(_ tag: String) async throws -> JSONValue {
    try await call("benchmarkVisionModel", ["tag": .string(tag)])
  }

  // MARK: Settings

  public func setToolResultAging(_ enabled: Bool) async throws -> JSONValue {
    try await call("setToolResultAging", ["enabled": .bool(enabled)])
  }
  public func setNativeToolResultAging(_ enabled: Bool) async throws -> JSONValue {
    try await call("setNativeToolResultAging", ["enabled": .bool(enabled)])
  }
  /// A day count, `"default"`, or `"off"`.
  public func setToolResultRetentionTtl(_ days: JSONValue) async throws -> JSONValue {
    try await call("setToolResultRetentionTtl", ["days": days])
  }
  public func setDefaultModel(_ slug: String) async throws -> JSONValue {
    try await call("setDefaultModel", ["slug": .string(slug)])
  }
  public func setRouterDefault(_ slug: String) async throws -> JSONValue {
    try await call("setRouterDefault", ["slug": .string(slug)])
  }
  public func clearRouterDefault() async throws -> JSONValue { try await call("clearRouterDefault") }
  public func setSignedRouting(_ enabled: Bool) async throws -> JSONValue {
    try await call("setSignedRouting", ["enabled": .bool(enabled)])
  }
  public func setChatGptSessionSharing(_ enabled: Bool) async throws -> JSONValue {
    try await call("setChatGptSessionSharing", ["enabled": .bool(enabled)])
  }
  public func addChatGptSubscriptionAccount(label: String?) async throws -> JSONValue {
    // Like the preload, an absent value is omitted rather than sent as null.
    try await call("addChatGptSubscriptionAccount", label.map { ["label": JSONValue.string($0)] } ?? [:])
  }
  public func loginChatGptSubscriptionAccount(_ accountId: String) async throws -> JSONValue {
    try await call("loginChatGptSubscriptionAccount", ["accountId": .string(accountId)])
  }
  public func removeChatGptSubscriptionAccount(_ accountId: String) async throws -> JSONValue {
    try await call("removeChatGptSubscriptionAccount", ["accountId": .string(accountId)])
  }
  public func setChatGptAccountSelection(_ selection: String) async throws -> JSONValue {
    try await call("setChatGptAccountSelection", ["selection": .string(selection)])
  }
  /// `always` or `follow-codex`.
  public func setPresence(_ mode: String) async throws -> JSONValue {
    try await call("setPresence", ["mode": .string(mode)])
  }
  /// `status` or `start`. Stop and restart stay terminal-only.
  public func controlService(_ action: String) async throws -> JSONValue {
    try await call("controlService", ["action": .string(action)])
  }
  /// `enable`, `disable`, `status`, or `restart`.
  public func controlTray(_ action: String) async throws -> JSONValue {
    try await call("controlTray", ["action": .string(action)])
  }

  // MARK: Harnesses and sessions

  /// `surface` is `app` or `terminal`.
  public func launchHarness(_ harnessId: String, surface: String) async throws -> JSONValue {
    try await call("launchHarness", ["harnessId": .string(harnessId), "surface": .string(surface)])
  }
  public func probeAgentBridge(_ bridgeId: String) async throws -> JSONValue {
    try await call("probeAgentBridge", ["bridgeId": .string(bridgeId)])
  }
  public func loginAgentBridge(_ bridgeId: String) async throws -> JSONValue {
    try await call("loginAgentBridge", ["bridgeId": .string(bridgeId)])
  }
  public func setupHarness(_ harnessId: String, hostname: String? = nil) async throws -> JSONValue {
    var params: Params = ["harnessId": .string(harnessId)]
    if let hostname { params["hostname"] = .string(hostname) }
    return try await call("setupHarness", params)
  }
  /// One routed client, or `"all"` installed ones, to its latest release.
  public func updateHarness(_ harnessId: String) async throws -> JSONValue {
    try await call("updateHarness", ["harnessId": .string(harnessId)])
  }
  public func prepareCursorTunnel() async throws -> JSONValue { try await call("prepareCursorTunnel") }
  public func connectCursor(hostname: String?) async throws -> JSONValue {
    try await call("connectCursor", hostname.map { ["hostname": JSONValue.string($0)] } ?? [:])
  }
  public func disconnectCursor() async throws -> JSONValue { try await call("disconnectCursor") }
  public func disconnectHarness(_ harnessId: String) async throws -> JSONValue {
    try await call("disconnectHarness", ["harnessId": .string(harnessId)])
  }
  public func openHarnessSession(_ harnessId: String, sessionId: String, surface: String, model: String? = nil) async throws -> JSONValue {
    var params: Params = [
      "harnessId": .string(harnessId),
      "sessionId": .string(sessionId),
      "surface": .string(surface),
    ]
    if let model { params["model"] = .string(model) }
    return try await call("openHarnessSession", params)
  }
  /// HTTPS only; ipc.mjs refuses anything else.
  public func openExternal(_ url: String) async throws -> JSONValue {
    try await call("openExternal", ["url": .string(url)])
  }
}
