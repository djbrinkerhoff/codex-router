import ControlCenterCore
import SwiftUI

// The three panels of the Usage page: the daily chart, the allowance meters
// and the source list.

/// The chart panel (`us-chart-panel`).
struct UsageChartPanel: View {
  @EnvironmentObject private var model: AppModel
  let source: UsageSourceEntry
  let buckets: [UsageDayBucket]
  @Binding var range: Int
  let routerAggregate: UsageSourceEntry?

  var body: some View {
    let t = model.t
    let isSubscription = source.kind == .subscription
    let fallbackDays = isSubscription ? buckets.filter { $0.origin == .routerFallback }.count : 0
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: headingTitle(isSubscription: isSubscription, fallbackDays: fallbackDays, t),
        description: headingDescription(isSubscription: isSubscription, fallbackDays: fallbackDays, t)
      ) {
        UsageRangePicker(range: $range)
      }
      chartOrEmpty(isSubscription: isSubscription, t)
      UsageChartHint(sourceKind: source.kind, buckets: buckets, range: range)
      UsageTokenMixView(source: source, buckets: buckets, range: range)
      HStack {
        Text(UsageLogic.formatBucketDate(buckets.first?.startDate, t))
        Spacer()
        Text(UsageLogic.formatBucketDate(buckets.last?.startDate, t))
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      if isSubscription, let routerAggregate {
        liveNote(routerAggregate, t)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelStyle(padding: 16)
  }

  private func headingTitle(isSubscription: Bool, fallbackDays: Int, _ t: Translator) -> String {
    guard isSubscription else { return t("usage.dailyRouterTraffic") }
    return fallbackDays > 0 ? t("usage.fallback.chartTitle") : t("usage.dailyAccountTokens")
  }

  private func headingDescription(isSubscription: Bool, fallbackDays: Int, _ t: Translator) -> String {
    guard isSubscription else { return t("usage.chart.routerBreakdown", ["name": source.name]) }
    if fallbackDays > 0 {
      let key = fallbackDays == 1 ? "usage.fallback.chartDescriptionOne" : "usage.fallback.chartDescription"
      return t(key, ["name": source.name, "count": fallbackDays])
    }
    let breakdown = buckets.contains { UsageLogic.tokenParts($0, t) != nil }
    return breakdown
      ? t("usage.chart.accountBreakdown", ["name": source.name])
      : t("usage.chart.accountTotalsOnly", ["name": source.name])
  }

  @ViewBuilder
  private func chartOrEmpty(isSubscription: Bool, _ t: Translator) -> some View {
    if buckets.contains(where: { $0.tokens > 0 }) {
      UsageChartView(buckets: buckets, sourceKind: source.kind)
    } else {
      EmptyStateView(
        systemImage: "chart.bar",
        title: t("usage.chart.noTraffic"),
        message: isSubscription ? t("usage.chart.noTrafficAccount") : t("usage.chart.noTrafficRouter")
      )
    }
  }

  private func liveNote(_ aggregate: UsageSourceEntry, _ t: Translator) -> some View {
    let measured = aggregate.last24hTokens
    let title = measured == nil
      ? t("usage.live.notMeasured")
      : t("usage.live.measured", ["count": Format.exactNumber(measured, t)])
    let message = measured == nil ? t("usage.live.missingNote") : t("usage.live.separateNote")
    return UsageNoteView(title: title, message: message, color: Color.secondary)
  }
}

/// The allowance meters (`us-allowance-panel`). Selection focuses, it does not
/// hide: every connected account keeps its meters on the page so a routed
/// provider can always be compared with its neighbours.
struct UsageAllowancePanel: View {
  @EnvironmentObject private var model: AppModel
  let source: UsageSourceEntry
  let allowances: [UsageAllowanceEntry]
  let targetRowID: String?
  let focused: Bool
  let dashboardSources: [UsageSourceEntry]
  let onOpenDashboard: (String) -> Void

