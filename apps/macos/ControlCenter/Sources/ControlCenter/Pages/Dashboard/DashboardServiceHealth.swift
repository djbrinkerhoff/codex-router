import ControlCenterCore
import SwiftUI

// The service-health panel, ported from `ServiceHealth.tsx` and
// `service-health.ts`. The Dashboard shows the compact strip; the full
// accordion (with the optional repair action) is kept because it is the same
// component in the renderer.

enum DashboardServiceHealthState {
  case ready, degraded, offline, standby, unknown
}

struct DashboardServiceHealthRow: Identifiable {
  let id: String
  let label: String
  let state: DashboardServiceHealthState
  let status: String
  let detail: String
  let tone: Tone
}

enum DashboardServiceHealth {
  /// Which forwarders the router can report on. The ids live here so the row
  /// order cannot drift from the keys `printHealth` projects; wording goes
  /// through the shared dictionary so every locale renders the same rows.
  static let forwarders: [(id: String, labelKey: String)] = [
    (id: "oauth", labelKey: "serviceHealth.forwarder.oauth"),
    (id: "api", labelKey: "serviceHealth.forwarder.api"),
    (id: "grokOauth", labelKey: "serviceHealth.forwarder.grokOauth"),
  ]

  private static func degradedName(_ value: JSONValue) -> String {
    switch value {
    case .string(let text): return text
    case .number(let number): return DashboardJS.string(number)
    case .bool(let flag): return flag ? "true" : "false"
    default: return ""
    }
  }

  private static func dependencyRow(
    id: String,
    label: String,
    service: JSONValue?,
    degraded: Set<String>,
    routerOk: Bool?,
    t: Translator
  ) -> DashboardServiceHealthRow {
    guard let service = service else {
      let offline = degraded.contains(id)
      // An absent per-service payload is not the same as no information. A
      // router that reported `ok` has already probed every dependency it
      // knows about, so an id missing from `degraded` is reachable --
      // rendering it as Unknown made a healthy install look like it had never
      // answered.
      if !offline && routerOk == true {
        return DashboardServiceHealthRow(
          id: id, label: label, state: .ready, status: t("serviceHealth.ready"),
          detail: t("serviceHealth.reachable"), tone: .success
        )
      }
      return DashboardServiceHealthRow(
        id: id,
        label: label,
        state: offline ? .offline : .unknown,
        status: offline ? t("serviceHealth.offline") : t("serviceHealth.unknown"),
        detail: offline ? t("serviceHealth.unreachable") : t("serviceHealth.waiting"),
        tone: offline ? .danger : .neutral
      )
    }
    if service["enabled"]?.bool == false && !degraded.contains(id) {
      return DashboardServiceHealthRow(
        id: id, label: label, state: .standby, status: t("serviceHealth.standby"),
        detail: t("serviceHealth.notEnabled"), tone: .neutral
      )
    }
    if service["reachable"]?.bool != true || degraded.contains(id) {
      let down = service["reachable"]?.bool == false || degraded.contains(id)
      return DashboardServiceHealthRow(
        id: id,
        label: label,
        state: down ? .offline : .unknown,
        status: down ? t("serviceHealth.offline") : t("serviceHealth.unknown"),
        detail: down ? t("serviceHealth.unreachable") : t("serviceHealth.waiting"),
        tone: down ? .danger : .neutral
      )
    }
    return DashboardServiceHealthRow(
      id: id, label: label, state: .ready, status: t("serviceHealth.ready"),
      detail: t("serviceHealth.reachable"), tone: .success
    )
  }

