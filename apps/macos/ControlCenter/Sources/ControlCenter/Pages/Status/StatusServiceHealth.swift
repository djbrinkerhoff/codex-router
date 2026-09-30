import ControlCenterCore
import SwiftUI

// The service-health accordion of the Status page, ported from
// `ServiceHealth.tsx` and `service-health.ts`.

enum StatusHealthState { case ready, degraded, offline, standby, unknown }

struct StatusHealthRow: Identifiable {
  let id: String
  let label: String
  let state: StatusHealthState
  let status: String
  let detail: String
  let tone: Tone
}

enum StatusHealthLogic {
  /// Which forwarders the router can report on, in display order.
  private static let forwarders: [(id: String, key: String)] = [
    ("oauth", "serviceHealth.forwarder.oauth"),
    ("api", "serviceHealth.forwarder.api"),
    ("grokOauth", "serviceHealth.forwarder.grokOauth"),
  ]

  private static func dependencyRow(
    id: String,
    label: String,
    service: JSONValue?,
    degraded: Set<String>,
    routerOK: Bool?,
    _ t: Translator
  ) -> StatusHealthRow {
    guard let service, service.object != nil else {
      let offline = degraded.contains(id)
      // An absent per-service payload is not the same as no information. A
      // router that reported `ok` has already probed every dependency it
      // knows about, so an id missing from `degraded` is reachable.
      if !offline && routerOK == true {
        return StatusHealthRow(id: id, label: label, state: .ready, status: t("serviceHealth.ready"), detail: t("serviceHealth.reachable"), tone: .success)
      }
      return StatusHealthRow(
        id: id,
        label: label,
        state: offline ? .offline : .unknown,
        status: offline ? t("serviceHealth.offline") : t("serviceHealth.unknown"),
        detail: offline ? t("serviceHealth.unreachable") : t("serviceHealth.waiting"),
        tone: offline ? .danger : .neutral
      )
    }
    if service["enabled"]?.bool == false && !degraded.contains(id) {
      return StatusHealthRow(id: id, label: label, state: .standby, status: t("serviceHealth.standby"), detail: t("serviceHealth.notEnabled"), tone: .neutral)
    }
    let reachable = service["reachable"]?.bool
    if reachable != true || degraded.contains(id) {
      let offline = reachable == false || degraded.contains(id)
      return StatusHealthRow(
        id: id,
        label: label,
        state: offline ? .offline : .unknown,
        status: offline ? t("serviceHealth.offline") : t("serviceHealth.unknown"),
        detail: offline ? t("serviceHealth.unreachable") : t("serviceHealth.waiting"),
        tone: offline ? .danger : .neutral
      )
    }
    return StatusHealthRow(id: id, label: label, state: .ready, status: t("serviceHealth.ready"), detail: t("serviceHealth.reachable"), tone: .success)
  }

