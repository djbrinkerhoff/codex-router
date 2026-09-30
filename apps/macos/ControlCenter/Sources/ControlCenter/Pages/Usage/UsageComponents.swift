import ControlCenterCore
import SwiftUI

// Small views for the Usage page: the summary tiles, notes, range picker,
// token mix, allowance meter cards and source rows.

/// The headline tiles (`UsageSummary`).
struct UsageSummaryGrid: View {
  let items: [UsageSummaryEntry]

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 150), spacing: 0, alignment: .top)],
      alignment: .leading,
      spacing: 0
    ) {
      ForEach(items) { item in
        tile(item)
      }
    }
    .panelStyle()
  }

  private func valueColor(_ tone: UsageTokenTone?) -> Color {
    guard let tone else { return Color.primary }
    return UsageColors.color(tone)
  }

  private func tile(_ item: UsageSummaryEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.label.uppercased())
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(minHeight: 24, alignment: .topLeading)
      Text(item.value)
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(valueColor(item.tone))
        .lineLimit(item.tone == .cached ? 3 : 1)
        .minimumScaleFactor(0.7)
      Text(item.detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .help(item.detail)
    .accessibilityElement(children: .combine)
  }
}

/// A one-paragraph note with a colored leading edge (`us-aggregate-note`,
/// `us-live-note`, `us-chart-hint`).
struct UsageNoteView: View {
  let title: String
  let message: String
  var color: Color = UsageColors.total

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 12, weight: .semibold))
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

/// The router-ledger scope note above the chart (`AggregateLedgerNote`).
struct UsageAggregateLedgerNote: View {
  @EnvironmentObject private var model: AppModel
  let source: UsageSourceEntry

  var body: some View {
    let t = model.t
    if source.kind == .aggregate {
      UsageNoteView(title: t("usage.ledger.title"), message: message(t))
    }
  }

  private func message(_ t: Translator) -> String {
    let scope = UsageLogic.nonEmpty(source.scopeLabel) ?? t("usage.scope.lastDays", ["days": UsageLogic.ledgerDays])
    var since = ""
    if let start = UsageLogic.nonEmpty(source.windowStart) {
      since = t("usage.ledger.since", ["date": String(start.prefix(10))])
    }
    var text: String
    if let total = source.totalTokens {
      text = t("usage.ledger.tokensIn", [
        "count": Format.exactNumber(total, t),
        "scope": scope.lowercased(),
        "since": since,
      ])
      if let input = source.inputTokens, let output = source.outputTokens {
        text += t("usage.ledger.breakdown", ["input": Format.exactNumber(input, t), "output": Format.exactNumber(output, t)])
      } else {
        text += "."
      }
    } else {
      text = t("usage.ledger.missing")
    }
    if let regular = source.regularInputTokens, let cached = source.cachedInputTokens {
      text += t("usage.ledger.split", ["regular": Format.exactNumber(regular, t), "cached": Format.exactNumber(cached, t)])
    } else {
      text += t("usage.ledger.splitMissing")
    }
    return text
  }
}

/// The 7 / 30 / 90 day selector (`RangePicker`).
struct UsageRangePicker: View {
  @EnvironmentObject private var model: AppModel
  @Binding var range: Int

  var body: some View {
    let t = model.t
    Picker(selection: $range) {
      ForEach([7, 30, 90], id: \.self) { days in
        Text(t("display.daysD", ["days": days])).tag(days)
      }
    } label: {
      Text(t("usage.rangeAria"))
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 170)
    .accessibilityLabel(t("usage.rangeAria"))
  }
}

/// The key under the chart (`UsageChartHint`).
struct UsageChartHint: View {
  @EnvironmentObject private var model: AppModel
  let sourceKind: UsageSourceKind
  let buckets: [UsageDayBucket]
  let range: Int

