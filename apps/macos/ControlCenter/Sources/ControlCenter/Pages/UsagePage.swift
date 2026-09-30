import ControlCenterCore
import SwiftUI

/// The Usage page, ported from `UsagePage.tsx`: the selected stream's summary
/// and daily chart, every account's allowance meters, and the list of streams.
/// Its data model lives in `Usage/UsageData.swift`.
@MainActor
struct UsagePage: View {
  @EnvironmentObject private var model: AppModel
  @State private var range = 30
  @State private var selected = ""
  @State private var allowanceFocused = false
  @State private var handledFocus: Int?
  @State private var appliedSelection: Int?
  @State private var cache = UsageComputationCache()

  private static let topID = "usage-top"
  private static let allowancesID = "usage-allowances"

  /// Everything derived from the router data for one render.
  private struct Context {
    var sources: [UsageSourceEntry]
    var source: UsageSourceEntry?
    var buckets: [UsageDayBucket]
    var allowances: [UsageAllowanceEntry]
    var targetRowID: String?
  }

  var body: some View {
    let t = model.t
    let context = makeContext(t)
    let sourceIDs = context.sources.map { $0.id }
    return ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: 20) {
        header(context, t).id(Self.topID)
        pageContent(context, t)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(t("usage.overviewAria"))
      .onAppear { handleFocus(context, proxy) }
      .onChange(of: model.usageFocusRequest) { _ in handleFocus(context, proxy) }
      .onChange(of: model.refreshing) { _ in handleFocus(context, proxy) }
      .onChange(of: sourceIDs) { ids in
        if !selected.isEmpty && !ids.contains(selected) { selected = "" }
        handleFocus(context, proxy)
      }
      .onChange(of: context.targetRowID) { _ in handleFocus(context, proxy) }
    }
  }

  // MARK: Derived data

  private func makeContext(_ t: Translator) -> Context {
    let sources = cache.sources(t: t, target: model.target, account: model.accountUsage, providerUsage: model.providerUsage)
    // Prefer the rolling local-router stream so the headline remains useful
    // across midnight and timezone boundaries. The ChatGPT account stream stays
    // available for authoritative plan limits and calendar-day history.
    var chosen: UsageSourceEntry? = sources.first(where: { $0.id == selected })
    if chosen == nil { chosen = sources.first(where: { $0.id == "all-router" }) }
    if chosen == nil { chosen = sources.first(where: { $0.kind == .subscription }) }
    if chosen == nil { chosen = sources.first }
    let source = chosen
    guard let source else {
      return Context(sources: sources, source: nil, buckets: [], allowances: [], targetRowID: nil)
    }
    let allowances = UsageLogic.allowanceRows(sources: sources, selected: source)
    var targetSourceID: String?
    if let request = model.usageFocusRequest, request.allowance {
      targetSourceID = UsageLogic.navigationSourceID(request.sourceID)
    }
    return Context(
      sources: sources,
      source: source,
      buckets: cache.buckets(for: source, days: range),
      allowances: allowances,
      targetRowID: UsageLogic.targetAllowanceRowID(allowances: allowances, targetSourceID: targetSourceID)
    )
  }

  // MARK: Header

  private func header(_ context: Context, _ t: Translator) -> some View {
    PageHeader(
      eyebrow: t("usage.eyebrow"),
      title: t("usage.title"),
      description: headerDescription(context, t),
      onRefresh: { Task { await model.refreshAll() } }
    ) {
      if !context.sources.isEmpty {
        sourcePicker(context, t)
      }
    }
  }

  private func headerDescription(_ context: Context, _ t: Translator) -> String {
    var text = t("usage.description")
    let fetchedAt: JSONValue?
    if context.source?.kind == .subscription {
      fetchedAt = model.accountUsage?["fetchedAt"]
    } else {
      fetchedAt = model.providerUsage?["fetchedAt"]
    }
    if let fetchedAt, fetchedAt.truthy {
      text += " " + t("usage.snapshotFetched", ["time": Format.dateTime(fetchedAt, t)])
    }
    return text
  }

  private func sourcePicker(_ context: Context, _ t: Translator) -> some View {
    let binding = Binding<String>(
      get: { context.source?.id ?? "" },
      set: { selected = $0 }
    )
    return HStack(spacing: 6) {
      Text(t("usage.view")).font(.system(size: 12)).foregroundStyle(.secondary)
      Picker(selection: binding) {
        ForEach(context.sources) { entry in
          Text(entry.name).tag(entry.id)
        }
      } label: {
        Text(t("usage.sourceAria"))
      }
      .labelsHidden()
      .frame(maxWidth: 240)
      .accessibilityLabel(t("usage.sourceAria"))
    }
  }

  // MARK: Content

  @ViewBuilder
  private func pageContent(_ context: Context, _ t: Translator) -> some View {
    if let source = context.source {
      loadedContent(source, context, t)
    } else if !(model.isReady(.snapshot) && model.isReady(.accountUsage) && model.isReady(.providerUsage)) {
      UsageLoadingView()
    } else {
      EmptyStateView(
        systemImage: "chart.bar",
        title: t("usage.empty.title"),
        message: t("usage.empty.body")
      )
    }
  }

  @ViewBuilder
  private func loadedContent(_ source: UsageSourceEntry, _ context: Context, _ t: Translator) -> some View {
    UsageSummaryGrid(items: summary(source, context, t))
    UsageAggregateLedgerNote(source: source)
    primaryGrid(source, context)
    UsageSourcesPanel(
      sources: context.sources,
      selectedID: source.id,
      weekBuckets: weekBuckets(context),
      onSelect: { selected = $0 }
    )
  }

  private func summary(_ source: UsageSourceEntry, _ context: Context, _ t: Translator) -> [UsageSummaryEntry] {
    let requestsAvailable = context.buckets.contains { $0.requests != nil }
    let rangeRequests: Double? = requestsAvailable
      ? context.buckets.reduce(0.0) { $0 + ($1.requests ?? 0) }
      : nil
    // The mixed display series may end in a local fallback. Keep the account
    // headline tied to OpenAI's raw stream so a router-only value is never
    // presented as the last globally reported day.
    var latest: JSONValue?
    if source.kind == .subscription {
      latest = model.accountUsage?["dailyUsageBuckets"]?.items.last
    }
    return UsageLogic.usageSummary(
      source: source,
      range: range,
      rangeBuckets: context.buckets,
      rangeRequests: rangeRequests,
      latestReportedBucket: latest,
      t
    )
  }

  private func weekBuckets(_ context: Context) -> [String: [UsageDayBucket]] {
    var result: [String: [UsageDayBucket]] = [:]
    for entry in context.sources where entry.kind == .subscription {
      result[entry.id] = cache.buckets(for: entry, days: 7)
    }
    return result
  }

  private func primaryGrid(_ source: UsageSourceEntry, _ context: Context) -> some View {
    let aggregate = context.sources.first { $0.id == "all-router" }
    let dashboards = dashboardSources(context.sources)
    let api = model.api
    let open: (String) -> Void = { url in
      // The router refuses anything but HTTPS; check here as well.
      guard url.lowercased().hasPrefix("https://") else { return }
      Task { _ = try? await api.openExternal(url) }
    }
    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        UsageChartPanel(source: source, buckets: context.buckets, range: $range, routerAggregate: aggregate)
          .frame(minWidth: 460, maxWidth: .infinity, alignment: .topLeading)
        UsageAllowancePanel(
          source: source,
          allowances: context.allowances,
          targetRowID: context.targetRowID,
          focused: allowanceFocused,
          dashboardSources: dashboards,
          onOpenDashboard: open
        )
        .frame(width: 340, alignment: .topLeading)
      }
      VStack(alignment: .leading, spacing: 16) {
        UsageChartPanel(source: source, buckets: context.buckets, range: $range, routerAggregate: aggregate)
        UsageAllowancePanel(
          source: source,
          allowances: context.allowances,
          targetRowID: context.targetRowID,
          focused: allowanceFocused,
          dashboardSources: dashboards,
          onOpenDashboard: open
        )
      }
    }
  }

  private func dashboardSources(_ sources: [UsageSourceEntry]) -> [UsageSourceEntry] {
    var seen = Set<String>()
    var result: [UsageSourceEntry] = []
    for entry in sources where entry.kind != .aggregate {
      guard let url = entry.dashboardUrl, !url.isEmpty, !seen.contains(url) else { continue }
      seen.insert(url)
      result.append(entry)
    }
    return result
  }

  // MARK: Focus requests

  /// Acts on a tray request: select the requested source, then either scroll
  /// to the page top or to the requested allowance meter and highlight it.
  private func handleFocus(_ context: Context, _ proxy: ScrollViewProxy) {
    guard let request = model.usageFocusRequest else { return }
    let preferred = UsageLogic.navigationSourceID(request.sourceID)
    if appliedSelection != request.id {
      if let preferred {
        if context.sources.contains(where: { $0.id == preferred }) {
          selected = preferred
          appliedSelection = request.id
        }
      } else {
        appliedSelection = request.id
      }
    }
    if handledFocus == request.id { return }
    // A refresh can replace the usage rows. Let its committed data choose the
    // final target before marking this navigation request as handled.
    if model.refreshing { return }

    if !request.allowance {
      allowanceFocused = false
      handledFocus = request.id
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 80_000_000)
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(Self.topID, anchor: .top) }
      }
      return
    }

    if let preferred,
      let preferredSource = context.sources.first(where: { $0.id == preferred }),
      !preferredSource.metrics.isEmpty,
      context.targetRowID == nil
    {
      return
    }
    guard context.source != nil else { return }
    handledFocus = request.id
    allowanceFocused = true
    let anchorID = context.targetRowID ?? Self.allowancesID
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 80_000_000)
      withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(anchorID, anchor: .center) }
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      allowanceFocused = false
    }
  }
}
