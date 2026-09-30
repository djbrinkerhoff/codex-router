import ControlCenterCore
import SwiftUI

/// One "Providers" or "Models" list of the mix panel (`BreakdownGroup`).
struct DashboardBreakdownGroup: View {
  let title: String
  let rows: [DashboardBreakdownRow]
  var providerRows = false
  let emptyTitle: String
  let emptyBody: String
  let t: Translator

  var body: some View {
    let visibleRows = Array(rows.prefix(5))
    let maximum = visibleRows.reduce(1.0) { max($0, $1.tokens) }

    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Spacer(minLength: 8)
        if rows.count > visibleRows.count {
          Text(t("dashboard.breakdown.top", ["shown": visibleRows.count, "total": rows.count]))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
      if visibleRows.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text(emptyTitle).font(.system(size: 12.5, weight: .semibold))
          if !emptyBody.isEmpty {
            Text(emptyBody)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
      } else {
        VStack(spacing: 12) {
          ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
            rowView(row, maximum: maximum)
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("dashboard.breakdown.aria", ["title": title]))
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private func logoProviderId(_ row: DashboardBreakdownRow) -> String {
    if let id = row.providerId, !id.isEmpty { return id }
    if row.id.hasPrefix("provider:") { return String(row.id.dropFirst("provider:".count)) }
    return row.id
  }

  private func subtitle(_ row: DashboardBreakdownRow) -> String {
    var text = ""
    if let provider = row.provider, !provider.isEmpty { text += "\(provider) · " }
    let word = t(row.requests == 1 ? "dashboard.word.request" : "dashboard.word.requests")
    text += "\(Format.exactNumber(row.requests, t)) \(word)"
    if row.measuredTokens {
      text += " · \(Format.compactNumber(row.tokens, t)) tok"
    } else {
      text += t("dashboard.breakdown.tokensNotReported")
    }
    return text
  }

  private func rowView(_ row: DashboardBreakdownRow, maximum: Double) -> some View {
    let share: Double = row.tokens > 0 ? max(2, (row.tokens / maximum) * 100) : 0
    return HStack(alignment: .top, spacing: 10) {
      ProviderLogo(
        providerId: logoProviderId(row),
        displayName: (row.provider?.isEmpty == false ? row.provider : nil) ?? row.label,
        size: 22
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(row.label)
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
          .help(row.label)
        Text(subtitle(row))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if !providerRows {
          DashboardModelFacts(row: row, t: t)
        }
        MeterBar(percent: share, tone: .accent)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(row.measuredTokens ? Format.compactNumber(row.tokens, t) : "—")
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct DashboardFact {
  enum Kind {
    case input, cached, output, speed
  }

  let label: String
  let kind: Kind

  var color: Color {
    switch kind {
    case .input: return DashboardPalette.regularInput
    case .cached: return DashboardPalette.cachedInput
    case .output: return DashboardPalette.output
    case .speed: return Color.secondary
    }
  }
}

/// The input / cache / output / speed line under a model row
/// (`ModelBreakdownFacts`). Draws nothing when the row has none of them.
struct DashboardModelFacts: View {
  let row: DashboardBreakdownRow
  let t: Translator

  private func facts() -> [DashboardFact] {
    var facts: [DashboardFact] = []
    if let input = row.inputTokens {
      facts.append(DashboardFact(label: t("dashboard.facts.input", ["count": Format.compactNumber(input, t)]), kind: .input))
    }
    if let cached = row.cachedInputTokens {
      facts.append(DashboardFact(label: t("dashboard.facts.cache", ["count": Format.compactNumber(cached, t)]), kind: .cached))
    }
    if let output = row.outputTokens {
      facts.append(DashboardFact(label: t("dashboard.facts.output", ["count": Format.compactNumber(output, t)]), kind: .output))
    }
    if let speed = row.tokensPerSecond {
      facts.append(DashboardFact(label: DashboardStats.formatTokensPerSecond(speed), kind: .speed))
    }
    return facts
  }

  var body: some View {
    let items = facts()
    if !items.isEmpty {
      HStack(spacing: 8) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, fact in
          Text(fact.label)
            .foregroundStyle(fact.color)
            .lineLimit(1)
        }
      }
      .font(.system(size: 10.5, weight: .medium))
      .help(items.map { $0.label }.joined(separator: " · "))
    }
  }
}

/// One line of the recent-activity list (`DashboardEventRow`).
struct DashboardEventRow: View {
  let event: DashboardEvent
  let t: Translator

  private func statusTone() -> Tone {
    guard let status = event.status else { return .neutral }
    if status >= 400 { return .danger }
    if status >= 200 { return .success }
    return .neutral
  }

  private func durationText() -> String {
    if DashboardJS.nullish(event.durationMs) == nil { return t("dashboard.event.noDuration") }
    return Format.duration(DashboardJS.numberOrZero(event.durationMs), t)
  }

  var body: some View {
    let status = event.status
    let total = DashboardStats.tokenCount(event)
    let speed = DashboardStats.tokensPerSecond(event)
    let breakdown = DashboardStats.tokenBreakdown(event)
    let tokenFacts = DashboardStats.formatEventTokenFacts(total: total, breakdown: breakdown, t: t)
    let provider = event.provider ?? t("dashboard.event.router")

    HStack(alignment: .center, spacing: 12) {
      ProviderLogo(providerId: provider, displayName: event.provider, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(DashboardStats.shortModelName(event.model ?? t("dashboard.event.unknownModel")))
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
        Text(provider)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(speed == nil ? t("dashboard.event.speedUnmeasured") : DashboardStats.formatTokensPerSecond(speed ?? 0))
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
        Text(tokenFacts)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(tokenFacts)
      }
      .frame(width: 170, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(durationText())
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
        Text(Format.dateTime(JSONValue.string(event.at), t))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 120, alignment: .leading)
      Badge(status == nil ? t("dashboard.event.noStatus") : DashboardJS.string(status ?? 0), tone: statusTone())
        .frame(minWidth: 52, alignment: .trailing)
    }
    .padding(.vertical, 7)
    .accessibilityElement(children: .combine)
  }
}