  var body: some View {
    let t = model.t
    let complete = UsageLogic.hasCompleteTokenBreakdown(buckets, t)
      && (sourceKind != .subscription || !UsageLogic.hasFallbackDays(buckets))
    if sourceKind == .subscription {
      UsageNoteView(
        title: t("usage.hint.accountGraph"),
        message: complete ? t("usage.hint.accountSplit", ["range": range]) : t("usage.hint.accountTotalsOnly"),
        color: UsageColors.total
      )
    } else {
      UsageNoteView(
        title: t("usage.hint.tokenKey"),
        message: complete ? t("usage.hint.cachedSubset") : t("usage.hint.noSplit"),
        color: Color.secondary
      )
    }
  }
}

/// Regular / cached / output totals under the chart (`TokenMix`).
struct UsageTokenMixView: View {
  @EnvironmentObject private var model: AppModel
  let source: UsageSourceEntry
  let buckets: [UsageDayBucket]
  let range: Int

  var body: some View {
    let t = model.t
    if let mix = UsageLogic.tokenMix(source: source, buckets: buckets, range: range, t) {
      HStack(alignment: .top, spacing: 10) {
        ForEach(mix.rows) { row in
          cell(row, scope: mix.scope, t)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(t("usage.tokenMix.aria", ["scope": mix.scope]))
    }
  }

  private func cell(_ row: UsageMixRow, scope: String, _ t: Translator) -> some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 1.5).fill(UsageColors.color(row.tone)).frame(width: 3)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.label).font(.system(size: 11)).foregroundStyle(.secondary)
        Text(row.value == nil ? t("usage.summary.notReported") : Format.exactNumber(row.value, t))
          .font(.system(size: 14, weight: .semibold))
        Text(scope).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One quota or balance meter (`MetricCard`).
struct UsageMetricCard: View {
  @EnvironmentObject private var model: AppModel
  let sourceName: String
  let metric: JSONValue
  var focused = false

  var body: some View {
    let t = model.t
    let remaining = Format.remainingPercent(metric)
    let tone = meterTone(remaining)
    let isBalance = metric["kind"]?.string == "balance"
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(sourceName)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 6)
        Badge(Format.metricValue(metric, t), tone: tone)
      }
      HStack(spacing: 6) {
        Image(systemName: isBalance ? "dollarsign.circle" : "gauge.with.dots.needle.33percent")
          .foregroundStyle(.secondary)
        Text(labelText(isBalance: isBalance, t)).font(.system(size: 13, weight: .semibold))
      }
      if let remaining {
        MeterBar(percent: remaining, tone: tone == .neutral ? .accent : tone)
          .accessibilityLabel(quotaLabel(remaining, t))
      }
      if !isBalance && UsageLogic.hasMetricCounts(metric) {
        facts(t)
      }
      if let detail = UsageLogic.nonEmpty(metric["detail"]?.string) {
        Text(t.backend(detail))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(resetLabel(t))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(focused ? Palette.accent : Palette.border, lineWidth: focused ? 2 : 1)
    )
    .animation(.easeOut(duration: 0.2), value: focused)
    .accessibilityElement(children: .combine)
  }

  private func meterTone(_ remaining: Double?) -> Tone {
    guard let remaining else { return .neutral }
    if remaining < 15 { return .danger }
    if remaining < 35 { return .warning }
    return .neutral
  }

  private func quotaLabel(_ remaining: Double, _ t: Translator) -> String {
    let name = UsageLogic.nonEmpty(metric["label"]?.string) ?? t("usage.metric.quota")
    return "\(name): \(t("usage.metric.percentRemaining", ["percent": Int(remaining.rounded())]))"
  }

  private func labelText(isBalance: Bool, _ t: Translator) -> String {
    let label = t.backend(metric["label"]?.string)
    if !label.isEmpty { return label }
    return isBalance ? t("usage.metric.balance") : t("usage.metric.usageLimit")
  }

  private func resetLabel(_ t: Translator) -> String {
    guard let reset = UsageLogic.metricResetAt(metric) else { return t("usage.metric.noReset") }
    return t("usage.metric.resets", [
      "date": Format.dateTime(.number(reset), t),
      "countdown": UsageLogic.resetCountdown(reset, t),
    ])
  }

  private func facts(_ t: Translator) -> some View {
    let unit = metric["unit"]?.string
    return HStack(alignment: .top, spacing: 16) {
      fact(t("usage.metric.used"), UsageLogic.formatMetricCount(metric["used"]?.double, unit: unit, t))
      fact(t("usage.metric.remaining"), UsageLogic.formatMetricCount(metric["remaining"]?.double, unit: unit, t))
      fact(t("usage.metric.limit"), UsageLogic.formatMetricCount(metric["limit"]?.double, unit: unit, t))
    }
  }

  private func fact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 12, weight: .medium))
    }
  }
}

