import ControlCenterCore
import SwiftUI

// The panels of the Status page. Each takes the precomputed `StatusData`.

/// Router activity and the list of requests in flight (`st-live-panel`).
struct StatusLivePanel: View {
  @EnvironmentObject private var model: AppModel
  let data: StatusData
  let health: JSONValue?

  var body: some View {
    let t = model.t
    VStack(alignment: .leading, spacing: 14) {
      SectionHeading(
        title: t("status.routerActivity.title"),
        description: t("status.routerActivity.description")
      )
      if data.healthPending {
        PanelSkeleton(label: t("status.loading.liveActivity"), count: 4)
      } else {
        routerState(t)
        StatusSubsectionHeading(
          title: t("status.liveRequests.title"),
          description: t("status.liveRequests.description")
        ) {
          Badge(t("status.liveCount", ["count": data.activeRequestCount]), tone: data.activeRequestCount > 0 ? .accent : .neutral)
        }
        requestList(t)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panelStyle(padding: 16)
  }

  private func routerState(_ t: Translator) -> some View {
    var ok = false
    if let health { ok = health["ok"].truthy }
    var subtitle = t("status.router.unavailable")
    if let activeModel = UsageLogic.nonEmpty(health?["activity"]?["model"]?.string) {
      subtitle = activeModel
    } else if ok {
      subtitle = t("status.router.readyForRequests")
    } else if let error = UsageLogic.nonEmpty(health?["error"]?.string) {
      subtitle = error
    }
    let badgeTone: Tone = ok ? .success : (health != nil ? .danger : .neutral)
    let badgeText = ok ? t("status.badge.reachable") : (health != nil ? t("status.badge.offline") : t("status.badge.checking"))
    return HStack(spacing: 12) {
      StatusActivityOrb(state: data.state)
      VStack(alignment: .leading, spacing: 2) {
        Text(StatusLogic.activityLabel(data.state, t)).font(.system(size: 14, weight: .semibold))
        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 8)
      Badge(badgeText, tone: badgeTone)
    }
  }

  @ViewBuilder
  private func requestList(_ t: Translator) -> some View {
    if data.active.isEmpty {
      EmptyStateView(
        systemImage: "waveform.path.ecg",
        title: data.activeRequestCount > 0 ? t("status.empty.requestStarting") : t("status.empty.routerIdle"),
        message: data.activeRequestCount > 0 ? t("status.empty.requestStartingBody") : t("status.empty.routerIdleBody")
      )
    } else {
      VStack(spacing: 0) {
        ForEach(Array(data.active.enumerated()), id: \.offset) { entry in
          if entry.offset > 0 { Divider() }
          StatusLiveRequestRow(request: entry.element, state: data.state)
        }
      }
      .accessibilityLabel(t("status.liveRequestsAria"))
    }
  }
}

/// Cache reuse and compaction savings (`st-context-panel`).
struct StatusContextPanel: View {
  @EnvironmentObject private var model: AppModel
  let data: StatusData
  @Binding var range: StatusSavingsRange
  let onRangeChosen: () -> Void

  var body: some View {
    let t = model.t
    VStack(alignment: .leading, spacing: 14) {
      SectionHeading(title: t("status.context.title"), description: t("status.context.description"))
      if data.contextPending {
        PanelSkeleton(label: t("status.loading.contextEfficiency"), count: 4)
      } else {
        StatusSubsectionHeading(title: t("status.context.cachedSaved"), description: t("status.context.cachedSavedDesc"))
        windows(t)
        cacheDetail(t)
        compaction(t)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panelStyle(padding: 16)
  }

  private func windows(_ t: Translator) -> some View {
    HStack(alignment: .top, spacing: 10) {
      ForEach(data.contextWindows) { row in
        StatusFigureTile(
          label: row.label,
          value: row.value == nil ? t("status.summary.notReported") : Format.compactNumber(row.value, t),
          caption: row.value == nil
            ? t("status.context.waitingCacheWindow")
            : t("status.context.tokensSaved", ["count": Format.exactNumber(row.value, t)])
        )
      }
    }
  }

  @ViewBuilder
  private func cacheDetail(_ t: Translator) -> some View {
    if data.hasCacheTelemetry {
      HStack(alignment: .top, spacing: 10) {
        StatusFigureTile(
          label: t("status.context.cachedInput"),
          value: Format.compactNumber(data.cachedInputTokens, t),
          caption: t("status.context.tokensReused", ["count": Format.exactNumber(data.cachedInputTokens, t)])
        )
        StatusFigureTile(
          label: t("status.context.inputObserved"),
          value: Format.compactNumber(data.observedInputTokens, t),
          caption: t("status.context.acrossEvents", ["count": Format.exactNumber(Double(data.events.count), t)])
        )
        StatusFigureTile(
          label: t("status.context.reuseShare"),
          value: data.cacheReusePercent == nil
            ? t("status.context.notMeasured")
            : String(format: "%.1f", data.cacheReusePercent ?? 0) + "%",
          caption: t("status.context.reuseShareDesc")
        )
      }
      Text(telemetryNote(t))
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      EmptyStateView(
        systemImage: "brain",
        title: t("status.context.noTelemetry"),
        message: t("status.context.noTelemetryBody")
      )
    }
  }

  private func telemetryNote(_ t: Translator) -> String {
    var text = t("status.context.telemetryNote")
    if data.estimatedInputEvents > 0 {
      let key = data.estimatedInputEvents == 1 ? "status.context.estimatedOne" : "status.context.estimatedMany"
      text += " " + t(key, ["count": data.estimatedInputEvents])
    }
    return text
  }

  // MARK: Compaction

  private func rangeStats(_ stats: JSONValue?) -> JSONValue? {
    stats?["ranges"]?[range.rawValue]
  }

  private func compaction(_ t: Translator) -> some View {
    let stats = data.compactionStats
    let rangeValue = rangeStats(stats)
    let buckets = (rangeValue?["buckets"]?.items ?? []).map { $0.double ?? 0 }
    let hasBuckets = buckets.contains { $0 > 0 }
    return VStack(alignment: .leading, spacing: 10) {
      StatusSubsectionHeading(
        title: t("status.context.compactionTitle"),
        description: t("status.context.compactionDesc")
      ) {
        rangePicker(t)
      }
      if stats != nil && hasBuckets {
        StatusSavingsChart(
          buckets: buckets,
          range: range,
          savedTokens: rangeValue?["savedTokens"]?.double ?? 0,
          requests: rangeValue?["requests"]?.double ?? 0
        )
      } else {
        Text(emptyCompaction(stats, t))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, 4)
  }

  private func emptyCompaction(_ stats: JSONValue?, _ t: Translator) -> String {
    guard let stats else { return t("status.context.compactionEmpty") }
    var text = t("status.context.noCompactions")
    let requests = stats["requests"]?.double ?? 0
    if requests > 0 {
      text += " · " + t("status.context.recordedAllTime", ["count": Format.exactNumber(requests, t)])
    }
    return text + "."
  }

  private func rangePicker(_ t: Translator) -> some View {
    let binding = Binding<StatusSavingsRange>(
      get: { range },
      set: { next in
        range = next
        onRangeChosen()
      }
    )
    return Picker(selection: binding) {
      ForEach(StatusSavingsRange.allCases) { entry in
        Text(entry.label).tag(entry)
      }
    } label: {
      Text(t("status.context.compactionRangeAria"))
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 150)
    .accessibilityLabel(t("status.context.compactionRangeAria"))
  }
}

/// Per-model traffic with a filter and pagination (`st-model-panel`).
struct StatusModelsPanel: View {
  @EnvironmentObject private var model: AppModel
  let data: StatusData
  @Binding var query: String
  @Binding var limit: Int

  var body: some View {
    let t = model.t
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let filtered = data.allModelRows.filter { row in
      needle.isEmpty || "\(row.displayName ?? "") \(row.slug ?? "") \(row.providerName)".lowercased().contains(needle)
    }
    let visible = Array(filtered.prefix(limit))
    let peak = max(filtered.map { $0.totalTokens ?? 0 }.max() ?? 0, 1)
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: t("status.models.title"), description: t("status.models.description")) {
        if !data.allModelRows.isEmpty {
          SearchField(text: $query, placeholder: t("status.models.filter"))
        }
      }
      if data.providerUsagePending {
        PanelSkeleton(label: t("status.loading.modelUsage"), count: 6)
      } else if !visible.isEmpty {
        list(visible, peak: peak, t)
        pagination(visibleCount: visible.count, total: filtered.count, t)
      } else {
        EmptyStateView(
          systemImage: query.isEmpty ? "square.3.layers.3d" : "magnifyingglass",
          title: query.isEmpty ? t("status.models.noTraffic") : t("status.models.noMatch"),
          message: query.isEmpty ? t("status.models.noTrafficBody") : t("status.models.noMatchBody")
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panelStyle(padding: 16)
  }

  private func list(_ rows: [StatusModelUsage], peak: Double, _ t: Translator) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
        if entry.offset > 0 { Divider() }
        StatusModelRowView(usage: entry.element, peak: peak)
      }
    }
    .accessibilityLabel(t("status.models.aria"))
  }

  private func pagination(visibleCount: Int, total: Int, _ t: Translator) -> some View {
    HStack {
      Text(t("status.models.showing", [
        "shown": Format.exactNumber(Double(visibleCount), t),
        "total": Format.exactNumber(Double(total), t),
      ]))
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      Spacer()
      if visibleCount < total {
        Button(t("status.models.showMore")) { limit += statusModelPageSize }
          .buttonStyle(.borderless)
      } else if total > statusModelPageSize {
        Button(t("status.models.showFewer")) { limit = statusModelPageSize }
          .buttonStyle(.borderless)
      }
    }
  }
}

/// Upcoming quota resets (`st-reset-panel`).
struct StatusResetPanel: View {
  @EnvironmentObject private var model: AppModel
  let data: StatusData

  var body: some View {
    let t = model.t
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: t("status.quota.title"), description: t("status.quota.description"))
      if data.usagePending {
        PanelSkeleton(label: t("status.loading.quotaResets"), count: 3)
      } else if !data.resetRows.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(data.resetRows.prefix(10).enumerated()), id: \.element.id) { entry in
            if entry.offset > 0 { Divider() }
            StatusResetRowView(row: entry.element)
          }
        }
      } else {
        EmptyStateView(
          systemImage: "gauge.with.dots.needle.33percent",
          title: t("status.quota.empty"),
          message: t("status.quota.emptyBody")
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panelStyle(padding: 16)
  }
}

/// Observed generation speed (`st-speed-panel`).
struct StatusSpeedPanel: View {
  @EnvironmentObject private var model: AppModel
  let data: StatusData

