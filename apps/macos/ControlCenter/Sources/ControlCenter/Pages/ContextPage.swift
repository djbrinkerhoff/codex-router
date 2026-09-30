import ControlCenterCore
import SwiftUI

/// Cross-harness session history with resume. Ported from `ContextPage.tsx`.
///
/// The page loads its own data (`getContextSessions`, `getHarnesses`) and
/// keeps it in local state; opening a session goes through the shared
/// operation feedback.
struct ContextPage: View {
  @EnvironmentObject private var model: AppModel
  @State private var snapshot: JSONValue?
  @State private var harnesses: JSONValue?
  @State private var search = ""
  @State private var harnessFilter = "all"
  @State private var showArchived = false
  @State private var codexModel = ""
  @State private var visibleCount = 200
  @State private var loadError: String?

  private static let pageSize = 200

  var body: some View {
    let allSessions = snapshot?["sessions"]?.items ?? []
    let filtered = ContextSupport.filter(allSessions, search: search, harness: harnessFilter, showArchived: showArchived)
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        eyebrow: model.t("context.eyebrow"),
        title: model.t("context.title"),
        description: model.t("context.description"),
        onRefresh: refresh
      )
      StatStrip(items: statItems(allSessions))
      InlineNotice(
        tone: .neutral,
        title: model.t("context.continuity.title"),
        message: model.t("context.continuity.body")
      )
      if let errorMessage = loadError {
        InlineNotice(tone: .warning, title: model.t("context.historyUnavailable"), message: errorMessage)
      }
      resumeSection
      sessionsSection(all: allSessions, filtered: filtered)
    }
    .task { await loadSessions() }
    .onChange(of: harnessFilter) { _ in visibleCount = Self.pageSize }
    .onChange(of: search) { _ in visibleCount = Self.pageSize }
    .onChange(of: showArchived) { _ in visibleCount = Self.pageSize }
  }

  // MARK: Loading

  private func loadSessions() async {
    let api = model.api
    do {
      async let nextSessions = api.getContextSessions()
      async let nextHarnesses = api.getHarnesses()
      let loaded = try await (nextSessions, nextHarnesses)
      snapshot = loaded.0
      harnesses = loaded.1
      loadError = nil
    } catch {
      if Task.isCancelled { return }
      let message = (error as? ControlCenterError)?.message ?? error.localizedDescription
      loadError = message.isEmpty ? model.t("context.loadError") : message
    }
  }

  private func refresh() {
    Task { await model.refreshAll() }
    Task { await loadSessions() }
  }

  // MARK: Actions

  private func openSession(_ session: JSONValue, _ surface: String) {
    let harnessId = session["harnessId"]?.string ?? ""
    let sessionId = session["id"]?.string ?? ""
    let title = session["title"]?.string ?? ""
    let modelSlug: String? = (harnessId == "codex" && surface == "terminal" && !codexModel.isEmpty) ? codexModel : nil
    model.perform(model.t("app.action.openSession", ["title": title])) { api in
      try await api.openHarnessSession(harnessId, sessionId: sessionId, surface: surface, model: modelSlug)
    }
  }

  // MARK: Stats

  private func statItems(_ sessions: [JSONValue]) -> [StatItem] {
    let t = model.t
    let stats = ContextStats(sessions: sessions)
    let counts = snapshot?["counts"]
    let hasInput = stats.inputTokens > 0
    return [
      StatItem(
        label: t("context.stats.sessions"),
        value: String(counts?["total"]?.int ?? 0),
        detail: t("context.stats.sessionsDetail", [
          "codex": counts?["codex"]?.int ?? 0,
          "dsh": counts?["dsh"]?.int ?? 0,
          "cursor": counts?["cursor"]?.int ?? 0,
        ])
      ),
      StatItem(label: t("context.stats.workspaces"), value: String(stats.workspaceCount), detail: t("context.stats.workspacesDetail")),
      StatItem(label: t("context.stats.models"), value: String(stats.modelCount), detail: t("context.stats.modelsDetail")),
      StatItem(
        label: t("context.stats.cachedContext"),
        value: hasInput ? "\(stats.cachePercent)%" : t("context.stats.unreported"),
        detail: hasInput
          ? t("context.stats.reusedTokens", ["count": Format.compactNumber(stats.cachedTokens, t)])
          : t("context.stats.metadataOnly")
      ),
    ]
  }

  // MARK: Resume behavior

  private var enabledModels: [ContextModelChoice] {
    (model.target?["models"]?.items ?? [])
      .filter { $0["enabled"].truthy || $0["native"].truthy }
      .compactMap { item -> ContextModelChoice? in
        guard let slug = item["slug"]?.string else { return nil }
        return ContextModelChoice(slug: slug, name: item["displayName"]?.string ?? slug)
      }
  }

  private var resumeSection: some View {
    let choices = enabledModels
    return VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: model.t("context.resume.title"), description: model.t("context.resume.description"))
      HStack(alignment: .top, spacing: 24) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.t("context.resume.modelLabel")).font(.system(size: 12, weight: .medium))
          Picker(model.t("context.resume.modelLabel"), selection: $codexModel) {
            Text(model.t("context.resume.keepModel")).tag("")
            ForEach(choices) { choice in Text(choice.name).tag(choice.slug) }
          }
          .labelsHidden()
          .disabled(choices.isEmpty)
          Text(model.t("context.resume.modelNote"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 17))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(model.t("context.resume.oneIndex")).font(.system(size: 12.5, weight: .semibold))
            Text(model.t("context.resume.separateStores"))
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .panelStyle(padding: 14)
  }

  // MARK: Sessions

  private func sessionsSection(all: [JSONValue], filtered: [JSONValue]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: model.t("context.sessions.title"), description: model.t("context.sessions.description"))
      toolbar(count: filtered.count)
      if snapshot == nil && loadError == nil {
        PanelSkeleton(label: model.t("context.loadingHistory"), count: 5)
      } else if !filtered.isEmpty {
        sessionList(filtered)
      } else {
        EmptyStateView(
          systemImage: "magnifyingglass",
          title: model.t("context.empty.title"),
          message: all.isEmpty ? model.t("context.empty.noSessionsBody") : model.t("context.empty.filteredBody")
        )
      }
    }
    .panelStyle(padding: 14)
  }

  private func toolbar(count: Int) -> some View {
    HStack(spacing: 12) {
      SearchField(text: $search, placeholder: model.t("context.searchPlaceholder"))
      Picker(model.t("context.filterAria"), selection: $harnessFilter) {
        ForEach(ContextSupport.harnessFilters, id: \.self) { value in
          Text(value == "all" ? model.t("context.filterAll") : ContextSupport.harnessName(value)).tag(value)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityLabel(model.t("context.filterAria"))
      Toggle(model.t("context.showArchived"), isOn: $showArchived)
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
      Spacer(minLength: 0)
      Text(model.t("context.shownCount", ["count": count]))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
  }

  private func sessionList(_ filtered: [JSONValue]) -> some View {
    let visible = Array(filtered.prefix(visibleCount))
    let items = ContextSupport.items(visible)
    let codexApp = (codexHarness()?["appInstalled"]).truthy
    let terminalOn = (harnesses?["terminalAvailable"]).truthy
    return VStack(alignment: .leading, spacing: 0) {
      LazyVStack(spacing: 0) {
        ForEach(items) { item in
          let harnessId = item.value["harnessId"]?.string ?? ""
          ContextSessionRow(
            session: item.value,
            appAvailable: harnessId == "codex" && codexApp,
            terminalAvailable: terminalOn && (harnessRow(harnessId)?["cliInstalled"]).truthy,
            modelOverride: harnessId == "codex" ? codexModel : "",
            onOpen: { session, surface in openSession(session, surface) }
          )
          Divider()
        }
      }
      if visible.count < filtered.count {
        HStack(spacing: 12) {
          Button {
            visibleCount += Self.pageSize
          } label: {
            Text(model.t("context.showMore"))
          }
          .buttonStyle(.bordered)
          Text(model.t("context.renderedCount", ["shown": visible.count, "total": filtered.count]))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
      }
    }
  }

  private func harnessRow(_ id: String) -> JSONValue? {
    harnesses?["harnesses"]?.items.first { $0["id"]?.string == id }
  }

  private func codexHarness() -> JSONValue? { harnessRow("codex") }
}
