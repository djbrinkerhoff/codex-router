import Charts
import ControlCenterCore
import SwiftUI

// Building blocks for the Status page: the summary strip, the router activity
// orb, list rows and the compaction-savings chart.

/// The headline strip (`StatusSummary`); a pending item shows a skeleton.
struct StatusSummaryGrid: View {
  let items: [StatusSummaryEntry]

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 140), spacing: 0, alignment: .top)],
      alignment: .leading,
      spacing: 0
    ) {
      ForEach(items) { item in
        tile(item)
      }
    }
    .panelStyle()
  }

  private func tile(_ item: StatusSummaryEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.label.uppercased())
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if item.pending {
        SkeletonBlock(height: 22, width: 80)
        SkeletonBlock(height: 11, width: 110)
      } else {
        Text(item.value)
          .font(.system(size: 20, weight: .semibold, design: .rounded))
          .foregroundStyle(item.tone?.color ?? Color.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        Text(item.detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .help(item.detail)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
  }
}

/// A pulsing marker for the router's state (`RouterActivityOrb`).
struct StatusActivityOrb: View {
  let state: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var expanded = false

  private var color: Color {
    switch state {
    case "generating": return Palette.accent
    case "starting": return Palette.warning
    case "error", "offline": return Palette.danger
    default: return Palette.success
    }
  }

  private var animates: Bool { state == "generating" || state == "starting" }

  var body: some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.18))
        .frame(width: 44, height: 44)
        .scaleEffect(animates && expanded ? 1.25 : 1)
      Circle()
        .stroke(color.opacity(0.5), lineWidth: 1.5)
        .frame(width: 26, height: 26)
      Circle()
        .fill(color)
        .frame(width: 14, height: 14)
    }
    .frame(width: 52, height: 52)
    .onAppear { restart() }
    .onChange(of: state) { _ in restart() }
    .accessibilityHidden(true)
  }

  private func restart() {
    expanded = false
    guard animates, !reduceMotion else { return }
    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
      expanded = true
    }
  }
}

/// A small heading with a description, for a subsection of a panel.
struct StatusSubsectionHeading<Accessory: View>: View {
  let title: String
  let description: String
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(description)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      accessory()
    }
  }
}

extension StatusSubsectionHeading where Accessory == EmptyView {
  init(title: String, description: String) {
    self.init(title: title, description: description, accessory: { EmptyView() })
  }
}

/// A labelled figure with a caption (`st-context-windows`, `st-context-stats`).
struct StatusFigureTile: View {
  let label: String
  let value: String
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
      Text(caption)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    .accessibilityElement(children: .combine)
  }
}

// MARK: Live requests

/// One in-flight request (`st-live-list` article).
struct StatusLiveRequestRow: View {
  @EnvironmentObject private var model: AppModel
  let request: JSONValue
  let state: String

