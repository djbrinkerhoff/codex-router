import ControlCenterCore
import Foundation

// Data layer of the Models page: ports of `model-families.mjs`,
// `model-catalog-search.mjs`, and the pure helpers at the top and bottom of
// `ModelsPage.tsx`. Nothing here touches the router or the UI.
//
// Records stay JSON-backed (`JSONValue`) so a router newer or older than this
// build never fails the whole page on one unexpected field; the structs below
// only give the fields the page reads a typed, lenient accessor.

// MARK: - Records

/// One provider route of a model (`RouterModel`).
struct ModelsRoute: Equatable, Identifiable {
  let json: JSONValue
  let slug: String
  let displayName: String
  let provider: String
  let gatewayModel: String?
  let enabled: Bool
  /// `native === true`.
  let native: Bool
  /// `nativeClientManaged !== false`.
  let nativeClientManagedFlag: Bool
  let multiAgentVersion: String?
  let certification: String?
  /// JavaScript truthiness of `visible`.
  let visible: Bool
  /// `visible === false`, strictly.
  let visibleIsFalse: Bool
  let contextWindow: Double?
  let inputModalities: [String]
  let reasoningLevels: [String]
  let isFree: Bool
  let local: Bool
  /// `available !== false`.
  let available: Bool

  var id: String { slug }

  init(_ json: JSONValue) {
    self.json = json
    slug = json["slug"]?.string ?? ""
    displayName = json["displayName"]?.string ?? ""
    provider = json["provider"]?.string ?? ""
    gatewayModel = json["gatewayModel"]?.string
    enabled = json["enabled"].truthy
    native = json["native"]?.bool == true
    nativeClientManagedFlag = json["nativeClientManaged"]?.bool != false
    multiAgentVersion = json["multiAgentVersion"]?.string
    certification = json["subagentCertification"]?.string
    visible = json["visible"].truthy
    visibleIsFalse = json["visible"]?.bool == false
    contextWindow = json["contextWindow"]?.double
    inputModalities = json["inputModalities"]?.strings ?? []
    reasoningLevels = json["reasoningLevels"]?.strings ?? []
    isFree = json["isFree"].truthy
    local = json["local"].truthy
    available = json["available"]?.bool != false
  }

  /// The capability the catalog published wins over the registry's
  /// provenance: a route the operator selected is v2 to Codex even though the
  /// registry never certified it.
  var subagentCertification: String {
    if multiAgentVersion == "v2" { return "v2" }
    return certification ?? (multiAgentVersion == "v1" ? "v1" : "unknown")
  }
}

struct ModelsCatalogSource: Equatable {
  let id: String
  let displayName: String
  let kind: String
}

/// One provider or custom endpoint as the setup snapshot describes it
/// (`ProviderSetup`).
struct ModelsSetup: Equatable {
  let json: JSONValue

  var id: String { json["id"]?.string ?? "" }
  var displayName: String { json["displayName"]?.string ?? "" }
  var kind: String { json["kind"]?.string ?? "" }
  var generic: Bool { json["generic"].truthy }
  /// `nil` when the router did not say; the page treats that as not disabled.
  var enabled: Bool? { json["enabled"]?.bool }
  var baseUrl: String { json["baseUrl"]?.string ?? "" }
  var adapter: String { json["adapter"]?.string ?? "" }
  var hasKey: Bool { json["hasKey"].truthy }
  var configured: Bool { json["configured"].truthy }
  var action: String { json["action"]?.string ?? "" }
  var planNote: String? { json["planNote"]?.string }
  var credentialLabel: String? { json["credentialLabel"]?.string }
  var configurationNote: String? { json["configurationNote"]?.string }
  var cliInstalled: Bool? { json["cliInstalled"]?.bool }
  var signIn: Bool { json["signIn"].truthy }
  var signedIn: Bool { json["signedIn"]?.bool == true }
  var disconnectable: Bool { json["disconnectable"].truthy }
  var probeNote: String? { json["probeNote"]?.string }
  var blockedNote: String? { json["blockedNote"]?.string }