  var body: some View {
    let t = model.t
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: t("status.speed.title"), description: t("status.speed.description"))
      if data.providerUsagePending {
        PanelSkeleton(label: t("status.loading.modelSpeed"), count: 3)
      } else if !data.speedRows.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(data.speedRows.prefix(12).enumerated()), id: \.element.id) { entry in
            if entry.offset > 0 { Divider() }
            StatusSpeedRowView(usage: entry.element)
          }
        }
      } else {
        EmptyStateView(
          systemImage: "timer",
          title: t("status.speed.empty"),
          message: t("status.speed.emptyBody")
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panelStyle(padding: 16)
  }
}

/// The most recent routed requests (`st-events-panel`).
struct StatusEventsPanel: View {
  @EnvironmentObject private var model: AppModel
  let data: StatusData

  var body: some View {
    let t = model.t
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: t("status.recent.title"), description: t("status.recent.description"))
      if data.snapshotPending {
        PanelSkeleton(label: t("status.loading.recentActivity"), count: 5)
      } else if !data.recentEvents.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(data.recentEvents.enumerated()), id: \.offset) { entry in
            if entry.offset > 0 { Divider() }
            StatusEventRow(event: entry.element)
          }
        }
      } else {
        EmptyStateView(
          systemImage: "server.rack",
          title: t("status.recent.empty"),
          message: t("status.recent.emptyBody")
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .panelStyle(padding: 16)
  }
}