  var body: some View {
    let t = model.t
    let usageReady = model.isReady(.accountUsage) && model.isReady(.providerUsage)
    let selectedRows = source.kind != .aggregate ? allowances.filter { $0.sourceID == source.id } : []
    let otherRows = selectedRows.isEmpty ? allowances : allowances.filter { $0.sourceID != source.id }
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: t("usage.allowances.title"), description: t("usage.allowances.description"))
      content(selectedRows: selectedRows, otherRows: otherRows, usageReady: usageReady, t)
      if !dashboardSources.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(dashboardSources) { entry in
            dashboardButton(entry, t)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelStyle(padding: 16)
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Palette.accent, lineWidth: focused ? 2 : 0)
    )
    .animation(.easeOut(duration: 0.2), value: focused)
    .id("usage-allowances")
    .accessibilityElement(children: .contain)
    .accessibilityLabel(t("usage.allowances.title"))
  }

  @ViewBuilder
  private func content(selectedRows: [UsageAllowanceEntry], otherRows: [UsageAllowanceEntry], usageReady: Bool, _ t: Translator) -> some View {
    if !allowances.isEmpty {
      if !selectedRows.isEmpty {
        groupLabel(t("usage.allowances.selected", ["name": source.name]))
        cards(selectedRows)
          .accessibilityLabel(t("usage.allowances.named", ["name": source.name]))
        if !otherRows.isEmpty { groupLabel(t("usage.allowances.otherAccounts")) }
      }
      if !otherRows.isEmpty || !usageReady {
        VStack(spacing: 10) {
          cardStack(otherRows)
          if !usageReady { SkeletonBlock(height: 64) }
        }
        .accessibilityLabel(selectedRows.isEmpty ? t("usage.allowances.allAria") : t("usage.allowances.otherAria"))
      }
    } else if !usageReady {
      PanelSkeleton(label: t("usage.loading.allowances"), count: 2)
    } else {
      EmptyStateView(
        systemImage: "gauge.with.dots.needle.33percent",
        title: t("usage.allowances.empty"),
        message: emptyMessage(t)
      )
    }
  }

  private func emptyMessage(_ t: Translator) -> String {
    let message = t.backend(source.message)
    return message.isEmpty ? t("usage.allowances.emptyBody") : message
  }

  private func groupLabel(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11.5, weight: .semibold))
      .foregroundStyle(.secondary)
  }

  private func cards(_ rows: [UsageAllowanceEntry]) -> some View {
    VStack(spacing: 10) { cardStack(rows) }
  }

  @ViewBuilder
  private func cardStack(_ rows: [UsageAllowanceEntry]) -> some View {
    ForEach(rows) { row in
      UsageMetricCard(
        sourceName: row.sourceName,
        metric: row.metric,
        focused: focused && row.id == targetRowID
      )
      .id(row.id)
    }
  }

  private func dashboardButton(_ entry: UsageSourceEntry, _ t: Translator) -> some View {
    Button {
      if let url = entry.dashboardUrl { onOpenDashboard(url) }
    } label: {
      HStack(spacing: 4) {
        Text(t("usage.dashboard", ["name": entry.name]))
        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
      }
    }
    .buttonStyle(.borderless)
  }
}

/// The source list (`us-source-panel`).
struct UsageSourcesPanel: View {
  @EnvironmentObject private var model: AppModel
  let sources: [UsageSourceEntry]
  let selectedID: String
  /// Seven-day buckets by subscription source id.
  let weekBuckets: [String: [UsageDayBucket]]
  let onSelect: (String) -> Void

  var body: some View {
    let t = model.t
    let routed = sources.filter { $0.kind != .subscription }
    let accounts = sources.filter { $0.kind == .subscription }
    VStack(alignment: .leading, spacing: 10) {
      SectionHeading(title: t("usage.sources.title"), description: t("usage.sources.description"))
      VStack(spacing: 6) {
        ForEach(routed) { entry in
          row(entry)
        }
        if !model.isReady(.providerUsage) {
          SkeletonBlock(height: 52)
          SkeletonBlock(height: 52)
        }
      }
      if !accounts.isEmpty {
        Text(t("usage.sources.accountGroup"))
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.top, 4)
        VStack(spacing: 6) {
          ForEach(accounts) { entry in
            row(entry)
          }
        }
        .accessibilityLabel(t("usage.sources.accountAria"))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelStyle(padding: 16)
  }

  private func row(_ entry: UsageSourceEntry) -> some View {
    UsageSourceRow(
      source: entry,
      selected: entry.id == selectedID,
      weekBuckets: weekBuckets[entry.id] ?? [],
      onSelect: { onSelect(entry.id) }
    )
  }
}
