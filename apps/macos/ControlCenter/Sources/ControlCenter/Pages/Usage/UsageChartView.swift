import Charts
import ControlCenterCore
import SwiftUI

/// Series colors shared by the chart, its legend, the summary tiles and the
/// token mix (`--token-*` in usage-status.css).
enum UsageColors {
  static let regular = Palette.hex("#5b8def")
  static let cached = Palette.hex("#b477e3")
  static let output = Palette.hex("#ef8a5f")
  static let fallback = Palette.hex("#c88a24")
  static let other = Color.secondary.opacity(0.5)
  static let total = Palette.accent

  static func color(_ tone: UsageTokenTone) -> Color {
    switch tone {
    case .total: return total
    case .regular: return regular
    case .cached: return cached
    case .output: return output
    }
  }

  static func color(_ tone: UsagePartTone) -> Color {
    switch tone {
    case .regularInput: return regular
    case .cachedInput: return cached
    case .output: return output
    case .other: return other
    }
  }
}

private struct UsageLegendItem: Identifiable {
  let id: String
  let label: String
  let color: Color
  var dashed = false
}

/// The daily token chart, ported from `UsageChart`. Bars are stacked by
/// regular input, cached input, output and other when the source reports a
/// split, and plain totals otherwise. Days the router filled in for the
/// ChatGPT account are dimmed and marked at the baseline.
struct UsageChartView: View {
  @EnvironmentObject private var model: AppModel
  let buckets: [UsageDayBucket]
  let sourceKind: UsageSourceKind
  @State private var hovered: String?

  private static let seriesDomain: [String] = ["regular", "cached", "output", "other", "total"]
  private static let seriesColors: [Color] = [
    UsageColors.regular, UsageColors.cached, UsageColors.output, UsageColors.other, UsageColors.total,
  ]
  private static let tooltipWidth: CGFloat = 210