  var catalogSources: [ModelsCatalogSource] {
    let items = json["catalogSources"]?.items ?? []
    return items.map { item in
      ModelsCatalogSource(
        id: item["id"]?.string ?? "",
        displayName: item["displayName"]?.string ?? "",
        kind: item["kind"]?.string ?? ""
      )
    }
  }
}

/// One model and every provider route that can serve it.
struct ModelsFamily: Identifiable {
  let id: String
  let displayName: String
  var routes: [ModelsRoute]
}

/// One row of the provider directory: setup state plus the routes it serves.
struct ModelsDirectoryEntry: Identifiable {
  let id: String
  var displayName: String
  var setup: ModelsSetup?
  var models: [ModelsRoute]
  var knownModels: [JSONValue]
}

/// A model a connected provider offers but the router may not have
/// registered yet (`CatalogModel`).
struct ModelsCatalogModel: Identifiable, Equatable {
  let key: String
  let modelId: String
  let displayName: String
  let providerId: String
  let providerName: String
  let sourceId: String
  let sourceName: String
  let registered: Bool
  let addable: Bool
  let blockedReason: String?
  let contextWindow: Double?
  let isFree: Bool

  var id: String { key }
}

enum ModelsCatalogStatus {
  case idle, loading, ready, error
}

/// Renderer-side state of one catalog source (`CatalogViewState`).
struct ModelsCatalogState {
  var status = ModelsCatalogStatus.idle
  /// A refresh keeps the list on screen instead of replacing it with a skeleton.
  var refreshing = false
  var data: JSONValue?
  var error: String?
}

/// A credential command -- saving a key, signing in, disconnecting -- is one
/// router transaction that also enables the provider and republishes every
/// installed client catalog. Which one is running decides what the chip and
/// the routes waiting on that provider say for the seconds it takes.
enum ModelsProviderMutation {
  case connecting, disconnecting
}

/// Slugs committed to the picker but not yet published: provider id to model
/// id to how many operations are in flight for it.
typealias ModelsPending = [String: [String: Int]]

enum ModelsStatusFilter: String, CaseIterable, Identifiable {
  case all, on, off, blocked
  var id: String { rawValue }
}

/// What the endpoint dialog collects (`CustomEndpointInput`).
struct ModelsEndpointInput {
  let displayName: String
  let baseUrl: String
  let adapter: RouterControl.EndpointAdapter
  let credential: String?
}

// MARK: - Logic

enum ModelsLogic {
  /// Below this, a list is short enough to read whole; filters and bulk
  /// switches would be more chrome than the list they act on.
  static let crowdedList = 8
  /// Picking between two or three providers is slower through a menu than by
  /// reading the provider each row already names.
  static let crowdedProviders = 3
  static let catalogAddBatchLimit = 200
  /// The native app is macOS only; the renderer's `api.platform`.
  static let platform = "darwin"

  /// `nil` reads as JavaScript `null`/`undefined` for `??` chains.
  static func present(_ value: JSONValue?) -> JSONValue? {
    guard let value, !value.isNull else { return nil }
    return value
  }

  /// `localeCompare` as -1, 0, or 1.
  static func compare(_ left: String, _ right: String) -> Int {
    switch left.localizedCompare(right) {
    case .orderedAscending: return -1
    case .orderedSame: return 0
    case .orderedDescending: return 1
    }
  }

  /// A stable sort, as `Array.prototype.sort` is.
  static func stableSorted<T>(_ items: [T], _ comparison: (T, T) -> Int) -> [T] {
    let ordered = items.enumerated().sorted { left, right in
      let result = comparison(left.element, right.element)
      if result != 0 { return result < 0 }
      return left.offset < right.offset
    }
    return ordered.map { $0.element }
  }

  static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `a || b` for strings.
  static func nonEmpty(_ value: String, or fallback: @autoclosure () -> String) -> String {
    value.isEmpty ? fallback() : value
  }

  // MARK: Families (model-families.mjs)

