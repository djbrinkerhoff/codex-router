import ControlCenterCore
import SwiftUI

/// One of the five headline tiles. Each opens the page that owns the detail.
struct DashboardTile: Identifiable {
  let id: String
  let label: String
  let systemImage: String
  let value: String
  let detail: String
  let tone: Tone?
  /// 0...100, drawn as a meter under the value.
  let meter: Double?
  let view: ViewID
  let viewLabel: String
  /// Shows a skeleton instead of the value and detail.
  let pending: Bool
}

extension DashboardContext {
  /// The router-state, live, tokens, next-reset, and lowest-allowance tiles.
  func tiles() -> [DashboardTile] {
    let statusLabel = t("dashboard.view.status")
    let usageLabel = t("dashboard.view.usage")
    return [
      routerTile(viewLabel: statusLabel),
      liveTile(viewLabel: statusLabel),
      tokensTile(viewLabel: usageLabel),
      resetTile(viewLabel: usageLabel),
      allowanceTile(viewLabel: usageLabel),
    ]
  }

  private func routerTile(viewLabel: String) -> DashboardTile {
    let value: String
    let detail: String
    var tone: Tone?
    if let health = health {
      let ok = health["ok"].truthy
      value = ok ? t("status.summary.online") : t("status.summary.offline")
      if ok {
        var text = DashboardStats.activityLabel(routerState, t)
        if let version = DashboardJS.nonEmpty(health["version"]) {
          text += t("dashboard.tile.version", ["version": version])
        }
        detail = text
      } else {
        detail = DashboardJS.nonEmpty(health["error"]) ?? t("dashboard.tile.healthNoAnswer")
      }
      tone = ok ? .success : .danger
    } else {
      value = pending
      detail = refreshing ? t("dashboard.tile.contacting") : t("dashboard.tile.healthUnread")
    }
    return DashboardTile(
      id: "router",
      label: t("dashboard.tile.routerState"),
      systemImage: "waveform.path.ecg",
      value: value,
      detail: detail,
      tone: tone,
      meter: nil,
      view: .status,
      viewLabel: viewLabel,
      pending: healthPending
    )
  }

  private func liveTile(viewLabel: String) -> DashboardTile {
    let value: String
    let detail: String
    if health == nil {
      value = pending
      detail = t("dashboard.tile.waitingHealth")
    } else if activityMeasured {
      value = Format.exactNumber(liveCount, t)
      let chats = t(chatCount == 1 ? "dashboard.word.chat" : "dashboard.word.chats")
      let subagents = t(subagentCount == 1 ? "dashboard.word.subagent" : "dashboard.word.subagents")
      detail = "\(Format.exactNumber(Double(chatCount), t)) \(chats) · \(Format.exactNumber(Double(subagentCount), t)) \(subagents)"
    } else {
      value = t("dashboard.tile.notMeasured")
      detail = t("dashboard.tile.liveUnreported")
    }
    return DashboardTile(
      id: "live",
      label: t("dashboard.tile.liveNow"),
      systemImage: "point.3.connected.trianglepath.dotted",
      value: value,
      detail: detail,
      tone: activityMeasured && (liveCount ?? 0) > 0 ? .accent : nil,
      meter: nil,
      view: .status,
      viewLabel: viewLabel,
      pending: healthPending
    )
  }

  private func tokensTile(viewLabel: String) -> DashboardTile {
    let value: String
    let detail: String
    if !usageMeasured {
      value = pending
      detail = t("dashboard.tile.waitingTelemetry")
    } else if let tokens = tokens24h {
      value = Format.compactNumber(tokens, t)
      var text = t("dashboard.tile.routerTokens", ["count": Format.exactNumber(tokens, t)])
      if let requests = requests24h {
        let word = t(requests == 1 ? "dashboard.word.request" : "dashboard.word.requests")
        text += t("dashboard.tile.requestsSuffix", ["count": Format.exactNumber(requests, t), "word": word])
      }
      let source: String
      if reportedTokens24h != nil {
        source = t("dashboard.tile.source.providerRows")
      } else if rollupTokens24h != nil {
        source = t("dashboard.tile.source.hourlyRollup")
      } else {
        source = t("dashboard.tile.source.eventDetails")
      }
      detail = "\(text) · \(source)"
    } else {
      value = t("dashboard.tile.notMeasured")
      detail = t("dashboard.tile.noRollingWindow")
    }
    return DashboardTile(
      id: "tokens",
      label: t("dashboard.tile.tokensLabel"),
      systemImage: "gauge.with.dots.needle.33percent",
      value: value,
      detail: detail,
      tone: nil,
      meter: nil,
      view: .usage,
      viewLabel: viewLabel,
      pending: snapshotPending && providerUsage == nil
    )
  }

