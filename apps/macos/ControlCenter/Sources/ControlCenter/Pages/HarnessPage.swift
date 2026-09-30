import ControlCenterCore
import SwiftUI

/// Coding-client routing: one row per client with its Route switch, launch
/// buttons, and updater. Ported from `HarnessPage.tsx`.
///
/// The page loads its own data (`getHarnesses`, `getContextSessions`,
/// `getAgentBridges`) and reloads after every action, as the renderer did.
struct HarnessPage: View {
  @EnvironmentObject private var model: AppModel
  @State private var snapshot: JSONValue?
  @State private var sessions: JSONValue?
  @State private var agentBridges: JSONValue?
  @State private var loadError: String?
  @State private var cursorHostname = ""
  @State private var pendingHarnessId: String?

  var body: some View {
    let clients = currentClients()
    let routedModelCount = routedModels()
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        eyebrow: model.t("harness.eyebrow"),
        title: model.t("harness.title"),
        description: model.t("harness.description"),
        onRefresh: refresh
      )
      summary(clients: clients, routedModelCount: routedModelCount)
      if let loadError {
        InlineNotice(tone: .warning, title: model.t("harness.detectionIncomplete"), message: loadError)
      }
      clientList(clients: clients, routedModelCount: routedModelCount)
      continuum(clients: clients, routedModelCount: routedModelCount)
    }
    .task { await loadHarnesses() }
    .onChange(of: snapshot) { _ in adoptSavedHostname() }
  }

  // MARK: Derived

  private func currentClients() -> [JSONValue] {
    let all = snapshot?["harnesses"]?.items ?? []
    return HarnessSupport.clientOrder.compactMap { id in
      all.first { $0["id"]?.string == id }
    }
  }

  private func routedModels() -> Int {
    (model.target?["models"]?.items ?? []).filter { item in
      item["visible"].truthy && (item["enabled"].truthy || item["native"].truthy)
    }.count
  }

  private var cursorOperationActive: Bool {
    if pendingHarnessId == "cursor" { return true }
    guard let operation = model.operation, operation.status == .started else { return false }
    return HarnessSupport.cursorOperationActions.contains(operation.action)
  }

  private func isBusy(_ id: String) -> Bool {
    pendingHarnessId == id || (id == "cursor" && cursorOperationActive)
  }

  private func sessionCount(_ id: String) -> Int {
    sessions?["counts"]?[id]?.int ?? 0
  }

  private func routingEnabled(_ harness: JSONValue) -> Bool {
    if harness["id"]?.string == "cursor" { return harness["appConfigured"].truthy }
    return harness["configured"].truthy
  }

  private func trimmedHostname() -> String? {
    let value = cursorHostname.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func adoptSavedHostname() {
    let harnesses = snapshot?["harnesses"]?.items ?? []
    let cursor = harnesses.first { $0["id"]?.string == "cursor" }
    if let saved = cursor?["tunnel"]?["hostname"]?.string, !saved.isEmpty {
      cursorHostname = saved
    }
  }

  // MARK: Loading

  private func loadHarnesses() async {
    let api = model.api
    do {
      async let nextHarnesses = api.getHarnesses()
      async let nextSessions = api.getContextSessions()
      let loaded = try await (nextHarnesses, nextSessions)
      snapshot = loaded.0
      sessions = loaded.1
      loadError = nil
      if api.supports("getAgentBridges") != false {
        do {
          agentBridges = try await api.getAgentBridges()
        } catch {
          // Agent bridges are optional client-owned sessions. Their detection
          // must never hide the routed Cursor, DeepSeek, and Codex rows.
          agentBridges = nil
        }
      }
    } catch {
      if Task.isCancelled { return }
      let message = (error as? ControlCenterError)?.message ?? error.localizedDescription
      loadError = message.isEmpty ? model.t("harness.loadError") : message
    }
  }

  private func refresh() {
    Task {
      await model.refreshAll()
    }
    Task { await loadHarnesses() }
  }

  // MARK: Actions

  /// The renderer's `act`: run the action with the shared feedback, then
  /// reload this page's own data.
  private func act(_ label: String, _ action: @escaping (RouterControl) async throws -> JSONValue) async {
    let api = model.api
    await model.runAction(label) { try await action(api) }
    await loadHarnesses()
  }

  private func runHarnessAction(
    _ harnessId: String,
    _ label: String,
    _ action: @escaping (RouterControl) async throws -> JSONValue
  ) async {
    pendingHarnessId = harnessId
    await act(label, action)
    pendingHarnessId = nil
  }

  private func toggleRouting(_ harness: JSONValue, enabled: Bool) async {
    let id = harness["id"]?.string ?? ""
    let name = harness["displayName"]?.string ?? id
    if enabled {
      if id == "cursor" {
        let hostname = trimmedHostname()
        await runHarnessAction("cursor", model.t("harness.connectLabel", ["name": "Cursor"])) { api in
          try await api.connectCursor(hostname: hostname)
        }
        return
      }
      await runHarnessAction(id, model.t("harness.configureLabel", ["name": name])) { api in
        try await api.setupHarness(id)
      }
      return
    }
    if id == "cursor" {
      await runHarnessAction("cursor", model.t("harness.disconnectLabel", ["name": "Cursor"])) { api in
        try await api.disconnectCursor()
      }
      return
    }
    await runHarnessAction(id, model.t("harness.disconnectLabel", ["name": name])) { api in
      try await api.disconnectHarness(id)
    }
  }

  private func setup(_ harness: JSONValue) async {
    let id = harness["id"]?.string ?? ""
    let name = harness["displayName"]?.string ?? id
    if id == "cursor" {
      let hostname = trimmedHostname()
      await runHarnessAction("cursor", model.t("harness.connectLabel", ["name": "Cursor"])) { api in
        try await api.connectCursor(hostname: hostname)
      }
    } else {
      await runHarnessAction(id, model.t("harness.configureLabel", ["name": name])) { api in
        try await api.setupHarness(id)
      }
    }
  }

  private func openSurface(_ harness: JSONValue, _ surface: String) async {
    let id = harness["id"]?.string ?? ""
    let name = harness["displayName"]?.string ?? id
    let label = surface == "app"
      ? model.t("harness.openAppLabel", ["name": name])
      : model.t("harness.openTerminalLabel", ["name": name])
    await act(label) { api in try await api.launchHarness(id, surface: surface) }
  }

  // Updating is its own action, never a step inside setup: publishing a model
  // list must not be the reason somebody's global coding agent changed version.
  private func update(_ harness: JSONValue) async {
    let id = harness["id"]?.string ?? ""
    let name = harness["displayName"]?.string ?? id
    await act(model.t("harness.updateLabel", ["name": name])) { api in try await api.updateHarness(id) }
  }

  private func updateAll() async {
    await act(model.t("harness.updateAllLabel")) { api in try await api.updateHarness("all") }
  }

  private func openDocs(_ harness: JSONValue) {
    guard let url = harness["docsUrl"]?.text, url.lowercased().hasPrefix("https://") else { return }
    let api = model.api
    Task {
      do {
        _ = try await api.openExternal(url)
      } catch {
        model.showToast(.danger, model.readableError(error))
      }
    }
  }

  // MARK: Summary

  private func summary(clients: [JSONValue], routedModelCount: Int) -> some View {
    let t = model.t
    let updatable = clients.filter { $0["canUpdate"].truthy }
    let names = updatable.compactMap { $0["displayName"]?.string }.joined(separator: ", ")
    return HStack(alignment: .top, spacing: 12) {
      StatStrip(items: [
        StatItem(label: t("harness.stats.clients"), value: String(clients.count), detail: t("harness.stats.clientsDetail")),
        StatItem(
          label: t("harness.stats.configured"),
          value: String(clients.filter { $0["configured"].truthy }.count),
          detail: t("harness.stats.configuredDetail")
        ),
        StatItem(
          label: t("harness.stats.sessions"),
          value: String(sessions?["counts"]?["total"]?.int ?? 0),
          detail: t("harness.stats.sessionsDetail")
        ),
        StatItem(label: t("harness.stats.routedModels"), value: String(routedModelCount), detail: t("harness.stats.routedModelsDetail")),
      ])
      if !updatable.isEmpty {
        Button {
          Task { await updateAll() }
        } label: {
          Label(t("harness.updateAll.label", ["count": updatable.count]), systemImage: "arrow.up.circle")
        }
        .buttonStyle(.bordered)
        .help(t("harness.updateAll.title", ["list": names]))
      }
    }
  }

  // MARK: Client rows

  @ViewBuilder
  private func clientList(clients: [JSONValue], routedModelCount: Int) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if snapshot == nil && loadError == nil {
        PanelSkeleton(label: model.t("harness.detecting"), count: HarnessSupport.clientOrder.count)
      }
      if !clients.isEmpty {
        HarnessTableHead()
      }
      ForEach(Array(clients.enumerated()), id: \.offset) { _, harness in
        row(harness, routedModelCount: routedModelCount)
      }
    }
  }

  private func row(_ harness: JSONValue, routedModelCount: Int) -> some View {
    let id = harness["id"]?.string ?? ""
    let handlers = HarnessRowHandlers(
      toggleRouting: { next in Task { await toggleRouting(harness, enabled: next) } },
      setup: { Task { await setup(harness) } },
      open: { surface in Task { await openSurface(harness, surface) } },
      update: { Task { await update(harness) } },
      showSessions: { model.navigate(.context) },
      openDocs: { openDocs(harness) }
    )
    return HarnessRow(
      harness: harness,
      sessions: sessionCount(id),
      modelFact: HarnessSupport.modelFact(harness, modelCount: routedModelCount, model.t),
      bridge: HarnessSupport.bridge(for: id, in: agentBridges),
      enabled: routingEnabled(harness),
      busy: isBusy(id),
      terminalAvailable: snapshot?["terminalAvailable"].truthy ?? false,
      updateAvailable: harness["canUpdate"].truthy,
      cursorHostname: $cursorHostname,
      handlers: handlers
    )
  }

  // MARK: Continuum

  private func continuum(clients: [JSONValue], routedModelCount: Int) -> some View {
    let t = model.t
    let cursorConfigured = clients.first { $0["id"]?.string == "cursor" }?["configured"].truthy ?? false
    let active = (model.target?["active"]).truthy
    return VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: t("harness.continuum.title", ["count": clients.count]),
        description: t("harness.continuum.description")
      )
      CardGrid(minimum: 260) {
        continuumCard(
          systemImage: "arrow.triangle.branch",
          title: t("harness.continuum.catalogTitle"),
          detail: t("harness.continuum.catalogBody", ["count": routedModelCount]),
          badge: Badge(active ? t("harness.continuum.active") : t("harness.continuum.inactive"), tone: active ? .success : .neutral)
        )
        continuumCard(
          systemImage: "globe",
          title: t("harness.continuum.cursorEdgeTitle"),
          detail: t("harness.continuum.cursorEdgeBody"),
          badge: Badge(t("harness.continuum.isolated"), tone: cursorConfigured ? .success : .neutral)
        )
        continuumCard(
          systemImage: "shippingbox",
          title: t("harness.continuum.ownershipTitle"),
          detail: t("harness.continuum.ownershipBody"),
          badge: Badge(t("harness.continuum.local"), tone: .accent)
        )
      }
    }
    .panelStyle(padding: 14)
  }

  private func continuumCard(systemImage: String, title: String, detail: String, badge: Badge) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 12.5, weight: .semibold))
        Text(detail)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 4)
      badge
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
  }
}
