import ControlCenterCore
import Foundation
import SwiftUI

/// The dialogs the page presents. One at a time, as the renderer's `Dialog`
/// components were mutually exclusive in practice.
enum ModelsSheet: Identifiable {
  case addModels(query: String)
  case endpointNotice(id: String, displayName: String, reason: String)
  case namedModel(ModelsSetup)
  case customEndpoint(editing: ModelsSetup?)
  case credential(ModelsSetup)
  case configuration(ModelsSetup)
  case disconnect(ModelsSetup)
  case removeLocal(ModelsRoute)

  var id: String {
    switch self {
    case .addModels: return "add-models"
    case .endpointNotice: return "endpoint-notice"
    case .namedModel: return "named-model"
    case .customEndpoint: return "custom-endpoint"
    case .credential: return "credential"
    case .configuration: return "configuration"
    case .disconnect: return "disconnect"
    case .removeLocal: return "remove-local"
    }
  }
}

/// The page's asynchronous state and the router flows that change it: catalog
/// discovery, model publication, and credential transactions. Everything runs
/// on the main actor, so a router answer can never publish from a background
/// thread.
@MainActor
final class ModelsStore: ObservableObject {
  @Published private(set) var catalogStates: [String: ModelsCatalogState] = [:]
  /// Bumped on every catalog-state change so views can cache derived lists.
  @Published private(set) var catalogVersion = 0
  /// Slugs committed to the picker but not yet published, per provider.
  /// Adding republishes the whole catalog to every installed client, which is
  /// the slowest thing this page starts; without a placeholder the models
  /// simply are not there for the length of it and the click reads as having
  /// done nothing.
  @Published private(set) var pendingModels: ModelsPending = [:]
  /// The credential dialog closes on submit, and the command behind it runs
  /// for as long as publication takes. Without this the page is identical
  /// either side of the key being accepted, so the wait reads as a click that
  /// did nothing.
  @Published private(set) var providerMutations: [String: ModelsProviderMutation] = [:]
  @Published private(set) var loadingConnectedCatalogs = false
  @Published var sheet: ModelsSheet?
  /// Set once a new endpoint is saved; the model picker opens as soon as the
  /// refreshed snapshot shows that endpoint with a catalog to browse.
  @Published var awaitingEndpointId: String?

  /// Discovery reads are intentionally not serialized with credential
  /// mutations: a provider can take tens of seconds to answer and must not
  /// hold the mutation queue that stores or removes a key. A per-source
  /// generation makes that safe. Replacing a credential invalidates the
  /// generation captured by every earlier read, so an old account's eventual
  /// response cannot repopulate state.
  private var generations: [String: Int] = [:]

  // MARK: Catalog generations

  private func beginRequest(_ sourceId: String) -> Int {
    let source = ModelsLogic.trimmed(sourceId)
    if source.isEmpty { return 0 }
    let next = max(0, generations[source] ?? 0) + 1
    generations[source] = next
    return next
  }

  private func requestIsCurrent(_ sourceId: String, _ generation: Int) -> Bool {
    let source = ModelsLogic.trimmed(sourceId)
    return !source.isEmpty && generation > 0 && generations[source] == generation
  }

  /// Drops the matching copies at the same success boundary a credential
  /// mutation invalidates the router's persistent catalog, so global search
  /// cannot keep showing the previous account.
  private func invalidateCatalogs(_ sources: [ModelsCatalogSource]) {
    var changed = false
    for source in sources {
      _ = beginRequest(source.id)
      let id = ModelsLogic.trimmed(source.id)
      if !id.isEmpty, catalogStates[id] != nil {
        catalogStates.removeValue(forKey: id)
        changed = true
      }
    }
    if changed { catalogVersion += 1 }
  }

  private func updateCatalogState(_ sourceId: String, _ update: (inout ModelsCatalogState) -> Void) {
    var state = catalogStates[sourceId] ?? ModelsCatalogState()
    update(&state)
    catalogStates[sourceId] = state
    catalogVersion += 1
  }

  // MARK: Credential transactions

