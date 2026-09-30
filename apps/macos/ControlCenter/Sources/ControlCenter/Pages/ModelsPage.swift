import ControlCenterCore
import SwiftUI

/// The Models page: provider connections, the model catalog (one row per
/// model family, expanding to its provider routes), the model picker, and the
/// subagent settings. Ported from `ModelsPage.tsx`.
///
/// The pieces live in `Pages/Models/`: `ModelsData.swift` (families, catalog
/// search, directory), `ModelsStore.swift` (discovery, publication, and
/// credential flows), `ModelsConnections.swift` (the connections strip),
/// `ModelsFamilyRows.swift` (the list), `ModelsAddSheet.swift`, and
/// `ModelsDialogs.swift`.
struct ModelsPage: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var store = ModelsStore()
  // The router-owned switches respond at once and settle to its answer.
  @StateObject private var optimisticProviders = OptimisticValues<Bool>()
  @StateObject private var optimisticPicker = OptimisticValues<Bool>()
  @StateObject private var optimisticSubagents = OptimisticValues<Bool>()
  @StateObject private var optimisticEfforts = OptimisticValues<String>()
  @State private var modelSearch = ""
  @State private var statusFilter = ModelsStatusFilter.all
  @State private var providerFilter = "all"
  // The connect menu lives in the connections strip but is also the first-run
  // call to action, so the page owns whether it is open.
  @State private var connectMenuOpen = false
  @State private var expandedFamilyId: String?
  @State private var managedProviderId: String?
  @State private var dataCache = ModelsDataCache()

  private static let providersAnchor = "model-provider-directory"
  private static let catalogAnchor = "model-catalog-controls"

  // MARK: Body

  var body: some View {
    let data = currentData()
    ScrollViewReader { proxy in
      pageContent(data)
        .onChange(of: model.modelFocusRequest) { request in
          scrollToFocus(request, proxy: proxy)
        }
        .onAppear {
          scrollToFocus(model.modelFocusRequest, proxy: proxy)
        }
    }
    .onChange(of: data.providerStates) { optimisticProviders.reconcile(with: $0) }
    .onChange(of: data.pickerStates) { optimisticPicker.reconcile(with: $0) }
    .onChange(of: data.subagentStates) { optimisticSubagents.reconcile(with: $0) }
    .onChange(of: data.subagentEfforts) { optimisticEfforts.reconcile(with: $0) }
    .onChange(of: awaitingKey(data)) { _ in openAwaitingEndpoint(data) }
    .sheet(item: $store.sheet) { sheet in
      sheetContent(sheet, data: data)
        .environmentObject(model)
    }
  }

  private func currentData() -> ModelsPageData {
    let catalog = model.snapshot?["catalog"]
    let target = model.target
    let setup = model.providers
    let usage = model.providerUsage
    let t = model.t
    let key = ModelsDataCache.Key(target: target, catalog: catalog, setup: setup, usage: usage, language: t.language)
    return dataCache.resolve(key) {
      ModelsPageData.build(target: target, catalog: catalog, setup: setup, usage: usage, t: t)
    }
  }

  private func scrollToFocus(_ request: ModelFocusRequest?, proxy: ScrollViewProxy) {
    guard let request else { return }
    let anchor = request.region == "providers" ? Self.providersAnchor : Self.catalogAnchor
    DispatchQueue.main.async {
      proxy.scrollTo(anchor, anchor: .top)
    }
  }

  // MARK: Page

  @ViewBuilder
  private func pageContent(_ data: ModelsPageData) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        eyebrow: model.t("models.eyebrow"),
        title: model.t("models.title"),
        description: model.t("models.description"),
        onRefresh: { Task { await model.refreshAll() } }
      )
      connectionsSection(data)
        .id(Self.providersAnchor)
      if model.target != nil {
        catalogSection(data)
          .id(Self.catalogAnchor)
      } else if !model.isReady(.snapshot) {
        PanelSkeleton(label: model.t("models.loading.routes"), count: 6)
          .panelStyle(padding: 12)
          .accessibilityElement(children: .contain)
          .accessibilityLabel(model.t("models.loading.models"))
      } else {
        EmptyStateView(
          systemImage: "magnifyingglass",
          title: model.t("models.snapshotUnavailable"),
          message: model.t("models.snapshotUnavailableBody")
        )
      }
    }
  }

  // MARK: Connections

  @ViewBuilder
  private func connectionsSection(_ data: ModelsPageData) -> some View {
    if !model.isReady(.providers) && model.providers == nil {
      VStack(spacing: 8) {
        SkeletonBlock()
        SkeletonBlock()
        SkeletonBlock()
      }
      .panelStyle(padding: 12)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.t("models.loading.connections"))
    } else {
      ModelsConnectionsBar(
        directory: data.directory,
        enabledProviders: data.enabledProviders,
        pendingMutations: store.providerMutations,
        usageById: data.usageById,
        openProviderId: managedProviderId,
        connectMenuOpen: $connectMenuOpen,
        isEnabled: { isEnabled($0, data) },
        onOpenProvider: { openProviderMenu($0) },
        onCloseProvider: { managedProviderId = nil },
        onEnabledChange: { setProviderEnabled($0, $1) },
        onSignIn: { signIn($0) },
        onConfigure: { entry in
          if let setup = entry.setup { present(.configuration(setup)) }
        },
        onKey: { entry in
          if let setup = entry.setup { present(.credential(setup)) }
        },
        onRemove: { entry in
          if let setup = entry.setup { present(.disconnect(setup)) }
        },
        onAddEndpoint: { present(.customEndpoint(editing: nil)) },
        onEditEndpoint: { entry in
          if let setup = entry.setup { present(.customEndpoint(editing: setup)) }
        },
        onAddEndpointModels: { entry in
          afterMenuCloses { store.openAddModels(model, directory: data.directory, enabled: data.enabledProviders, query: entry.displayName) }
        },
        onAddNamedModel: { entry in
          if let setup = entry.setup { present(.namedModel(setup)) }
        },
        onRemoveEndpointModel: { entry, route in removeEndpointModel(entry, route) }
      )
    }
  }

  private func isEnabled(_ entry: ModelsDirectoryEntry, _ data: ModelsPageData) -> Bool {
    let authoritative: Bool
    if let setup = entry.setup, setup.generic {
      authoritative = setup.enabled != false
    } else {
      authoritative = data.enabledProviders.contains(entry.id) || entry.models.contains(where: { $0.native })
    }
    return optimisticProviders.value(entry.id, fallback: authoritative)
  }

  private func openProviderMenu(_ providerId: String) {
    managedProviderId = managedProviderId == providerId ? nil : providerId
  }

  /// A dialog cannot present while the popover it was launched from is still
  /// dismissing, so menu-originated dialogs wait for it to finish.
  private func afterMenuCloses(_ work: @escaping @MainActor () -> Void) {
    managedProviderId = nil
    connectMenuOpen = false
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 180_000_000)
      work()
    }
  }

  private func present(_ sheet: ModelsSheet) {
    afterMenuCloses { store.sheet = sheet }
  }

  private func setProviderEnabled(_ entry: ModelsDirectoryEntry, _ checked: Bool) {
    let id = entry.id
    let label = checked
      ? model.t("models.action.enableProvider", ["name": entry.displayName])
      : model.t("models.action.disableProvider", ["name": entry.displayName])
    optimisticProviders.mutate(id, to: checked, label: label, model: model) { api in
      try await api.setProviderEnabled(id, checked)
    }
  }

  private func signIn(_ entry: ModelsDirectoryEntry) {
    guard let setup = entry.setup else { return }
    let id = entry.id
    let label = setup.action == "probe"
      ? model.t("models.action.runProbe", ["name": entry.displayName])
      : model.t("models.action.startSignIn", ["name": entry.displayName])
    Task {
      await store.runProviderCredentialAction(model, provider: setup, label: label) { api in
        _ = try await api.connectProvider(id)
      }
    }
  }

  private func removeEndpointModel(_ entry: ModelsDirectoryEntry, _ route: ModelsRoute) {
    let entryId = entry.id
    let slug = route.slug
    model.perform(model.t("customEndpoint.action.removeModel", ["name": route.displayName])) { api in
      try await api.removeCustomEndpointModels(entryId, [slug])
    }
  }

  // MARK: Catalog section

  private struct RowSet {
    var all: [ModelsFamilyRowData] = []
    var visible: [ModelsFamilyRowData] = []
    var ready: [ModelsFamilyRowData] = []
    var blocked: [ModelsFamilyRowData] = []
  }

  private struct ProviderOption: Identifiable {
    let id: String
    let name: String
  }

  /// A filter whose chip is not on screen -- because the provider left the
  /// list, or because there are too few providers left to warrant the chip --
  /// would go on narrowing the list with nothing there to undo it.
  private func activeProviderFilter(_ data: ModelsPageData) -> String {
    let crowded = data.filterProviders.count > ModelsLogic.crowdedProviders
    if crowded && data.filterProviders.contains(where: { $0.id == providerFilter }) {
      return providerFilter
    }
    return "all"
  }

  private func filteredFamilies(_ data: ModelsPageData, active: String) -> [ModelsFamily] {
    let needle = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if needle.isEmpty && active == "all" { return data.families }
    let t = model.t
    return data.families.filter { family in
      if active != "all" && !family.routes.contains(where: { $0.provider == active }) { return false }
      if needle.isEmpty { return true }
      var parts: [String] = []
      for route in family.routes {
        parts.append("\(route.displayName) \(route.slug) \(ModelsLogic.providerDisplayName(route.provider, t))")
      }
      return "\(family.displayName) \(parts.joined(separator: " "))".lowercased().contains(needle)
    }
  }

  /// Row order never depends on a switch. Sorting by on/off would throw the
  /// row you just clicked to the other end of the list, at the exact moment
  /// you are looking at it to confirm the click did what you meant.
  private func rowSet(_ data: ModelsPageData, active: String) -> RowSet {
    var result = RowSet()
    for family in filteredFamilies(data, active: active) {
      let usable = family.routes.filter { ModelsLogic.routeUsable($0) }
      let inPicker = usable.filter { optimisticPicker.value($0.slug, fallback: $0.visible) }
      result.all.append(ModelsFamilyRowData(family: family, usable: usable, inPicker: inPicker, on: !inPicker.isEmpty))
    }
    for row in result.all {
      switch statusFilter {
      case .all: result.visible.append(row)
      case .blocked: if row.usable.isEmpty { result.visible.append(row) }
      case .on: if !row.usable.isEmpty && row.on { result.visible.append(row) }
      case .off: if !row.usable.isEmpty && !row.on { result.visible.append(row) }
      }
    }
    for row in result.visible {
      if row.usable.isEmpty { result.blocked.append(row) } else { result.ready.append(row) }
    }
    return result
  }

  private func pendingSlugs(_ data: ModelsPageData) -> [String] {
    var slugs: [String] = []
    for entry in data.directory {
      for slug in ModelsLogic.pendingIds(store.pendingModels, provider: entry.id) {
        if !entry.models.contains(where: { $0.slug == slug }) { slugs.append(slug) }
      }
    }
    return slugs
  }

  private func catalogSection(_ data: ModelsPageData) -> some View {
    let active = activeProviderFilter(data)
    let rows = rowSet(data, active: active)
    let connectedCount = data.directory.filter { ModelsLogic.providerConnected($0, data.enabledProviders) }.count
    let filtered = !modelSearch.isEmpty || statusFilter != .all || active != "all"
    return VStack(alignment: .leading, spacing: 12) {
      toolbar(data, rows: rows, active: active, connectedCount: connectedCount, filtered: filtered)
      listArea(data, rows: rows, connectedCount: connectedCount, filtered: filtered)
    }
    .panelStyle(padding: 12)
  }

  // MARK: Toolbar

  private func statusLabel(_ value: ModelsStatusFilter) -> String {
    switch value {
    case .all: return model.t("models.status.all")
    case .on: return model.t("models.status.on")
    case .off: return model.t("models.status.off")
    case .blocked: return model.t("models.status.blocked")
    }
  }

  private func toolbar(
    _ data: ModelsPageData,
    rows: RowSet,
    active: String,
    connectedCount: Int,
    filtered: Bool
  ) -> some View {
    // The count describes the list underneath it. Reporting the whole
    // catalogue while a filter is narrowing the view made the filter look
    // broken.
    let count = filtered
      ? model.t("models.resultsCount", ["shown": rows.visible.count, "total": data.families.count])
      : model.t("models.resultsCountAll", ["total": data.families.count])
    // A short list reads whole. Filters and bulk switches only earn their
    // space once scrolling starts.
    let crowded = rows.all.count > ModelsLogic.crowdedList
    // Which account serves a model matters most where several of them serve
    // overlapping catalogues; below that the list already names the provider
    // on every row.
    let providerCrowded = data.filterProviders.count > ModelsLogic.crowdedProviders
    return HStack(spacing: 10) {
      SearchField(text: $modelSearch, placeholder: model.t("models.searchModels"))
      Text(count)
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      if crowded { statusMenu }
      if providerCrowded { providerMenu(data, active: active) }
      bulkMenu(data)
      Button {
        store.openAddModels(model, directory: data.directory, enabled: data.enabledProviders)
      } label: {
        Label(model.t("models.addModels"), systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .disabled(connectedCount == 0)
    }
  }

  private var statusMenu: some View {
    Menu {
      ForEach(ModelsStatusFilter.allCases) { value in
        Button {
          statusFilter = value
        } label: {
          if statusFilter == value {
            Label(statusLabel(value), systemImage: "checkmark")
          } else {
            Text(statusLabel(value))
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease")
        Text(model.t("models.show"))
        Text(statusLabel(statusFilter)).fontWeight(.semibold)
      }
    }
    .fixedSize()
    .accessibilityLabel(model.t("models.filterAria"))
  }

  private func providerMenu(_ data: ModelsPageData, active: String) -> some View {
    let allLabel = model.t("models.allProviders")
    var options = [ProviderOption(id: "all", name: allLabel)]
    for entry in data.filterProviders { options.append(ProviderOption(id: entry.id, name: entry.displayName)) }
    let activeName = active == "all"
      ? allLabel
      : ModelsLogic.nonEmpty(data.providerNames[active] ?? "", or: active)
    return Menu {
      ForEach(options) { option in
        Button {
          providerFilter = option.id
        } label: {
          if active == option.id {
            Label(option.name, systemImage: "checkmark")
          } else {
            Text(option.name)
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "line.3.horizontal.decrease")
        Text(model.t("models.provider"))
        Text(activeName).fontWeight(.semibold)
      }
    }
    .fixedSize()
    .accessibilityLabel(model.t("models.filterByProviderAria"))
  }

  private func bulkMenu(_ data: ModelsPageData) -> some View {
    Menu {
      Button(model.t("models.turnAllOn")) { setAllPicker(true, data) }
      Button(model.t("models.turnAllOff")) { setAllPicker(false, data) }
    } label: {
      Image(systemName: "ellipsis")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help(model.t("models.moreActions"))
    .accessibilityLabel(model.t("models.moreActions"))
  }

  private func setAllPicker(_ visible: Bool, _ data: ModelsPageData) {
    var changes: [(String, Bool)] = []
    for route in data.models where !ModelsLogic.nativeClientManaged(route) {
      changes.append((route.slug, visible))
    }
    let label = visible ? model.t("models.action.showAll") : model.t("models.action.hideAll")
    optimisticPicker.mutateMany(changes, label: label, model: model) { api in
      try await api.setPickerModels(showAll: visible)
    }
  }

  // MARK: List

  @ViewBuilder
  private func listArea(_ data: ModelsPageData, rows: RowSet, connectedCount: Int, filtered: Bool) -> some View {
    let pending = pendingSlugs(data)
    if connectedCount == 0 && data.families.isEmpty {
      EmptyStateView(
        systemImage: "plus",
        title: model.t("models.connectToGetStarted"),
        message: model.t("models.connectToGetStartedBody"),
        action: {
          Button(model.t("models.connectProvider")) { connectMenuOpen = true }
            .buttonStyle(.borderedProminent)
        }
      )
    } else if !rows.ready.isEmpty || !rows.blocked.isEmpty || !pending.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        if !rows.ready.isEmpty || !pending.isEmpty {
          familyList(rows.ready, pending: pending, data: data)
        }
        if !rows.blocked.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
              Text(model.t("models.needsProvider"))
                .font(.system(size: 13, weight: .semibold))
              Text("\(rows.blocked.count)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            familyList(rows.blocked, pending: [], data: data)
          }
        }
      }
    } else {
      EmptyStateView(
        systemImage: "magnifyingglass",
        title: model.t("models.noMatch"),
        message: filtered ? model.t("models.noMatchFilteredBody") : model.t("models.noMatchBody")
      )
    }
  }

  private func familyList(_ rows: [ModelsFamilyRowData], pending: [String], data: ModelsPageData) -> some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      if !pending.isEmpty {
        ModelsPendingRows(slugs: pending)
        Divider()
      }
      ForEach(rows) { row in
        familyRow(row, data)
        Divider()
      }
    }
    .panelStyle()
  }

  private func familyRow(_ row: ModelsFamilyRowData, _ data: ModelsPageData) -> some View {
    let values = ModelsRowValues(
      providerNames: data.providerNames,
      isConnecting: { store.providerMutations[$0] == .connecting },
      pickerValue: { optimisticPicker.value($0.slug, fallback: $0.visible) },
      subagentValue: { route in
        let enabled = ModelsLogic.subagentEnabled(
          targetModels: data.targetModels,
          slug: route.slug,
          settings: data.subagentSettings
        )
        return optimisticSubagents.value(route.slug, fallback: enabled)
      },
      effortValue: { route in
        let stored = data.subagentSettings?["efforts"]?[route.slug]?.string ?? "default"
        return optimisticEfforts.value(route.slug, fallback: stored)
      }
    )
    let familyId = row.family.id
    let actions = ModelsRowActions(
      toggleExpanded: { expandedFamilyId = expandedFamilyId == familyId ? nil : familyId },
      familyPicker: { updateFamilyPicker(row, visible: $0) },
      routePicker: { updatePicker($0.slug, $1) },
      subagent: { updateSubagent($0.slug, $1) },
      effort: { updateEffort($0.slug, $1) },
      connect: { connectProvider($0, data) },
      removeLocal: { store.sheet = .removeLocal($0) }
    )
    return ModelsFamilyRow(row: row, expanded: expandedFamilyId == familyId, values: values, actions: actions)
  }

  // MARK: Picker and subagent writes

  private func updatePicker(_ slug: String, _ visible: Bool) {
    let label = visible
      ? model.t("models.action.show", ["name": slug])
      : model.t("models.action.hide", ["name": slug])
    optimisticPicker.mutate(slug, to: visible, label: label, model: model) { api in
      try await api.setPickerModel(slug, visible: visible)
    }
  }

  private func updateSubagent(_ slug: String, _ enabled: Bool) {
    let label = enabled
      ? model.t("models.action.enableSubagent", ["name": slug])
      : model.t("models.action.disableSubagent", ["name": slug])
    optimisticSubagents.mutate(slug, to: enabled, label: label, model: model) { api in
      try await api.setSubagentModel(slug, enabled)
    }
  }

  private func updateEffort(_ slug: String, _ effort: String) {
    let label = model.t("models.action.setEffort", ["name": slug, "effort": Format.effortLabel(effort, model.t)])
    optimisticEfforts.mutate(slug, to: effort, label: label, model: model) { api in
      try await api.setSubagentEffort(slug, effort)
    }
  }

  /// The row-level switch speaks for the whole model: turning it on publishes
  /// the route the router would pick anyway, turning it off withdraws every
  /// route. Choosing between routes stays inside the expanded row. The switch
  /// is the whole interaction: it runs the checks, and the router promotes the
  /// route only if every one of them passed.
  private func updateFamilyPicker(_ row: ModelsFamilyRowData, visible: Bool) {
    let selectable = row.usable.filter { !ModelsLogic.nativeClientManaged($0) }
    if visible {
      let candidate = ModelsFamily(id: row.family.id, displayName: row.family.displayName, routes: selectable)
      guard let route = ModelsLogic.preferredRoute(candidate) ?? selectable.first else { return }
      let slug = route.slug
      optimisticPicker.mutate(
        slug,
        to: true,
        label: model.t("models.action.show", ["name": row.family.displayName]),
        model: model
      ) { api in
        try await api.setPickerModel(slug, visible: true)
      }
      return
    }
    let withdraw = row.inPicker.filter { !ModelsLogic.nativeClientManaged($0) }
    if withdraw.isEmpty { return }
    let slugs = withdraw.map { $0.slug }
    optimisticPicker.mutateMany(
      slugs.map { ($0, false) },
      label: model.t("models.action.hide", ["name": row.family.displayName]),
      model: model
    ) { api in
      for slug in slugs { _ = try await api.setPickerModel(slug, visible: false) }
      return JSONValue.null
    }
  }

  private func connectProvider(_ providerId: String, _ data: ModelsPageData) {
    guard let setup = data.directoryById[providerId]?.setup else { return }
    if setup.kind == "oauth" || setup.signIn {
      openProviderMenu(providerId)
    } else if setup.kind == "configuration" {
      store.sheet = .configuration(setup)
    } else {
      store.sheet = .credential(setup)
    }
  }

  // MARK: New endpoint

  private func awaitingKey(_ data: ModelsPageData) -> String {
    guard let id = store.awaitingEndpointId else { return "" }
    let ready = data.directoryById[id].map { ModelsLogic.catalogEligible($0) } ?? false
    return "\(id)|\(ready)"
  }

  /// Opens the model picker as soon as the refreshed snapshot shows the new
  /// endpoint with a catalog to browse.
  private func openAwaitingEndpoint(_ data: ModelsPageData) {
    guard let id = store.awaitingEndpointId,
      let entry = data.directoryById[id],
      ModelsLogic.catalogEligible(entry)
    else { return }
    store.awaitingEndpointId = nil
    store.openAddModels(model, directory: data.directory, enabled: data.enabledProviders, query: entry.displayName)
  }

  // MARK: Dialogs

  @ViewBuilder
  private func sheetContent(_ sheet: ModelsSheet, data: ModelsPageData) -> some View {
    switch sheet {
    case .addModels(let query):
      ModelsAddSheet(
        store: store,
        directory: data.directory,
        initialQuery: query,
        onReload: { reloadCatalogs(data) },
        onAdd: { addCatalogModels($0, data) },
        onClose: { store.sheet = nil }
      )
    case .endpointNotice(let id, let displayName, let reason):
      ModelsEndpointNoticeSheet(
        displayName: displayName,
        reason: reason,
        onClose: { store.sheet = nil },
        onNameModel: {
          // The notice closes, then the named-model dialog opens if the
          // endpoint is still known.
          if let setup = data.directoryById[id]?.setup {
            store.sheet = .namedModel(setup)
          } else {
            store.sheet = nil
          }
        }
      )
    case .namedModel(let provider):
      ModelsNamedModelSheet(
        provider: provider,
        onSave: { target, modelId in saveNamedModel(target, modelId) },
        onClose: { store.sheet = nil }
      )
    case .customEndpoint(let editing):
      ModelsEndpointSheet(
        editing: editing,
        onSave: { endpoint, target in saveEndpoint(endpoint, target) },
        onClose: { store.sheet = nil }
      )
    case .credential(let provider):
      ModelsCredentialSheet(
        provider: provider,
        onSave: { target, secret in saveCredential(target, secret) },
        onClose: { store.sheet = nil }
      )
    case .configuration(let provider):
      ModelsConfigurationSheet(provider: provider, onClose: { store.sheet = nil })
    case .disconnect(let provider):
      ModelsDisconnectSheet(
        provider: provider,
        onClose: { store.sheet = nil },
        onConfirm: { removeCredential($0) }
      )
    case .removeLocal(let route):
      ModelsRemoveLocalSheet(
        route: route,
        onClose: { store.sheet = nil },
        onConfirm: { removeLocalModel($0) }
      )
    }
  }

  private func reloadCatalogs(_ data: ModelsPageData) {
    Task {
      await store.loadConnectedCatalogs(model, directory: data.directory, enabled: data.enabledProviders, refresh: true)
    }
  }

  private func addCatalogModels(_ selection: [ModelsCatalogModel], _ data: ModelsPageData) {
    Task {
      await store.addCatalogModels(model, directoryById: data.directoryById, selection: selection)
    }
  }

  private func saveNamedModel(_ provider: ModelsSetup, _ modelId: String) {
    Task { await store.addNamedModel(model, provider: provider, modelId: modelId) }
  }

  private func saveEndpoint(_ endpoint: ModelsEndpointInput, _ editing: ModelsSetup?) {
    Task { await store.saveEndpoint(model, endpoint: endpoint, editing: editing) }
  }

  /// The secret goes to the router once, over the bridge's stdin, and is not
  /// kept anywhere else: the dialog already cleared its field.
  private func saveCredential(_ provider: ModelsSetup, _ secret: String) {
    let id = provider.id
    let label = model.t("models.action.saveCredential", ["name": provider.displayName])
    Task {
      await store.runProviderCredentialAction(model, provider: provider, label: label) { api in
        _ = try await api.saveProviderCredential(id, secret)
      }
    }
  }

  private func removeCredential(_ provider: ModelsSetup) {
    let id = provider.id
    let label = model.t("models.action.removeCredential", ["name": provider.displayName])
    Task {
      await store.runProviderCredentialAction(model, provider: provider, label: label, intent: .disconnecting) { api in
        _ = try await api.removeProviderCredential(id)
      }
    }
  }

  /// The router resolves the slug against the local overlay, so nothing here
  /// has to know how a provider's public slug relates to its upstream id.
  private func removeLocalModel(_ route: ModelsRoute) {
    let slug = route.slug
    model.perform(model.t("models.local.action.remove", ["name": route.displayName])) { api in
      try await api.removeLocalModels([slug])
    }
  }
}