  static func rows(health rawHealth: JSONValue?, t: Translator) -> [DashboardServiceHealthRow] {
    let health = DashboardJS.nullish(rawHealth)
    let degradedItems = health?["degraded"]?.items ?? []
    let degraded = Set(degradedItems.map { degradedName($0) })
    let hasHealth = health != nil
    let routerOk = health?["ok"].truthy ?? false
    let degradedCount = degraded.count

    let routerState: DashboardServiceHealthState
    let routerStatus: String
    let routerDetail: String
    let routerTone: Tone
    if !hasHealth {
      routerState = .unknown
      routerStatus = t("serviceHealth.unknown")
      routerDetail = t("serviceHealth.waiting")
      routerTone = .neutral
    } else if routerOk {
      routerState = .ready
      routerStatus = t("serviceHealth.ready")
      routerDetail = t("serviceHealth.servingLocally")
      routerTone = .success
    } else if degradedCount > 0 {
      routerState = .degraded
      routerStatus = t("serviceHealth.degraded")
      routerDetail = degradedCount == 1
        ? t("serviceHealth.dependencyAttention", ["count": degradedCount])
        : t("serviceHealth.dependenciesAttention", ["count": degradedCount])
      routerTone = .warning
    } else {
      routerState = .offline
      routerStatus = t("serviceHealth.offline")
      routerDetail = DashboardJS.nonEmpty(health?["error"]) ?? t("serviceHealth.endpointUnavailable")
      routerTone = .danger
    }

    var rows: [DashboardServiceHealthRow] = [
      DashboardServiceHealthRow(
        id: "router",
        label: t("serviceHealth.router"),
        state: routerState,
        status: routerStatus,
        detail: routerDetail,
        tone: routerTone
      )
    ]

    let routerReported: Bool? = health?["ok"]?.bool
    rows.append(dependencyRow(
      id: "gateway",
      label: t("serviceHealth.gateway"),
      service: DashboardJS.nullish(health?["gateway"]),
      degraded: degraded,
      routerOk: routerReported,
      t: t
    ))

    var reported = 0
    for forwarder in forwarders {
      let service = DashboardJS.nullish(health?[forwarder.id])
      if !service.truthy && !degraded.contains(forwarder.id) { continue }
      reported += 1
      rows.append(dependencyRow(
        id: forwarder.id,
        label: t(forwarder.labelKey),
        service: service,
        degraded: degraded,
        routerOk: routerReported,
        t: t
      ))
    }
    if reported == 0 {
      rows.append(DashboardServiceHealthRow(
        id: "forwarders",
        label: t("serviceHealth.externalForwarders"),
        state: hasHealth ? .standby : .unknown,
        status: hasHealth ? t("serviceHealth.standby") : t("serviceHealth.unknown"),
        detail: hasHealth ? t("serviceHealth.noForwarders") : t("serviceHealth.waiting"),
        tone: .neutral
      ))
    }
    return rows
  }

  static func attentionCount(_ rows: [DashboardServiceHealthRow]) -> Int {
    var count = 0
    for row in rows where row.state == .offline || row.state == .degraded {
      count += 1
    }
    return count
  }

  static func allSettled(_ rows: [DashboardServiceHealthRow]) -> Bool {
    for row in rows where !(row.state == .ready || row.state == .standby) {
      return false
    }
    return true
  }

  static func systemImage(_ state: DashboardServiceHealthState) -> String {
    switch state {
    case .ready: return "checkmark.circle"
    case .offline: return "xmark.circle"
    case .degraded: return "exclamationmark.circle"
    case .standby, .unknown: return "circle.dashed"
    }
  }

  static func color(_ state: DashboardServiceHealthState) -> Color {
    switch state {
    case .ready: return Palette.success
    case .offline: return Palette.danger
    case .degraded: return Palette.warning
    case .standby, .unknown: return Color.secondary
    }
  }
}

struct DashboardServiceHealthPanel: View {
  @EnvironmentObject private var model: AppModel
  private let health: JSONValue?
  private let compact: Bool
  private let onOpen: (() -> Void)?
  private let onRepair: (() -> Void)?
  private let repairing: Bool
  @State private var detailsOpen = false
  @State private var previousAttention: Int?