  /// Runs one credential command with the provider marked as connecting (or
  /// disconnecting) for as long as it takes. `runAction` reconciles the
  /// snapshot before it resolves -- on failure too -- so the busy state ends
  /// on a render that already carries the outcome.
  func runProviderCredentialAction(
    _ model: AppModel,
    provider: ModelsSetup,
    label: String,
    intent: ModelsProviderMutation = .connecting,
    action: @escaping (RouterControl) async throws -> Void
  ) async {
    let sources = provider.catalogSources
    let providerId = provider.id
    let api = model.api
    // Clear at both boundaries. The command may have changed the credential
    // before a later refresh/publish step rejects, and a discovery that lands
    // while the mutation is running must not show the previous account.
    invalidateCatalogs(sources)
    providerMutations[providerId] = intent
    await model.runAction(label) {
      try await action(api)
      return JSONValue.null
    }
    invalidateCatalogs(sources)
    providerMutations.removeValue(forKey: providerId)
  }

  // MARK: Catalog discovery

  func discoverCatalog(
    _ model: AppModel,
    entry: ModelsDirectoryEntry,
    sourceId: String,
    refresh: Bool = false,
    keepOnFailure: Bool = false
  ) async {
    guard ModelsLogic.catalogEligible(entry), !sourceId.isEmpty else { return }
    let generation = beginRequest(sourceId)
    updateCatalogState(sourceId) { current in
      current.status = .loading
      current.refreshing = refresh && current.data != nil
      current.error = nil
    }
    do {
      let data = try await model.api.discoverProviderModels(sourceId, refresh: refresh)
      guard requestIsCurrent(sourceId, generation) else { return }
      updateCatalogState(sourceId) { current in
        current.status = .ready
        current.refreshing = false
        current.data = data
        current.error = nil
      }
      // A stored list past its trust window is shown immediately and re-read
      // behind it, so a model the provider shipped since the last visit does
      // not stay invisible until somebody thinks to press Reload. A failed
      // re-read leaves the list that is already on screen in place.
      if !refresh && data["stale"].truthy {
        Task { await self.discoverCatalog(model, entry: entry, sourceId: sourceId, refresh: true, keepOnFailure: true) }
      }
    } catch {
      guard requestIsCurrent(sourceId, generation) else { return }
      let message = model.readableError(error)
      updateCatalogState(sourceId) { current in
        if keepOnFailure && current.data != nil {
          current.status = .ready
          current.refreshing = false
        } else {
          current.status = .error
          current.refreshing = false
          current.error = message
        }
      }
    }
  }

  private struct CatalogRequest {
    let entry: ModelsDirectoryEntry
    let sourceId: String
  }

  private func catalogRequests(_ directory: [ModelsDirectoryEntry], _ enabled: Set<String>) -> [CatalogRequest] {
    var requests: [CatalogRequest] = []
    for entry in directory {
      guard ModelsLogic.catalogEligible(entry), ModelsLogic.providerConnected(entry, enabled) else { continue }
      for source in entry.setup?.catalogSources ?? [] {
        requests.append(CatalogRequest(entry: entry, sourceId: source.id))
      }
    }
    return requests
  }

  /// Opening the picker loads every connected provider at once, so one search
  /// box can cover them all. Stored lists answer immediately; only an
  /// explicit reload re-asks the providers.
  func loadConnectedCatalogs(
    _ model: AppModel,
    directory: [ModelsDirectoryEntry],
    enabled: Set<String>,
    refresh: Bool = false
  ) async {
    guard !loadingConnectedCatalogs else { return }
    let requests = catalogRequests(directory, enabled).filter { request in
      refresh || (catalogStates[request.sourceId]?.status ?? .idle) == .idle
    }
    guard !requests.isEmpty else { return }
    loadingConnectedCatalogs = true
    var tasks: [Task<Void, Never>] = []
    for request in requests {
      tasks.append(Task {
        await self.discoverCatalog(model, entry: request.entry, sourceId: request.sourceId, refresh: refresh)
      })
    }
    for task in tasks { await task.value }
    loadingConnectedCatalogs = false
  }

  func openAddModels(_ model: AppModel, directory: [ModelsDirectoryEntry], enabled: Set<String>, query: String = "") {
    sheet = .addModels(query: query)
    Task { await self.loadConnectedCatalogs(model, directory: directory, enabled: enabled) }
  }

  // MARK: Publishing models