  private static func withoutProviderQualifier(_ value: String) -> String {
    let stripped = trimmed(value).replacingOccurrences(
      of: "\\s+\\([^()]+\\)\\s*$",
      with: "",
      options: .regularExpression
    )
    return trimmed(stripped)
  }

  static func familyName(_ model: ModelsRoute) -> String {
    withoutProviderQualifier(model.displayName.isEmpty ? model.slug : model.displayName)
  }

  static func familyKey(_ model: ModelsRoute) -> String {
    let name = familyName(model).precomposedStringWithCompatibilityMapping.lowercased()
    let dashed = name.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "-", options: .regularExpression)
    return dashed.replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
  }

  static func groupFamilies(_ models: [ModelsRoute]) -> [ModelsFamily] {
    var order: [String] = []
    var grouped: [String: ModelsFamily] = [:]
    for model in models {
      let key = familyKey(model)
      let id = key.isEmpty ? (model.slug.isEmpty ? "model" : model.slug) : key
      if var current = grouped[id] {
        current.routes.append(model)
        grouped[id] = current
      } else {
        order.append(id)
        grouped[id] = ModelsFamily(id: id, displayName: familyName(model), routes: [model])
      }
    }
    var families: [ModelsFamily] = []
    for id in order {
      guard var family = grouped[id] else { continue }
      family.routes = stableSorted(family.routes) { left, right in
        let byProvider = compare(left.provider, right.provider)
        return byProvider != 0 ? byProvider : compare(left.slug, right.slug)
      }
      families.append(family)
    }
    return stableSorted(families) { compare($0.displayName, $1.displayName) }
  }

  static func preferredRoute(_ family: ModelsFamily) -> ModelsRoute? {
    family.routes.first(where: { $0.visible })
      ?? family.routes.first(where: { $0.enabled || $0.native })
      ?? family.routes.first
  }

  // MARK: Route predicates

  static func nativeClientManaged(_ model: ModelsRoute) -> Bool {
    model.native && model.nativeClientManagedFlag
  }

  static func routeUsable(_ model: ModelsRoute) -> Bool {
    model.available
  }

  /// Certified routes remain active unless explicitly disabled; selected mode
  /// does not silently turn off every other registry-v2 route. For an unknown
  /// route, a selected-mode entry means only that its compatibility test was
  /// requested -- it never becomes an active subagent here.
  static func subagentEnabled(targetModels: [ModelsRoute], slug: String, settings: JSONValue?) -> Bool {
    guard let settings else { return false }
    if settings["disabled"]?.strings.contains(slug) == true { return false }
    guard let route = targetModels.first(where: { $0.slug == slug }), !route.visibleIsFalse else { return false }
    if route.subagentCertification == "v2" { return true }
    return settings["mode"]?.string == "selected" && (settings["enabled"]?.strings.contains(slug) ?? false)
  }

  // MARK: Provider directory

  static func providerConnected(_ entry: ModelsDirectoryEntry, _ enabledProviders: Set<String>) -> Bool {
    if let setup = entry.setup {
      // An anonymous endpoint has no stored account or credential that can
      // make it connected on its own. Its explicit provider selection is the
      // connection boundary instead.
      if setup.kind == "anonymous" { return enabledProviders.contains(entry.id) }
      // The Custom container is always "configured" because it needs no key.
      // It is only a connection once it holds models.
      if setup.kind == "per-model" { return !entry.models.isEmpty }
      return setup.configured || setup.signedIn
    }
    return entry.models.contains(where: { $0.native }) || enabledProviders.contains(entry.id)
  }

  static func catalogEligible(_ entry: ModelsDirectoryEntry) -> Bool {
    guard let setup = entry.setup else { return false }
    return setup.configured && !setup.catalogSources.isEmpty
  }

  static func providerDisplayName(_ providerId: String, _ t: Translator) -> String {
    providerId == "openai" ? t("models.provider.openaiNative") : providerId
  }

  static func launcherSummary(_ entry: ModelsDirectoryEntry, endpointCount: Int, _ t: Translator) -> String {
    var parts: [String] = []
    if endpointCount > 0 {
      parts.append(t(endpointCount == 1 ? "customEndpoint.endpointCountOne" : "customEndpoint.endpointCount", ["count": endpointCount]))
    }
    if !entry.models.isEmpty {
      parts.append(t(entry.models.count == 1 ? "customEndpoint.modelCountOne" : "customEndpoint.modelCount", ["count": entry.models.count]))
    }
    return parts.isEmpty ? t("customEndpoint.bringYourOwn") : parts.joined(separator: " · ")
  }

  static func connectionMethod(_ entry: ModelsDirectoryEntry, _ t: Translator) -> String {
    if entry.id == "openai" { return t("models.method.chatgpt") }
    if entry.id == "local" { return t("models.method.local") }
    guard let setup = entry.setup else { return t("models.method.managed") }
    if setup.action == "probe" { return t("models.method.liveTest") }
    if setup.action == "blocked" { return t("models.method.disconnectRequired") }
    if setup.kind == "oauth" { return t("models.method.signIn") }
    if setup.kind == "configuration" { return t("models.method.localConfig") }
    if setup.kind == "anonymous" { return t("models.method.noKey") }
    if setup.generic { return t("customEndpoint.method") }
    if setup.kind == "per-model" { return t("customEndpoint.addMethod") }
    if setup.signIn { return t("models.method.keyOrSignIn") }
    return nonEmpty(t.backend(setup.credentialLabel), or: t("models.method.apiKey"))
  }

  static func connectionDetail(
    _ entry: ModelsDirectoryEntry,
    _ t: Translator,
    accountStatus: String?,
    accountMessage: String?,
    canOpenTerminal: Bool
  ) -> String {
    if entry.id == "openai" { return t("models.detail.openai") }
    guard let setup = entry.setup else { return t("models.detail.managed") }
    if setup.kind == "configuration" {
      if setup.configured { return t("models.detail.configReady") }
      return nonEmpty(t.backend(setup.configurationNote), or: t("models.detail.configRun"))
    }
    if setup.kind == "anonymous" { return t("models.detail.anonymous") }
    if setup.action == "probe" { return nonEmpty(t.backend(setup.probeNote), or: t("models.detail.probe")) }
    if setup.action == "blocked" { return nonEmpty(t.backend(setup.blockedNote), or: t("models.detail.blocked")) }
    if accountStatus == "unavailable" { return nonEmpty(accountMessage ?? "", or: t("models.detail.unavailable")) }
    if setup.configured { return t("models.detail.credentialReady") }
    if setup.kind == "oauth" {
      if !canOpenTerminal { return t("models.detail.oauthTerminal") }
      return setup.cliInstalled == false ? t("models.detail.oauthInstall") : t("models.detail.oauthSignIn")
    }
    let credential = nonEmpty(t.backend(setup.credentialLabel), or: t("models.detail.anApiKey"))
    if setup.signIn { return t("models.detail.keyOrBrowser", ["credential": credential]) }
    return t("models.detail.addKey", ["credential": credential])
  }

  // MARK: Route kind (model-catalog-search.mjs)

  static func routeProviderId(_ model: ModelsRoute) -> String {
    let slug = trimmed(model.slug)
    if let slash = slug.firstIndex(of: "/"), slash > slug.startIndex {
      return String(slug[slug.startIndex..<slash])
    }
    return ""
  }

  /// Fixed English descriptions, as the renderer's `modelRouteKind` has no
  /// message ids for them.
  static func routeKind(_ model: ModelsRoute) -> String {
    if model.native { return "Native Codex route" }
    let routeProvider = routeProviderId(model)
    if routeProvider.hasSuffix("-messages") { return "Messages API route" }
    if routeProvider.hasSuffix("-responses") { return "Responses API route" }
    if routeProvider.contains("oauth") { return "OAuth route" }
    if model.isFree { return "Free provider route" }
    return "Provider API route"
  }

  // MARK: Catalog discovery (model-catalog-search.mjs)

  static func catalogModelName(_ modelId: String) -> String {
    let parts = trimmed(modelId).split(whereSeparator: { $0 == "/" || $0 == "_" || $0 == "-" })
    let words: [String] = parts.map { part in
      guard let first = part.first else { return "" }
      if first >= "0" && first <= "9" { return part.uppercased() }
      return first.uppercased() + part.dropFirst()
    }
    return words.joined(separator: " ")
  }

  /// Flattens every source that has actually been loaded so the picker's
  /// search can see candidates before they have been curated.
  static func loadedCatalogModels(
    directory: [ModelsDirectoryEntry],
    catalogStates: [String: ModelsCatalogState]
  ) -> [ModelsCatalogModel] {
    var results: [ModelsCatalogModel] = []
    for entry in directory {
      guard let setup = entry.setup else { continue }
      // Renderer state can outlive the setup snapshot that made it eligible.
      // Once a credential is removed, never let that previous account's
      // models remain searchable.
      if setup.json["configured"]?.bool == false { continue }
      for source in setup.catalogSources {
        guard let catalog = catalogStates[source.id]?.data,
          let discovered = catalog["discovered"]?.array
        else { continue }
        let registered = Set(catalog["registered"]?.strings ?? [])
        let unregistered = catalog["unregistered"]?.strings ?? []
        let addable: Set<String>
        if let list = catalog["addable"]?.array {
          addable = Set(list.compactMap { $0.string })
        } else {
          addable = Set(unregistered)
        }
        let free = Set(catalog["free"]?.strings ?? [])
        for item in discovered {
          let id = trimmed(item.string ?? "")
          if id.isEmpty { continue }
          let metadata = catalog["metadata"]?[id]
          let blockedReason = trimmed(catalog["blocked"]?[id]?.string ?? "")
          let contextWindow = metadata?["contextWindow"]?.double ?? catalog["contextLengths"]?[id]?.double
          let providerName = trimmed(entry.displayName)
          let sourceName = trimmed(source.displayName)
          results.append(
            ModelsCatalogModel(
              key: "\(source.id)\u{0}\(id)",
              modelId: id,
              displayName: catalogModelName(id),
              providerId: trimmed(entry.id),
              providerName: providerName.isEmpty ? trimmed(entry.id) : providerName,
              sourceId: trimmed(source.id),
              sourceName: sourceName.isEmpty ? trimmed(source.id) : sourceName,
              registered: registered.contains(id),
              addable: addable.contains(id),
              blockedReason: blockedReason.isEmpty ? nil : blockedReason,
              contextWindow: contextWindow,
              isFree: free.contains(id) || id == "big-pickle" || id.hasSuffix("-free")
            )
          )
        }
      }
    }
    return stableSorted(results) { left, right in
      var result = compare(left.displayName, right.displayName)
      if result == 0 { result = compare(left.providerName, right.providerName) }
      if result == 0 { result = compare(left.sourceName, right.sourceName) }
      if result == 0 { result = compare(left.modelId, right.modelId) }
      return result
    }
  }

  // MARK: Pending catalog models

  private static func changePending(_ current: ModelsPending, provider: String, modelIds: [String], delta: Int) -> ModelsPending {
    let providerId = trimmed(provider)
    if providerId.isEmpty || modelIds.isEmpty { return current }
    var counts = current[providerId] ?? [:]
    for raw in modelIds {
      let modelId = trimmed(raw)
      if modelId.isEmpty { continue }
      let count = max(0, (counts[modelId] ?? 0) + delta)
      if count > 0 { counts[modelId] = count } else { counts.removeValue(forKey: modelId) }
    }
    var next = current
    if counts.isEmpty { next.removeValue(forKey: providerId) } else { next[providerId] = counts }
    return next
  }

  /// Counts keep one completion from clearing another operation's
  /// placeholder, including two adds of the same id.
  static func addPending(_ current: ModelsPending, provider: String, modelIds: [String]) -> ModelsPending {
    changePending(current, provider: provider, modelIds: modelIds, delta: 1)
  }

  static func removePending(_ current: ModelsPending, provider: String, modelIds: [String]) -> ModelsPending {
    changePending(current, provider: provider, modelIds: modelIds, delta: -1)
  }

  static func pendingIds(_ current: ModelsPending, provider: String) -> [String] {
    (current[provider] ?? [:]).filter { $0.value > 0 }.map { $0.key }.sorted()
  }
}