  static func rows(_ health: JSONValue?, _ t: Translator) -> [StatusHealthRow] {
    let degraded = Set((health?["degraded"]?.items ?? []).compactMap { $0.string })
    let hasHealth = health != nil
    var routerOK: Bool?
    if let health, let ok = health["ok"] { routerOK = ok.truthy }
    let ok = routerOK == true

    let routerState: StatusHealthState
    let routerStatus: String
    let routerDetail: String
    let routerTone: Tone
    if !hasHealth {
      routerState = .unknown
      routerStatus = t("serviceHealth.unknown")
      routerDetail = t("serviceHealth.waiting")
      routerTone = .neutral
    } else if ok {
      routerState = .ready
      routerStatus = t("serviceHealth.ready")
      routerDetail = t("serviceHealth.servingLocally")
      routerTone = .success
    } else if !degraded.isEmpty {
      routerState = .degraded
      routerStatus = t("serviceHealth.degraded")
      routerDetail = degraded.count == 1
        ? t("serviceHealth.dependencyAttention", ["count": degraded.count])
        : t("serviceHealth.dependenciesAttention", ["count": degraded.count])
      routerTone = .warning
    } else {
      routerState = .offline
      routerStatus = t("serviceHealth.offline")
      routerDetail = UsageLogic.nonEmpty(health?["error"]?.string) ?? t("serviceHealth.endpointUnavailable")
      routerTone = .danger
    }

    var rows: [StatusHealthRow] = [
      StatusHealthRow(id: "router", label: t("serviceHealth.router"), state: routerState, status: routerStatus, detail: routerDetail, tone: routerTone),
      dependencyRow(id: "gateway", label: t("serviceHealth.gateway"), service: health?["gateway"], degraded: degraded, routerOK: routerOK, t),
    ]
    var forwarderCount = 0
    for entry in forwarders {
      let service = health?[entry.id]
      let present = (service?.truthy ?? false) || degraded.contains(entry.id)
      guard present else { continue }
      forwarderCount += 1
      rows.append(dependencyRow(id: entry.id, label: t(entry.key), service: service, degraded: degraded, routerOK: routerOK, t))
    }
    if forwarderCount == 0 {
      rows.append(StatusHealthRow(
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

  static func attention(_ rows: [StatusHealthRow]) -> Int {
    rows.filter { $0.state == .offline || $0.state == .degraded }.count
  }

  static func icon(_ state: StatusHealthState) -> String {
    switch state {
    case .ready: return "checkmark.circle"
    case .offline: return "nosign"
    case .degraded: return "exclamationmark.circle"
    case .standby, .unknown: return "circle.dashed"
    }
  }
}

/// The collapsible service-health panel. A new problem reveals its detail, but
/// polling health every second never overrides the operator's own choice.
struct StatusServiceHealthPanel: View {
  let health: JSONValue?
  let t: Translator
  let onRepair: () -> Void
  let repairing: Bool
  @State private var detailsOpen: Bool
  @State private var previousAttention: Int

  init(health: JSONValue?, t: Translator, repairing: Bool, onRepair: @escaping () -> Void) {
    self.health = health
    self.t = t
    self.repairing = repairing
    self.onRepair = onRepair
    let attention = StatusHealthLogic.attention(StatusHealthLogic.rows(health, t))
    _detailsOpen = State(initialValue: attention > 0)
    _previousAttention = State(initialValue: attention)
  }

  var body: some View {
    let rows = StatusHealthLogic.rows(health, t)
    let attention = StatusHealthLogic.attention(rows)
    let allClear = rows.allSatisfy { $0.state == .ready || $0.state == .standby }
    let summary = attention > 0
      ? t("serviceHealth.needsAttention", ["count": attention])
      : (allClear ? t("serviceHealth.allClear") : t("serviceHealth.checking"))
    let summaryTone: Tone = attention > 0 ? .warning : (health != nil ? .success : .neutral)
    VStack(alignment: .leading, spacing: 10) {
      headerRow(attention: attention, summary: summary, tone: summaryTone)
      if detailsOpen {
        VStack(spacing: 8) {
          ForEach(rows) { row in
            rowView(row)
          }
        }
        .accessibilityLabel(t("serviceHealth.listAria"))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelStyle(padding: 14)
    .onChange(of: attention) { next in
      if next > previousAttention { detailsOpen = true }
      previousAttention = next
    }
  }

  private func headerRow(attention: Int, summary: String, tone: Tone) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Button {
        detailsOpen.toggle()
      } label: {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(t("serviceHealth.title")).font(.system(size: 13.5, weight: .semibold))
            Text(attention > 0 ? t("serviceHealth.attentionDetail") : t("serviceHealth.normalDetail"))
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Image(systemName: detailsOpen ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(t("serviceHealth.title"))
      .accessibilityValue(detailsOpen ? "expanded" : "collapsed")
      Spacer(minLength: 8)
      Badge(summary, tone: tone)
      if attention > 0 {
        Button(repairing ? t("serviceHealth.repairing") : t("serviceHealth.fix")) {
          onRepair()
        }
        .disabled(repairing)
      }
    }
  }

  private func rowView(_ row: StatusHealthRow) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: StatusHealthLogic.icon(row.state))
        .foregroundStyle(row.tone == .neutral ? Color.secondary : row.tone.color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.label).font(.system(size: 12.5, weight: .semibold))
        Text(row.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Badge(row.status, tone: row.tone)
    }
    .accessibilityElement(children: .combine)
  }
}