  var body: some View {
    let t = model.t
    let isAgent = StatusLogic.isAgent(request)
    let provider = UsageLogic.nonEmpty(request["provider"]?.string)
    let modelName = UsageLogic.nonEmpty(request["model"]?.string)
    let session = StatusLogic.requestSessionName(request)
    HStack(alignment: .center, spacing: 10) {
      ProviderLogo(providerId: provider ?? "openai", displayName: provider, size: 24)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(StatusLogic.requestTitle(request, t)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Badge(isAgent ? t("status.agent") : t("status.chat"), tone: isAgent ? .accent : .neutral)
        }
        Text(metaText(provider: provider, model: modelName, session: session, t))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 1) {
        Text(StatusLogic.requestActivityLabel(state, t)).font(.system(size: 12, weight: .semibold))
        Text("· " + StatusLogic.liveElapsedLabel(request)).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private func metaText(provider: String?, model: String?, session: String?, _ t: Translator) -> String {
    var parts: [String] = [provider ?? t("status.routerFallback")]
    if let model { parts.append(StatusLogic.shortModelName(model)) }
    if let session { parts.append(session) }
    return parts.joined(separator: "  ·  ")
  }
}

// MARK: Compaction savings

/// The tool-result compaction chart (`ContextSavingsChart`): one bar per
/// bucket, dimmed when nothing was saved.
struct StatusSavingsChart: View {
  @EnvironmentObject private var model: AppModel
  let buckets: [Double]
  let range: StatusSavingsRange
  let savedTokens: Double
  let requests: Double
  @State private var hovered: Int?

  var body: some View {
    let t = model.t
    let peak = max(buckets.max() ?? 0, 1)
    VStack(alignment: .leading, spacing: 6) {
      Text(hoverText(t))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(height: 14, alignment: .leading)
      chart(peak: peak)
      HStack {
        Text(t("status.chart.footer", ["saved": Format.exactNumber(savedTokens, t), "requests": Format.exactNumber(requests, t)]))
        Spacer()
        Text(t("status.chart.peak", ["peak": Format.compactNumber(peak, t), "bucket": range.bucketLabel]))
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(t("status.chart.aria", [
      "saved": Format.exactNumber(savedTokens, t),
      "requests": Format.exactNumber(requests, t),
      "range": range.label,
      "peak": Format.exactNumber(peak, t),
      "bucket": range.bucketLabel,
    ]))
  }

  private func hoverText(_ t: Translator) -> String {
    guard let hovered, buckets.indices.contains(hovered) else { return " " }
    return t("status.chart.tokensSavedTitle", ["count": Format.exactNumber(buckets[hovered], t)])
  }

  private func chart(peak: Double) -> some View {
    let keys = buckets.indices.map { String($0) }
    return Chart {
      ForEach(buckets.indices, id: \.self) { index in
        BarMark(
          x: .value("Bucket", String(index)),
          yStart: .value("Base", 0.0),
          yEnd: .value("Tokens", buckets[index] > 0 ? buckets[index] : peak * 0.04),
          width: .ratio(0.7)
        )
        .foregroundStyle(buckets[index] > 0 ? Palette.accent : Color.secondary.opacity(0.3))
        .opacity(hovered == nil || hovered == index ? 1 : 0.55)
      }
    }
    .chartXScale(domain: keys)
    .chartYScale(domain: 0...peak)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle()
          .fill(Color.clear)
          .contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              let origin = geometry[proxy.plotAreaFrame].origin
              if let key = proxy.value(atX: location.x - origin.x, as: String.self) {
                hovered = Int(key)
              } else {
                hovered = nil
              }
            case .ended:
              hovered = nil
            }
          }
      }
    }
    .frame(height: 64)
  }
}

// MARK: Models

/// One model's traffic (`StatusModelRow`).
struct StatusModelRowView: View {
  @EnvironmentObject private var model: AppModel
  let usage: StatusModelUsage
  let peak: Double

  var body: some View {
    let t = model.t
    let total = usage.totalTokens ?? 0
    let width = max(total > 0 ? 1.5 : 0, total / peak * 100)
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 10) {
        ProviderLogo(providerId: usage.providerID, displayName: usage.providerName, size: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(usage.title ?? t("status.model.unknown")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Text(usage.providerName).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
        Text(total > 0
          ? t("status.model.tok", ["count": Format.compactNumber(total, t)])
          : t("status.model.req", ["count": Int((usage.requests ?? 0).rounded())]))
          .font(.system(size: 13, weight: .semibold))
      }
      MeterBar(percent: width, tone: .accent)
        .accessibilityLabel(t("status.model.meterAria", ["count": Format.exactNumber(total, t)]))
      Text(facts(t))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
  }

  private func facts(_ t: Translator) -> String {
    var parts: [String] = [
      t("status.model.input", ["count": Format.compactNumber(usage.inputTokens ?? 0, t)]),
      t("status.model.output", ["count": Format.compactNumber(usage.outputTokens ?? 0, t)]),
      t("status.model.requests", ["count": Format.exactNumber(usage.requests ?? 0, t)]),
    ]
    if let speed = usage.speed {
      parts.append(String(format: "%.1f", speed) + " tok/s")
    } else {
      parts.append(t("status.model.speedUnmeasured"))
    }
    if let samples = usage.speedSamples, samples != 0 {
      parts.append(t("status.model.speedSamples", ["count": Format.exactNumber(samples, t)]))
    }
    return parts.joined(separator: "  ·  ")
  }
}

// MARK: Quota resets and speed

struct StatusResetRowView: View {
  @EnvironmentObject private var model: AppModel
  let row: StatusResetRow

