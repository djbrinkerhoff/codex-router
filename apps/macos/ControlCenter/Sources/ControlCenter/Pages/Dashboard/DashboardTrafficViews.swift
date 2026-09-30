import ControlCenterCore
import SwiftUI

/// The token-split colors shared by the trend bars, its legend, and the
/// per-model facts (`--token-regular`, `--token-cached`, `--token-output`).
enum DashboardPalette {
  static let regularInput = Palette.hex("#5b8def")
  static let cachedInput = Palette.hex("#b477e3")
  static let output = Palette.hex("#ef8a5f")
  static let other = Color.secondary.opacity(0.45)

  static func color(_ kind: DashboardTrafficPart.Kind) -> Color {
    switch kind {
    case .regularInput: return regularInput
    case .cachedInput: return cachedInput
    case .output: return output
    case .other: return other
    }
  }
}

/// The 24h / 7d / 30d switch above the traffic chart (`TrafficRangePicker`).
struct DashboardRangePicker: View {
  @Binding var value: DashboardRange
  let label: String

  var body: some View {
    Picker(label, selection: $value) {
      ForEach(DashboardRange.allCases, id: \.self) { range in
        Text(range.title).tag(range)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 150)
    .accessibilityLabel(label)
  }
}

/// Hourly or daily traffic bars (`TrafficTrend`): stacked by token kind when
/// the router measured the split, otherwise a single series of tokens or, when
/// no upstream reported tokens, requests.
struct DashboardTrafficTrend: View {
  let buckets: [DashboardTrafficBucket]
  let hasTokens: Bool
  let range: DashboardRange
  let t: Translator

  private var chartHeight: CGFloat { 150 }
  private var barWidth: CGFloat { 13 }

  var body: some View {
    let maxTokens = buckets.reduce(1.0) { max($0, $1.tokens) }
    let maxRequests = buckets.reduce(1.0) { max($0, $1.requests) }
    let hasBreakdown = buckets.contains { $0.measuredBreakdown }
    let bucketLabel = range == .hours24 ? t("dashboard.trend.hourly") : t("dashboard.trend.daily")
    let breakdownLabel = hasTokens
      ? (hasBreakdown ? t("dashboard.trend.split") : t("dashboard.trend.byTokens"))
      : t("dashboard.trend.byRequests")
    let summary = t("dashboard.trend.aria", [
      "bucket": bucketLabel,
      "range": DashboardStats.trafficRangeLabel(range, t),
      "breakdown": breakdownLabel,
    ])
    let scaleTop = hasTokens ? Format.compactNumber(maxTokens, t) : Format.exactNumber(maxRequests, t)

    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .trailing, spacing: 0) {
          Text(scaleTop)
          Spacer(minLength: 0)
          Text("0")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: chartHeight, alignment: .trailing)
        .accessibilityHidden(true)