  private func resetTile(viewLabel: String) -> DashboardTile {
    let value: String
    let detail: String
    if !quotaLoaded {
      value = pending
      detail = t("dashboard.tile.waitingUsage")
    } else if let reset = nextReset {
      value = DashboardStats.resetCountdown(reset.resetAt, now: now, t)
      detail = "\(reset.entry.provider), \(reset.entry.label) · \(Format.dateTime(reset.resetAt, t))"
    } else {
      value = t("dashboard.tile.notReported")
      detail = t("dashboard.tile.noResetTimestamp")
    }
    return DashboardTile(
      id: "reset",
      label: t("dashboard.tile.nextReset"),
      systemImage: "clock",
      value: value,
      detail: detail,
      tone: nil,
      meter: nil,
      view: .usage,
      viewLabel: viewLabel,
      pending: quotaPending
    )
  }

  private func allowanceTile(viewLabel: String) -> DashboardTile {
    let value: String
    let detail: String
    if !quotaLoaded {
      value = pending
      detail = t("dashboard.tile.waitingUsage")
    } else if let lowest = lowestAllowance {
      value = t("dashboard.tile.percentLeft", ["percent": Int(lowest.percent.rounded())])
      var text = "\(lowest.entry.provider), \(lowest.entry.label)"
      if let plan = DashboardJS.nonEmpty(account?["planType"]) {
        text += t("dashboard.tile.plan", ["plan": DashboardStats.friendlyPlanName(plan)])
      }
      detail = text
    } else {
      value = t("dashboard.tile.notMeasured")
      detail = t("dashboard.tile.noRemainingShare")
    }
    return DashboardTile(
      id: "allowance",
      label: t("dashboard.tile.lowestAllowance"),
      systemImage: "gauge",
      value: value,
      detail: detail,
      tone: allowanceTone,
      meter: lowestAllowance?.percent,
      view: .usage,
      viewLabel: viewLabel,
      pending: quotaPending
    )
  }
}

/// The five tiles as one bordered strip (`db-summary-grid`).
struct DashboardSummaryTiles: View {
  let tiles: [DashboardTile]
  let t: Translator
  let onOpen: (ViewID) -> Void

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 0, alignment: .top)], alignment: .leading, spacing: 0) {
      ForEach(tiles) { tile in
        DashboardTileCell(tile: tile, t: t) { onOpen(tile.view) }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .panelStyle()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(t("dashboard.summaryAria"))
  }
}

private struct DashboardTileCell: View {
  let tile: DashboardTile
  let t: Translator
  let action: () -> Void

  private var valueColor: Color {
    tile.tone?.color ?? Color.primary
  }

  private var meterTone: Tone {
    if tile.tone == .danger { return .danger }
    if tile.tone == .warning { return .warning }
    return .accent
  }

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          Image(systemName: tile.systemImage).font(.system(size: 10))
          Text(tile.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        if tile.pending {
          SkeletonBlock(height: 24, width: 96)
        } else {
          Text(tile.value)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        if let meter = tile.meter {
          MeterBar(percent: max(2, min(100, meter)), tone: meterTone)
        }
        if tile.pending {
          SkeletonBlock(height: 20)
        } else {
          Text(tile.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        HStack(spacing: 3) {
          Text(t("dashboard.tile.viewLink", ["view": tile.viewLabel]))
          Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
      .background(Palette.panel)
      .overlay(Rectangle().strokeBorder(Palette.border.opacity(0.6), lineWidth: 0.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(tile.label): \(tile.value). \(tile.detail). \(t("dashboard.tile.open", ["view": tile.viewLabel]))"
    )
    .accessibilityAddTraits(.isButton)
  }
}