/// One entry in the sources list (`SourceRow`).
struct UsageSourceRow: View {
  @EnvironmentObject private var model: AppModel
  let source: UsageSourceEntry
  let selected: Bool
  /// The last seven days of a subscription source (empty otherwise).
  let weekBuckets: [UsageDayBucket]
  let onSelect: () -> Void

  var body: some View {
    let t = model.t
    let isSubscription = source.kind == .subscription
    let measured = measuredTokens(isSubscription: isSubscription)
    let quota = quotaText(t)
    let help = quota.isEmpty ? "\(source.name) — \(source.detail)" : "\(source.name) — \(source.detail) — \(quota)"
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(source.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Text(source.detail)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        values(measured: measured, isSubscription: isSubscription, quota: quota, t)
        badges(isSubscription: isSubscription, t)
      }
      .padding(10)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? Palette.selection : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(selected ? Palette.accent.opacity(0.5) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func measuredTokens(isSubscription: Bool) -> Double? {
    if isSubscription {
      if source.buckets.isEmpty { return nil }
      return weekBuckets.reduce(0.0) { $0 + $1.tokens }
    }
    return source.totalTokens ?? source.last24hTokens
  }

  private func quotaText(_ t: Translator) -> String {
    guard let primary = source.metrics.first else { return "" }
    let label = t.backend(primary["label"]?.string)
    return "\(Format.metricValue(primary, t)) · \(label.isEmpty ? t("usage.source.accountMeter") : label)"
  }

  private func windowLabel(isSubscription: Bool, _ t: Translator) -> String {
    if isSubscription {
      return UsageLogic.hasFallbackDays(weekBuckets) ? t("usage.fallback.lastSeven") : t("usage.source.last7Openai")
    }
    if source.totalTokens == nil { return t("usage.source.last24hRouter") }
    return UsageLogic.nonEmpty(source.scopeLabel) ?? t("usage.scope.lastDays", ["days": UsageLogic.ledgerDays])
  }

  private func values(measured: Double?, isSubscription: Bool, quota: String, _ t: Translator) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      // Absent is not zero: a backend that never reported this window says
      // nothing, and printing "0 tok" for it reads a booked day as idle.
      Text(measured == nil
        ? t("usage.summary.notMeasured")
        : t("usage.source.tok", ["count": Format.compactNumber(measured, t)]))
        .font(.system(size: 13, weight: .semibold))
      Text(windowLabel(isSubscription: isSubscription, t))
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if !isSubscription, let recent = source.last24hTokens {
        Text(t("usage.source.recentTokens", ["count": Format.compactNumber(recent, t)]))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      if !quota.isEmpty {
        Text(quota).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }

  private func badges(isSubscription: Bool, _ t: Translator) -> some View {
    let status: String
    if source.kind == .aggregate {
      status = t("usage.source.allData")
    } else if isSubscription {
      status = UsageLogic.nonEmpty(source.plan).map(UsageLogic.friendlyPlanName) ?? t("usage.source.signedIn")
    } else {
      status = source.enabled ? t("usage.source.enabled") : t("usage.source.historical")
    }
    return VStack(alignment: .trailing, spacing: 4) {
      if selected { Badge(t("usage.sources.selected"), tone: .accent) }
      Badge(status, tone: source.enabled ? .success : .neutral)
    }
  }
}

/// Placeholder while the usage sources load (`UsageLoading`).
struct UsageLoadingView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        ForEach(0..<7, id: \.self) { _ in SkeletonBlock(height: 64) }
      }
      HStack(spacing: 12) {
        SkeletonBlock(height: 260)
        SkeletonBlock(height: 260)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.t("usage.loading.main"))
  }
}