        VStack(spacing: 6) {
          bars(maxTokens: maxTokens, maxRequests: maxRequests, hasBreakdown: hasBreakdown)
          axis
        }
      }
      legend(hasBreakdown: hasBreakdown)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(summary)
  }

  private func bars(maxTokens: Double, maxRequests: Double, hasBreakdown: Bool) -> some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 0) {
        ForEach(0..<4, id: \.self) { _ in
          Spacer(minLength: 0)
          Rectangle().fill(Palette.border.opacity(0.5)).frame(height: 0.5)
        }
      }
      HStack(alignment: .bottom, spacing: 3) {
        ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
          slot(bucket, maxTokens: maxTokens, maxRequests: maxRequests, hasBreakdown: hasBreakdown)
        }
      }
      .padding(.horizontal, 3)
    }
    .frame(height: chartHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Palette.border).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func slot(
    _ bucket: DashboardTrafficBucket,
    maxTokens: Double,
    maxRequests: Double,
    hasBreakdown: Bool
  ) -> some View {
    let ratio = hasTokens ? bucket.tokens / maxTokens : bucket.requests / maxRequests
    let percent: Double = ratio > 0 ? max(4, ratio * 100) : 0
    let barHeight = chartHeight * CGFloat(percent / 100)
    let parts = DashboardStats.trafficParts(bucket, t)
    ZStack(alignment: .bottom) {
      Color.clear
      if hasBreakdown {
        stackedBar(bucket, parts: parts, height: barHeight)
      } else {
        plainBar(height: barHeight)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: chartHeight, alignment: .bottom)
    .contentShape(Rectangle())
    .help(tooltip(bucket, parts: parts))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spokenLabel(bucket, parts: parts))
  }

  private func plainBar(height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 2, style: .continuous)
      .fill(LinearGradient(
        colors: [Palette.accent.opacity(0.55), Palette.accent],
        startPoint: .top,
        endPoint: .bottom
      ))
      .opacity(0.85)
      .frame(maxWidth: barWidth)
      .frame(height: height)
  }

  private func stackedBar(_ bucket: DashboardTrafficBucket, parts: [DashboardTrafficPart], height: CGFloat) -> some View {
    // Regular input sits at the bottom, then cached input, output, and the
    // unattributed remainder on top (`flex-direction: column-reverse`).
    VStack(spacing: 0) {
      ForEach(Array(parts.reversed().enumerated()), id: \.offset) { _, part in
        Rectangle()
          .fill(DashboardPalette.color(part.kind))
          .frame(height: bucket.tokens > 0 ? height * CGFloat(part.tokens / bucket.tokens) : 0)
      }
    }
    .frame(maxWidth: barWidth)
    .frame(height: height, alignment: .bottom)
    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    .opacity(0.9)
  }

  private var axis: some View {
    HStack {
      Text(buckets.first?.label ?? "")
      Spacer(minLength: 4)
      Text(buckets.isEmpty ? "" : buckets[buckets.count / 2].label)
      Spacer(minLength: 4)
      Text(buckets.last?.label ?? "")
    }
    .font(.system(size: 9.5))
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .accessibilityHidden(true)
  }

  private func legend(hasBreakdown: Bool) -> some View {
    HStack(spacing: 14) {
      if hasBreakdown {
        legendItem(t("dashboard.trend.regular"), color: DashboardPalette.regularInput)
        legendItem(t("dashboard.trend.cached"), color: DashboardPalette.cachedInput)
        legendItem(t("dashboard.trend.output"), color: DashboardPalette.output)
      } else {
        legendItem(hasTokens ? t("dashboard.trend.tokens") : t("dashboard.trend.requests"), color: Palette.accent)
      }
      HStack(spacing: 5) {
        Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 6, height: 6)
        Text(t("dashboard.trend.requestVolume"))
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 10.5))
    .foregroundStyle(.secondary)
    .padding(.leading, 44)
    .accessibilityHidden(true)
  }

  private func legendItem(_ text: String, color: Color) -> some View {
    HStack(spacing: 5) {
      Capsule().fill(color).frame(width: 12, height: 3)
      Text(text)
    }
  }

  /// The hover tooltip (`TrafficTooltip`).
  private func tooltip(_ bucket: DashboardTrafficBucket, parts: [DashboardTrafficPart]) -> String {
    var lines: [String] = [bucket.fullLabel]
    if bucket.measuredTokens {
      lines.append(t("dashboard.tooltip.tokens", ["count": Format.compactNumber(bucket.tokens, t).uppercased()]))
      lines.append(t("dashboard.tooltip.totalTokens", ["count": Format.exactNumber(bucket.tokens, t)]))
    } else {
      lines.append(t("dashboard.tooltip.noTokens"))
    }
    if bucket.measuredBreakdown {
      for part in parts where part.tokens > 0 {
        lines.append("\(part.label): \(Format.exactNumber(part.tokens, t))")
      }
    }
    lines.append("\(t("dashboard.tooltip.requests")): \(Format.exactNumber(bucket.requests, t))")
    if !bucket.measuredTokens {
      lines.append(t("dashboard.tooltip.noUpstreamTokens"))
    } else if !bucket.measuredBreakdown {
      lines.append(t("dashboard.tooltip.noBreakdown"))
    }
    return lines.joined(separator: "\n")
  }

  private func spokenLabel(_ bucket: DashboardTrafficBucket, parts: [DashboardTrafficPart]) -> String {
    var pieces: [String] = ["\(bucket.fullLabel)."]
    if bucket.measuredTokens {
      pieces.append(t("dashboard.trend.total", ["count": Format.exactNumber(bucket.tokens, t)]))
    } else {
      pieces.append(t("dashboard.trend.noTokens"))
    }
    if bucket.measuredBreakdown {
      for part in parts where part.tokens > 0 {
        let value = t("dashboard.trend.partValue", ["label": part.label, "count": Format.exactNumber(part.tokens, t)])
        pieces.append("\(value).")
      }
    }
    pieces.append(t("dashboard.trend.requestsCount", ["count": Format.exactNumber(bucket.requests, t)]))
    return pieces.joined(separator: " ")
  }
}