  init(
    health: JSONValue?,
    compact: Bool = false,
    onOpen: (() -> Void)? = nil,
    onRepair: (() -> Void)? = nil,
    repairing: Bool = false
  ) {
    self.health = health
    self.compact = compact
    self.onOpen = onOpen
    self.onRepair = onRepair
    self.repairing = repairing
  }

  var body: some View {
    let t = model.t
    let rows = DashboardServiceHealth.rows(health: health, t: t)
    let attention = DashboardServiceHealth.attentionCount(rows)
    let summary = attention > 0
      ? t("serviceHealth.needsAttention", ["count": attention])
      : (DashboardServiceHealth.allSettled(rows) ? t("serviceHealth.allClear") : t("serviceHealth.checking"))
    let summaryTone: Tone = attention > 0 ? .warning : (DashboardJS.nullish(health) != nil ? .success : .neutral)

    Group {
      if compact {
        compactStrip(rows: rows, summary: summary, tone: summaryTone, t: t)
      } else {
        accordion(rows: rows, attention: attention, summary: summary, tone: summaryTone, t: t)
      }
    }
    // A new problem should reveal its detail, but polling health every second
    // must never override the operator's own open/closed choice.
    .onAppear {
      if previousAttention == nil {
        previousAttention = attention
        if attention > 0 { detailsOpen = true }
      }
    }
    .onChange(of: attention) { next in
      if let previous = previousAttention, next > previous { detailsOpen = true }
      previousAttention = next
    }
  }

  private func compactStrip(rows: [DashboardServiceHealthRow], summary: String, tone: Tone, t: Translator) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text(t("serviceHealth.title"))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
        Badge(summary, tone: tone)
        Spacer(minLength: 8)
        if let onOpen = onOpen {
          Button {
            onOpen()
          } label: {
            HStack(spacing: 3) {
              Text(t("serviceHealth.details"))
              Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5))
          }
          .buttonStyle(.borderless)
        }
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
        ForEach(rows) { row in
          DashboardServiceHealthChip(row: row)
        }
      }
    }
    .panelStyle(padding: 12)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(t("serviceHealth.aria"))
  }

  private func accordion(
    rows: [DashboardServiceHealthRow],
    attention: Int,
    summary: String,
    tone: Tone,
    t: Translator
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        Button {
          detailsOpen.toggle()
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(t("serviceHealth.title")).font(.system(size: 13.5, weight: .semibold))
              Text(attention > 0 ? t("serviceHealth.attentionDetail") : t("serviceHealth.normalDetail"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Image(systemName: detailsOpen ? "chevron.down" : "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(detailsOpen ? .isSelected : [])
        Spacer(minLength: 8)
        Badge(summary, tone: tone)
        if let onRepair = onRepair, attention > 0 {
          Button(repairing ? t("serviceHealth.repairing") : t("serviceHealth.fix")) {
            onRepair()
          }
          .disabled(repairing)
        }
      }
      if detailsOpen {
        VStack(spacing: 0) {
          ForEach(rows) { row in
            Divider()
            DashboardServiceHealthRowView(row: row)
          }
        }
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("serviceHealth.listAria"))
      }
    }
    .panelStyle(padding: 14)
  }
}

private struct DashboardServiceHealthChip: View {
  let row: DashboardServiceHealthRow

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(DashboardServiceHealth.color(row.state))
        .frame(width: 7, height: 7)
      Text(row.label)
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
      Text(row.status)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DashboardServiceHealth.color(row.state).opacity(0.08)))
    .help("\(row.label): \(row.detail)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(row.label): \(row.status). \(row.detail)")
  }
}

private struct DashboardServiceHealthRowView: View {
  let row: DashboardServiceHealthRow

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: DashboardServiceHealth.systemImage(row.state))
        .font(.system(size: 14))
        .foregroundStyle(DashboardServiceHealth.color(row.state))
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.label).font(.system(size: 12.5, weight: .semibold))
        Text(row.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Badge(row.status, tone: row.tone)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }
}