  var body: some View {
    let t = model.t
    HStack(alignment: .center, spacing: 10) {
      ProviderLogo(providerId: row.providerID, displayName: row.provider, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.provider).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(label(t)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 1) {
        Text(StatusLogic.resetCountdown(row.timestamp, t)).font(.system(size: 13, weight: .semibold))
        Text(Format.dateTime(row.resetValue, t)).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private func label(_ t: Translator) -> String {
    guard let remaining = row.remaining else { return row.label }
    return "\(row.label), \(t("status.quota.percentLeft", ["percent": Int(remaining.rounded())]))"
  }
}

struct StatusSpeedRowView: View {
  @EnvironmentObject private var model: AppModel
  let usage: StatusModelUsage

  var body: some View {
    let t = model.t
    HStack(alignment: .center, spacing: 10) {
      ProviderLogo(providerId: usage.providerID, displayName: usage.providerName, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(usage.title ?? t("status.model.unknown")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        Text(usage.providerName).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 1) {
        Text(String(format: "%.1f", usage.speed ?? 0) + " tok/s").font(.system(size: 13, weight: .semibold))
        Text(sampleText(t)).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  private func sampleText(_ t: Translator) -> String {
    if let samples = usage.speedSamples, samples != 0 {
      return t("status.speed.successfulSamples", ["count": Format.exactNumber(samples, t)])
    }
    return t("status.speed.sampleUnavailable")
  }
}

// MARK: Recent events

/// One routed request from the recent-activity list (`EventRow`).
struct StatusEventRow: View {
  @EnvironmentObject private var model: AppModel
  let event: JSONValue

  var body: some View {
    let t = model.t
    let status = event["status"]?.double
    let success = (status ?? 0) >= 200 && (status ?? 0) < 400
    let failure = (status ?? 0) >= 400
    let provider = UsageLogic.nonEmpty(event["provider"]?.string)
    let flag = StatusLogic.eventFlag(event, t)
    HStack(alignment: .center, spacing: 10) {
      ProviderLogo(providerId: provider ?? "router", displayName: provider, size: 22)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(failure ? Palette.danger : (success ? Palette.success : Color.clear), lineWidth: 1.5)
        )
      VStack(alignment: .leading, spacing: 1) {
        Text(StatusLogic.shortModelName(UsageLogic.nonEmpty(event["model"]?.string) ?? t("status.model.unknown")))
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(provider ?? t("status.routerFallback"))
          .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      metering(t)
        .frame(width: 118, alignment: .trailing)
      duration(status: status, t)
        .frame(width: 84, alignment: .trailing)
      Text(Format.dateTime(event["at"], t))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: 112, alignment: .trailing)
      HStack {
        if let flag { Badge(flag, tone: failure ? .danger : .warning) }
      }
      .frame(width: 118, alignment: .trailing)
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
  }

  private func totalTokens() -> Double? {
    if let total = event["totalTokens"]?.double { return total }
    let input = event["inputTokens"]?.double
    let output = event["outputTokens"]?.double
    if input != nil || output != nil { return (input ?? 0) + (output ?? 0) }
    return nil
  }

  private func metering(_ t: Translator) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(totalTokens() == nil
        ? t("status.event.unmetered")
        : t("status.model.tok", ["count": Format.compactNumber(totalTokens(), t)]))
        .font(.system(size: 12.5, weight: .semibold))
      Text(event["cachedInputTokens"]?.double == nil
        ? t("status.event.noCacheDetail")
        : t("status.event.cached", ["count": Format.compactNumber(event["cachedInputTokens"]?.double, t)]))
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func duration(status: Double?, _ t: Translator) -> some View {
    let milliseconds = event["durationMs"]?.double ?? 0
    return VStack(alignment: .trailing, spacing: 1) {
      Text(milliseconds != 0 ? Format.duration(milliseconds, t) : t("status.event.noDuration"))
        .font(.system(size: 12.5, weight: .semibold))
      Text(statusText(status, t))
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func statusText(_ status: Double?, _ t: Translator) -> String {
    guard let status, status != 0 else { return t("status.event.noStatus") }
    return String(Int(status.rounded()))
  }
}
