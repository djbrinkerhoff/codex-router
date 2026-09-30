import ControlCenterCore
import SwiftUI

/// The Status page, ported from `StatusPage.tsx`: router health, live
/// requests, context reuse, per-model traffic, quota resets, model speed and
/// recent activity. Its data model lives in `Status/StatusData.swift`.
@MainActor
struct StatusPage: View {
  @EnvironmentObject private var model: AppModel
  @State private var modelQuery = ""
  @State private var modelLimit = statusModelPageSize
  @State private var repairing = false
  @State private var savingsRange: StatusSavingsRange = .day
  @State private var savingsRangeChosen = false

  var body: some View {
    let t = model.t
    let data = StatusLogic.build(
      t,
      target: model.target,
      health: model.health,
      account: model.accountUsage,
      providerUsage: model.providerUsage,
      refreshing: model.refreshing,
      ready: { model.isReady($0) }
    )
    let requestSignature = StatusSavingsRange.allCases.map { requestCount(data, $0) }
    return VStack(alignment: .leading, spacing: 20) {
      PageHeader(
        eyebrow: t("status.eyebrow"),
        title: t("status.title"),
        description: t("status.description"),
        onRefresh: { Task { await model.refreshAll() } }
      )
      StatusSummaryGrid(items: data.summary)
      healthSection(data, t)
      primaryGrid(data)
      StatusModelsPanel(data: data, query: $modelQuery, limit: $modelLimit)
      secondaryGrid(data)
      StatusEventsPanel(data: data)
    }
    .onAppear { applyAutoRange(data) }
    .onChange(of: requestSignature) { _ in applyAutoRange(data) }
    .onChange(of: savingsRange) { _ in applyAutoRange(data) }
    .onChange(of: savingsRangeChosen) { _ in applyAutoRange(data) }
    .onChange(of: modelQuery) { _ in modelLimit = statusModelPageSize }
  }

  // MARK: Sections

  @ViewBuilder
  private func healthSection(_ data: StatusData, _ t: Translator) -> some View {
    if data.healthPending {
      PanelSkeleton(label: t("status.loading.serviceHealth"), count: 2)
        .panelStyle(padding: 16)
    } else {
      StatusServiceHealthPanel(
        health: model.health,
        t: t,
        repairing: repairing,
        onRepair: { repair() }
      )
    }
  }

  private func primaryGrid(_ data: StatusData) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        StatusLivePanel(data: data, health: model.health)
          .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
        contextPanel(data)
          .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
      }
      VStack(alignment: .leading, spacing: 16) {
        StatusLivePanel(data: data, health: model.health)
        contextPanel(data)
      }
    }
  }

  private func contextPanel(_ data: StatusData) -> some View {
    StatusContextPanel(data: data, range: $savingsRange, onRangeChosen: { savingsRangeChosen = true })
  }

  private func secondaryGrid(_ data: StatusData) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        StatusResetPanel(data: data).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        StatusSpeedPanel(data: data).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
      }
      VStack(alignment: .leading, spacing: 16) {
        StatusResetPanel(data: data)
        StatusSpeedPanel(data: data)
      }
    }
  }

  // MARK: Compaction range

  private func requestCount(_ data: StatusData, _ range: StatusSavingsRange) -> Double {
    data.compactionStats?["ranges"]?[range.rawValue]?["requests"]?.double ?? 0
  }

  /// The snapshot arrives after the first render, so the initial range cannot
  /// be chosen up front. Prefer 24H when it has data, otherwise reveal the
  /// nearest useful history; an explicit operator selection is never
  /// overwritten.
  private func applyAutoRange(_ data: StatusData) {
    guard !savingsRangeChosen, let ranges = data.compactionStats?["ranges"], ranges.object != nil else { return }
    if requestCount(data, savingsRange) > 0 { return }
    if let populated = StatusSavingsRange.allCases.first(where: { requestCount(data, $0) > 0 }) {
      savingsRange = populated
    }
  }

  // MARK: Repair

  /// The same repair Settings runs, reached from the panel where a stopped
  /// service first becomes visible. The toast plus the refreshed health rows
  /// are the whole answer, so this page keeps no report surface of its own.
  private func repair() {
    guard !repairing else { return }
    repairing = true
    let api = model.api
    let t = model.t
    Task { @MainActor in
      await model.runAction(t("status.repair")) {
        let report = try await api.repairInstall()
        if !report["ok"].truthy {
          let failed = report["checks"]?.items.first(where: { $0["status"]?.string == "fail" })
          if let failed {
            let name = failed["name"]?.string ?? ""
            let detail = UsageLogic.nonEmpty(failed["detail"]?.string) ?? t("status.repair.checkFailed")
            throw ControlCenterError("\(name): \(detail)")
          }
          throw ControlCenterError(t("status.repair.failingChecks"))
        }
        return report
      }
      repairing = false
    }
  }
}