// MARK: - Page data

/// Everything the page derives from the router's snapshots, computed once per
/// change of those snapshots.
struct ModelsPageData {
  var targetModels: [ModelsRoute] = []
  var models: [ModelsRoute] = []
  var enabledProviders: Set<String> = []
  var subagentSettings: JSONValue?
  var families: [ModelsFamily] = []
  var usageById: [String: JSONValue] = [:]
  var directory: [ModelsDirectoryEntry] = []
  var directoryById: [String: ModelsDirectoryEntry] = [:]
  var providerNames: [String: String] = [:]
  var providerStates: [String: Bool] = [:]
  var filterProviders: [ModelsDirectoryEntry] = []
  var pickerStates: [String: Bool] = [:]
  var subagentStates: [String: Bool] = [:]
  var subagentEfforts: [String: String] = [:]

  /// External model identity and picker visibility come from the router-owned
  /// catalog. Native entries remain a Codex-only adapter concern and are
  /// merged in for the convenience of the Codex client view.
  static func build(
    target rawTarget: JSONValue?,
    catalog rawCatalog: JSONValue?,
    setup rawSetup: JSONValue?,
    usage rawUsage: JSONValue?,
    t: Translator
  ) -> ModelsPageData {
    let target = ModelsLogic.present(rawTarget)
    let catalog = ModelsLogic.present(rawCatalog)
    let setup = ModelsLogic.present(rawSetup)
    let usage = ModelsLogic.present(rawUsage)
    var data = ModelsPageData()

    let clientModels: [ModelsRoute] = (target?["models"]?.items ?? []).map { ModelsRoute($0) }
    data.targetModels = clientModels
    if catalog != nil {
      let nativeModels = clientModels.filter { $0.native }
      let seen = Set(nativeModels.map { $0.slug })
      let catalogModels: [ModelsRoute] = (catalog?["models"]?.items ?? []).map { ModelsRoute($0) }
      data.models = nativeModels + catalogModels.filter { !seen.contains($0.slug) }
    } else {
      data.models = clientModels
    }

    let enabledSource = ModelsLogic.present(catalog?["enabledProviders"]) ?? ModelsLogic.present(target?["enabledProviders"])
    data.enabledProviders = Set(enabledSource?.strings ?? [])
    data.subagentSettings = ModelsLogic.present(catalog?["subagents"])
      ?? ModelsLogic.present(target?["modelSettings"]?["subagents"])

    // One list covers configured routes and routes that are only known to the
    // registry. A model nobody can reach yet is still the answer to "can I use
    // this model", so it stays on the page with the connection it is waiting
    // for.
    let activeSlugs = Set(data.models.map { $0.slug })
    let knownItems: [JSONValue] = catalog?["knownModels"]?.items ?? []
    var allModels = data.models
    for known in knownItems {
      let slug = known["slug"]?.string ?? ""
      if activeSlugs.contains(slug) { continue }
      var object = known.object ?? [:]
      object["enabled"] = .bool(false)
      object["visible"] = .bool(false)
      object["available"] = .bool(false)
      object["subagentCertification"] = .string("unknown")
      allModels.append(ModelsRoute(.object(object)))
    }
    data.families = ModelsLogic.groupFamilies(allModels)

    for provider in usage?["providers"]?.items ?? [] {
      if let id = provider["id"]?.string { data.usageById[id] = provider }
    }

    data.directory = buildDirectory(
      setup: setup,
      target: target,
      catalogKnown: knownItems,
      models: data.models,
      enabledProviders: data.enabledProviders,
      t: t
    )
    for entry in data.directory {
      data.directoryById[entry.id] = entry
      data.providerNames[entry.id] = entry.displayName
      data.providerStates[entry.id] = data.enabledProviders.contains(entry.id) || entry.models.contains(where: { $0.native })
    }

    let routed = Set(data.families.flatMap { family in family.routes.map { $0.provider } })
    data.filterProviders = data.directory.filter { routed.contains($0.id) }

    for route in data.models {
      data.pickerStates[route.slug] = route.visible
      data.subagentStates[route.slug] = ModelsLogic.subagentEnabled(
        targetModels: data.targetModels,
        slug: route.slug,
        settings: data.subagentSettings
      )
      data.subagentEfforts[route.slug] = data.subagentSettings?["efforts"]?[route.slug]?.string ?? "default"
    }
    return data
  }