  var body: some View {
    let t = model.t
    let breakdownAvailable = buckets.contains { UsageLogic.tokenParts($0, t) != nil }
    let segments = UsageLogic.chartSegments(buckets, breakdownAvailable: breakdownAvailable, t)
    let fallbackDates = buckets.filter { $0.origin == .routerFallback }.map { $0.startDate }
    VStack(alignment: .leading, spacing: 8) {
      legend(items: legendItems(breakdownAvailable: breakdownAvailable, fallbackCount: fallbackDates.count, t))
      chart(segments: segments, fallbackDates: fallbackDates, breakdownAvailable: breakdownAvailable, t)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(ariaLabel(breakdownAvailable: breakdownAvailable, fallbackCount: fallbackDates.count, t))
  }

  // MARK: Legend

  private func legendItems(breakdownAvailable: Bool, fallbackCount: Int, _ t: Translator) -> [UsageLegendItem] {
    var items: [UsageLegendItem] = []
    if breakdownAvailable {
      if sourceKind == .subscription && fallbackCount > 0 {
        items.append(UsageLegendItem(id: "account", label: t("usage.chart.accountTotal"), color: UsageColors.total))
      }
      items.append(UsageLegendItem(id: "regular", label: t("usage.summary.regularInput"), color: UsageColors.regular))
      items.append(UsageLegendItem(id: "cached", label: t("usage.summary.cachedInput"), color: UsageColors.cached))
      items.append(UsageLegendItem(id: "output", label: t("usage.summary.output"), color: UsageColors.output))
    } else if sourceKind == .subscription {
      items.append(UsageLegendItem(id: "account", label: t("usage.chart.accountTotal"), color: UsageColors.total))
    } else {
      items.append(UsageLegendItem(id: "token", label: t("usage.chart.tokens"), color: UsageColors.total))
    }
    if fallbackCount > 0 {
      items.append(UsageLegendItem(id: "fallback", label: t("usage.fallback.legend"), color: UsageColors.fallback, dashed: true))
    }
    return items
  }

  private func legend(items: [UsageLegendItem]) -> some View {
    HStack(spacing: 14) {
      Spacer(minLength: 0)
      ForEach(items) { item in
        HStack(spacing: 5) {
          swatch(item)
          Text(item.label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func swatch(_ item: UsageLegendItem) -> some View {
    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
      .fill(item.color.opacity(item.dashed ? 0.3 : 1))
      .overlay(
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .strokeBorder(item.color, style: StrokeStyle(lineWidth: item.dashed ? 1.3 : 0, dash: [2, 1.5]))
      )
      .frame(width: 10, height: 10)
  }

  // MARK: Chart

  private func yMax(segments: [UsageChartSegment]) -> Double {
    var totals: [String: Double] = [:]
    for segment in segments { totals[segment.startDate, default: 0] += segment.tokens }
    var peak = 1.0
    for bucket in buckets { peak = max(peak, bucket.tokens) }
    for value in totals.values { peak = max(peak, value) }
    return peak
  }

  private func chart(segments: [UsageChartSegment], fallbackDates: [String], breakdownAvailable: Bool, _ t: Translator) -> some View {
    let top = yMax(segments: segments)
    let days = buckets.map { $0.startDate }
    return Chart {
      ForEach(segments) { segment in
        BarMark(
          x: .value("Day", segment.startDate),
          y: .value("Tokens", segment.tokens),
          width: .ratio(0.62)
        )
        .foregroundStyle(by: .value("Series", segment.series))
        .opacity(segment.fallback ? 0.55 : 1)
      }
      ForEach(fallbackDates, id: \.self) { date in
        PointMark(x: .value("Day", date), y: .value("Tokens", 0.0))
          .symbolSize(26)
          .foregroundStyle(UsageColors.fallback)
      }
      if let hovered {
        RuleMark(x: .value("Day", hovered))
          .foregroundStyle(Color.secondary.opacity(0.3))
      }
    }
    .chartXScale(domain: days)
    .chartYScale(domain: 0...top)
    .chartXAxis(.hidden)
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let number = value.as(Double.self) {
            Text(Format.compactNumber(number, t))
          }
        }
      }
    }
    .chartLegend(.hidden)
    .chartForegroundStyleScale(domain: Self.seriesDomain, range: Self.seriesColors)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        hoverLayer(proxy: proxy, geometry: geometry, breakdownAvailable: breakdownAvailable, t)
      }
    }
    .frame(height: 228)
  }

  // MARK: Hover

  private func hoverLayer(proxy: ChartProxy, geometry: GeometryProxy, breakdownAvailable: Bool, _ t: Translator) -> some View {
    let plot = geometry[proxy.plotAreaFrame]
    return ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(Color.clear)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let location):
            hovered = proxy.value(atX: location.x - plot.origin.x, as: String.self)
          case .ended:
            hovered = nil
          }
        }
      tooltipLayer(proxy: proxy, plot: plot, width: geometry.size.width, t)
    }
  }

  @ViewBuilder
  private func tooltipLayer(proxy: ChartProxy, plot: CGRect, width: CGFloat, _ t: Translator) -> some View {
    if let hovered, let bucket = buckets.first(where: { $0.startDate == hovered }), let position = proxy.position(forX: hovered) {
      let anchor = plot.origin.x + position
      let preferred = anchor + 14
      let left = preferred + Self.tooltipWidth > width ? anchor - Self.tooltipWidth - 14 : preferred
      UsageChartTooltip(bucket: bucket, sourceKind: sourceKind)
        .frame(width: Self.tooltipWidth, alignment: .leading)
        .offset(x: max(0, left), y: 4)
        .allowsHitTesting(false)
    }
  }

  private func ariaLabel(breakdownAvailable: Bool, fallbackCount: Int, _ t: Translator) -> String {
    if fallbackCount > 0 {
      return t(fallbackCount == 1 ? "usage.fallback.chartAriaOne" : "usage.fallback.chartAria", ["count": fallbackCount])
    }
    let source = sourceKind == .subscription ? t("usage.chart.dailyAccount") : t("usage.chart.dailyRouter")
    let breakdown = breakdownAvailable ? t("usage.chart.splitLabel") : t("usage.chart.totalsLabel")
    return t("usage.chart.aria", ["source": source, "breakdown": breakdown])
  }
}

/// The hover card for one day (`ChartTooltip`).
struct UsageChartTooltip: View {
  @EnvironmentObject private var model: AppModel
  let bucket: UsageDayBucket
  let sourceKind: UsageSourceKind

  var body: some View {
    let t = model.t
    let parts = (UsageLogic.tokenParts(bucket, t) ?? []).filter { $0.tokens > 0 }
    VStack(alignment: .leading, spacing: 4) {
      Text(UsageLogic.formatBucketDate(bucket.startDate, t))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text(t("usage.chart.tokensTotal", ["count": Format.compactNumber(bucket.tokens, t).uppercased()]))
        .font(.system(size: 13, weight: .semibold))
      Text(t("usage.chart.totalTokens", ["count": Format.exactNumber(bucket.tokens, t)]))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      if !parts.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(parts.indices, id: \.self) { index in
            partRow(parts[index], t)
          }
        }
        .padding(.top, 2)
      } else if bucket.origin != .routerFallback {
        Text(sourceKind == .subscription ? t("usage.tooltip.accountTotals") : t("usage.tooltip.noDetails"))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if bucket.origin == .routerFallback {
        Text(t("usage.fallback.tooltip"))
          .font(.system(size: 11))
          .foregroundStyle(UsageColors.fallback)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Palette.panel)
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
    )
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.border))
  }

  private func partRow(_ part: UsageTokenPart, _ t: Translator) -> some View {
    HStack(spacing: 6) {
      Circle().fill(UsageColors.color(part.tone)).frame(width: 7, height: 7)
      Text(part.label).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(Format.exactNumber(part.tokens, t)).font(.system(size: 11, weight: .semibold))
    }
  }
}