  private func publishCatalogModels(_ model: AppModel, entry: ModelsDirectoryEntry, sourceId: String, selected: [String]) async {
    guard !sourceId.isEmpty, !selected.isEmpty else { return }
    let api = model.api
    var published = false
    pendingModels = ModelsLogic.addPending(pendingModels, provider: entry.id, modelIds: selected)
    let label = model.t("models.action.addModels", ["count": selected.count, "name": entry.displayName])
    await model.runAction(label) {
      _ = try await api.addProviderModels(sourceId, selected)
      published = true
      return JSONValue.null
    }
    if published {
      await discoverCatalog(model, entry: entry, sourceId: sourceId)
    }
    // Cleared on failure too: a placeholder left behind after a failed add
    // would claim the model arrived. runAction reports the error itself.
    pendingModels = ModelsLogic.removePending(pendingModels, provider: entry.id, modelIds: selected)
  }

  private struct SourceGroup {
    let entry: ModelsDirectoryEntry
    var modelIds: [String]
  }

  func addCatalogModels(
    _ model: AppModel,
    directoryById: [String: ModelsDirectoryEntry],
    selection: [ModelsCatalogModel]
  ) async {
    var order: [String] = []
    var groups: [String: SourceGroup] = [:]
    for item in selection {
      guard let entry = directoryById[item.providerId] else { continue }
      if var group = groups[item.sourceId] {
        group.modelIds.append(item.modelId)
        groups[item.sourceId] = group
      } else {
        order.append(item.sourceId)
        groups[item.sourceId] = SourceGroup(entry: entry, modelIds: [item.modelId])
      }
    }
    for sourceId in order {
      guard let group = groups[sourceId] else { continue }
      await publishCatalogModels(model, entry: group.entry, sourceId: sourceId, selected: group.modelIds)
    }
  }

  // MARK: Custom endpoints

  private static let endpointFallbackReason = "The endpoint did not respond."

  private func noticeReason(_ check: JSONValue) -> String {
    let reason = check["reason"]?.string ?? ""
    return reason.isEmpty ? Self.endpointFallbackReason : reason
  }

  /// A saved endpoint whose first live check failed is kept -- an unreachable
  /// host is usually a network or key problem the operator fixes next -- so
  /// the notice says what happened and offers the two ways forward.
  func saveEndpoint(_ model: AppModel, endpoint: ModelsEndpointInput, editing: ModelsSetup?) async {
    let api = model.api
    if let editing {
      var check: JSONValue?
      let label = model.t("customEndpoint.action.update", ["name": endpoint.displayName])
      await runProviderCredentialAction(model, provider: editing, label: label) { api in
        let result = try await api.editCustomEndpoint(
          editing.id,
          displayName: endpoint.displayName,
          baseUrl: endpoint.baseUrl,
          adapter: endpoint.adapter
        )
        if let credential = endpoint.credential {
          _ = try await api.saveProviderCredential(editing.id, credential)
        }
        check = result["check"]
      }
      if let failed = check, !failed["ok"].truthy {
        sheet = .endpointNotice(id: editing.id, displayName: endpoint.displayName, reason: noticeReason(failed))
      }
      return
    }
    var saved: JSONValue?
    let label = model.t("customEndpoint.action.add", ["name": endpoint.displayName])
    await model.runAction(label) {
      saved = try await api.addCustomEndpoint(
        displayName: endpoint.displayName,
        baseUrl: endpoint.baseUrl,
        adapter: endpoint.adapter,
        credential: endpoint.credential
      )
      return JSONValue.null
    }
    guard let result = saved else { return }
    Task { await model.refreshAll() }
    let providerId = result["providerId"]?.string ?? ""
    // Only browse a catalog the endpoint just proved it can serve.
    if let failed = result["check"], !failed["ok"].truthy {
      sheet = .endpointNotice(id: providerId, displayName: endpoint.displayName, reason: noticeReason(failed))
      return
    }
    awaitingEndpointId = providerId.isEmpty ? nil : providerId
  }

  func addNamedModel(_ model: AppModel, provider: ModelsSetup, modelId: String) async {
    let api = model.api
    let providerId = provider.id
    let label = model.t("customEndpoint.action.addModel", ["model": "\(providerId)/\(modelId)"])
    await model.runAction(label) {
      try await api.addCustomEndpointModel(providerId, modelId)
    }
  }
}