  private static func buildDirectory(
    setup: JSONValue?,
    target: JSONValue?,
    catalogKnown: [JSONValue],
    models: [ModelsRoute],
    enabledProviders: Set<String>,
    t: Translator
  ) -> [ModelsDirectoryEntry] {
    var order: [String] = []
    var entries: [String: ModelsDirectoryEntry] = [:]
    func put(_ entry: ModelsDirectoryEntry) {
      if entries[entry.id] == nil { order.append(entry.id) }
      entries[entry.id] = entry
    }

    let providers: [JSONValue] = (setup?["providers"]?.items ?? []) + (setup?["customEndpoints"]?.items ?? [])
    for provider in providers {
      guard let id = provider["id"]?.string else { continue }
      put(ModelsDirectoryEntry(
        id: id,
        displayName: provider["displayName"]?.string ?? "",
        setup: ModelsSetup(json: provider),
        models: [],
        knownModels: []
      ))
    }
    for provider in target?["providers"]?.items ?? [] {
      guard let id = provider["id"]?.string else { continue }
      let current = entries[id]
      put(ModelsDirectoryEntry(
        id: id,
        displayName: ModelsLogic.nonEmpty(current?.displayName ?? "", or: provider["displayName"]?.string ?? ""),
        setup: current?.setup,
        models: current?.models ?? [],
        knownModels: current?.knownModels ?? []
      ))
    }
    for model in models {
      let current = entries[model.provider]
      put(ModelsDirectoryEntry(
        id: model.provider,
        displayName: ModelsLogic.nonEmpty(current?.displayName ?? "", or: ModelsLogic.providerDisplayName(model.provider, t)),
        setup: current?.setup,
        models: (current?.models ?? []) + [model],
        knownModels: current?.knownModels ?? []
      ))
    }
    for known in catalogKnown {
      let providerId = known["provider"]?.string ?? ""
      let current = entries[providerId]
      put(ModelsDirectoryEntry(
        id: providerId,
        displayName: ModelsLogic.nonEmpty(current?.displayName ?? "", or: ModelsLogic.providerDisplayName(providerId, t)),
        setup: current?.setup,
        models: current?.models ?? [],
        knownModels: (current?.knownModels ?? []) + [known]
      ))
    }
    let all: [ModelsDirectoryEntry] = order.compactMap { entries[$0] }
    return ModelsLogic.stableSorted(all) { left, right in
      let leftConnected = ModelsLogic.providerConnected(left, enabledProviders)
      let rightConnected = ModelsLogic.providerConnected(right, enabledProviders)
      if leftConnected != rightConnected { return rightConnected ? 1 : -1 }
      return ModelsLogic.compare(left.displayName, right.displayName)
    }
  }
}

/// Memoizes `ModelsPageData` across the once-a-second health re-renders.
final class ModelsDataCache {
  struct Key: Equatable {
    let target: JSONValue?
    let catalog: JSONValue?
    let setup: JSONValue?
    let usage: JSONValue?
    let language: String
  }

  private var key: Key?
  private var cached = ModelsPageData()

  func resolve(_ next: Key, build: () -> ModelsPageData) -> ModelsPageData {
    if key == next { return cached }
    let built = build()
    key = next
    cached = built
    return built
  }
}
