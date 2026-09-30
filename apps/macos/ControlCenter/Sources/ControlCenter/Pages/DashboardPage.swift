import ControlCenterCore
import SwiftUI

/// The router at a glance, ported from `DashboardPage.tsx`: five headline
/// tiles, traffic and token-activity charts, the provider and model mix,
/// recent requests, provider-route switches, and the service-health strip.
///
/// Every figure is derived by `DashboardContext` from the router's own
/// snapshots (see `Pages/Dashboard/`); the only router write this page makes
/// is `setProviderEnabled`, through `OptimisticValues` and `AppModel`.
struct DashboardPage: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var routeMutations = OptimisticValues<Bool>()
  @State private var trafficRange: DashboardRange = .hours24

  var body: some View {
    let ctx = makeContext()
    VStack(alignment: .leading, spacing: 16) {
      PageHeader(
        eyebrow: ctx.t("dashboard.eyebrow"),
        title: ctx.t("dashboard.title"),
        description: ctx.t("dashboard.description"),
        onRefresh: { Task { await model.refreshAll() } }
      )
      notice(ctx)
      DashboardSummaryTiles(tiles: ctx.tiles(), t: ctx.t) { destination in
        model.navigate(destination)
      }
      trafficPanel(ctx)
      DashboardTokenActivityView(
        events: ctx.events,
        providerUsage: ctx.providerUsage,
        refreshing: ctx.refreshing,
        loading: ctx.snapshotPending && ctx.providerUsage == nil,
        t: ctx.t
      )
      .equatable()
      mixPanel(ctx)
      recentPanel(ctx)
      DashboardRoutesPanel(providers: ctx.routeProviders, routeMutations: routeMutations, loading: ctx.routesPending)
      healthSection(ctx)
    }
    // An optimistic switch settles when the router's answer catches up to it,
    // and again when an action finishes and its refresh has landed.
    .onChange(of: DashboardPage.authoritativeRoutes(ctx.routeProviders)) { authoritative in
      routeMutations.reconcile(with: authoritative)
    }
    .onChange(of: model.operation) { _ in
      routeMutations.reconcile(with: DashboardPage.authoritativeRoutes(currentRouteProviders()))
    }
  }

  // MARK: Inputs

  private func makeContext() -> DashboardContext {
    DashboardContext(
      t: model.t,
      now: DashboardTime.nowMillis(),
      refreshing: model.refreshing,
      ready: DashboardReadiness(
        snapshot: model.isReady(.snapshot),
        health: model.isReady(.health),
        accountUsage: model.isReady(.accountUsage),
        providerUsage: model.isReady(.providerUsage)
      ),
      health: model.health,
      account: model.accountUsage,
      providerUsage: model.providerUsage,
      target: model.target,
      dashboard: model.snapshot?["catalog"]?["dashboard"]
    )
  }

  private func currentRouteProviders() -> [JSONValue] {
    model.snapshot?["catalog"]?["dashboard"]?["providers"]?.items ?? []
  }

  /// The router's own enabled flag per provider route.
  private static func authoritativeRoutes(_ providers: [JSONValue]) -> [String: Bool] {
    var routes: [String: Bool] = [:]
    for provider in providers {
      if let id = provider["id"]?.string {
        routes[id] = provider["enabled"]?.bool ?? false
      }
    }
    return routes
  }

  // MARK: Notice

  @ViewBuilder
  private func notice(_ ctx: DashboardContext) -> some View {
    // The Electron page also warned when its desktop bridge was missing. The
    // native window owns its bridge, so that state cannot occur here.
    if let message = ctx.healthErrorMessage {
      InlineNotice(tone: .danger, title: ctx.t("dashboard.healthFailed.title"), message: message)
    }
  }

  // MARK: Traffic

  @ViewBuilder
  private func trafficPanel(_ ctx: DashboardContext) -> some View {
    let t = ctx.t
    let range = trafficRange
    // The provider snapshot gives accurate rolling totals, while the bounded
    // event stream gives the dashboard an honest hourly shape.
    let buckets = DashboardStats.buildTrafficBuckets(
      events: ctx.events,
      providerUsage: ctx.providerUsage,
      hours: ctx.eventHours,
      range: range,
      now: ctx.now,
      t: t
    )
    let hasRequests = buckets.contains { $0.requests > 0 }
    let hasTokens = buckets.contains { $0.measuredTokens }
    let rangeLabel = DashboardStats.trafficRangeLabel(range, t)

    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: t("dashboard.traffic.title", ["range": rangeLabel]),
        description: DashboardStats.trafficDescription(range, t),
        action: {
          HStack(spacing: 8) {
            DashboardRangePicker(value: $trafficRange, label: t("dashboard.rangeAria"))
            Button {
              model.navigate(.usage)
            } label: {
              Label(t("dashboard.usage"), systemImage: "chart.bar")
            }
            .buttonStyle(.borderless)
            .help(t("dashboard.openUsage"))
            .accessibilityLabel(t("dashboard.openUsage"))
          }
        }
      )
      if ctx.snapshotPending {
        PanelSkeleton(label: t("dashboard.loading.traffic"), count: 4)
      } else if ctx.events == nil {
        EmptyStateView(
          systemImage: "chart.bar",
          title: ctx.refreshing ? t("dashboard.traffic.reading") : t("dashboard.traffic.unavailable"),
          message: t("dashboard.traffic.emptyBody")
        )
      } else if hasRequests {
        DashboardTrafficTrend(buckets: buckets, hasTokens: hasTokens, range: range, t: t)
      } else {
        EmptyStateView(
          systemImage: "chart.bar",
          title: t("dashboard.traffic.noRequests", ["range": rangeLabel]),
          message: t("dashboard.traffic.chartFill")
        )
      }
      if ctx.events != nil {
        Text(trafficNote(ctx, buckets: buckets, range: range, hasRequests: hasRequests, hasTokens: hasTokens))
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .panelStyle(padding: 16)
  }

  private func trafficNote(
    _ ctx: DashboardContext,
    buckets: [DashboardTrafficBucket],
    range: DashboardRange,
    hasRequests: Bool,
    hasTokens: Bool
  ) -> String {
    let t = ctx.t
    let rangeLabel = DashboardStats.trafficRangeLabel(range, t)
    let totalTokens = buckets.reduce(0.0) { $0 + $1.tokens }
    let totalRequests = buckets.reduce(0.0) { $0 + $1.requests }
    if hasTokens {
      let measured = t("dashboard.traffic.measured", [
        "tokens": Format.exactNumber(totalTokens, t),
        "requests": Format.exactNumber(totalRequests, t),
        "range": rangeLabel,
      ])
      let source: String
      if range == .hours24 {
        let hasRollup = !(ctx.eventHours ?? []).isEmpty
        source = hasRollup ? t("dashboard.traffic.hourlyRollup") : t("dashboard.traffic.hourlyEvents")
      } else {
        source = t("dashboard.traffic.dailyLedger")
      }
      return "\(measured) \(source)"
    }
    if hasRequests {
      return t("dashboard.traffic.requestsObserved", [
        "requests": Format.exactNumber(totalRequests, t),
        "range": rangeLabel,
      ])
    }
    return t("dashboard.traffic.emptyWindow", ["range": rangeLabel])
  }

  // MARK: Provider and model mix

  @ViewBuilder
  private func mixPanel(_ ctx: DashboardContext) -> some View {
    let t = ctx.t
    let hasUsage = ctx.providerUsage != nil
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: t("dashboard.mix.title"),
        description: hasUsage ? t("dashboard.mix.description") : t("dashboard.mix.pending"),
        action: {
          Button {
            model.navigate(.status)
          } label: {
            Label(t("dashboard.details"), systemImage: "waveform.path.ecg")
          }
          .buttonStyle(.borderless)
          .help(t("dashboard.openStatus"))
          .accessibilityLabel(t("dashboard.openStatus"))
        }
      )
      if ctx.providerUsagePending {
        PanelSkeleton(label: t("dashboard.loading.mix"), count: 4)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 320), spacing: 28, alignment: .top)],
          alignment: .leading,
          spacing: 20
        ) {
          DashboardBreakdownGroup(
            title: t("dashboard.mix.providers"),
            rows: ctx.providerBreakdown,
            providerRows: true,
            emptyTitle: hasUsage
              ? t("dashboard.mix.noProviderTraffic")
              : (ctx.refreshing ? t("dashboard.mix.readingProviders") : t("dashboard.mix.providerUnavailable")),
            emptyBody: hasUsage ? t("dashboard.mix.providerEmpty") : t("dashboard.mix.providerEmptyPending"),
            t: t
          )
          DashboardBreakdownGroup(
            title: DashboardStats.modelBreakdownScopeTitle(ctx.modelBreakdown, t),
            rows: ctx.modelBreakdown,
            emptyTitle: ctx.events == nil && ctx.providerUsage == nil
              ? t("dashboard.mix.noModelUsage")
              : t("dashboard.mix.noModelTraffic"),
            emptyBody: ctx.modelBreakdown.isEmpty ? t("dashboard.mix.modelEmpty") : "",
            t: t
          )
        }
      }
    }
    .panelStyle(padding: 16)
  }

  // MARK: Recent activity

  @ViewBuilder
  private func recentPanel(_ ctx: DashboardContext) -> some View {
    let t = ctx.t
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: t("dashboard.recent.title"),
        description: t("dashboard.recent.description"),
        action: {
          Button {
            model.navigate(.status)
          } label: {
            Label(t("dashboard.status"), systemImage: "waveform.path.ecg")
          }
          .buttonStyle(.borderless)
          .help(t("dashboard.openStatus"))
          .accessibilityLabel(t("dashboard.openStatus"))
        }
      )
      if ctx.snapshotPending {
        PanelSkeleton(label: t("dashboard.loading.recent"), count: 5)
      } else if !ctx.recentEvents.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(ctx.recentEvents.enumerated()), id: \.offset) { index, event in
            if index > 0 { Divider() }
            DashboardEventRow(event: event, t: t)
          }
        }
      } else {
        EmptyStateView(
          systemImage: "server.rack",
          title: ctx.events != nil
            ? t("dashboard.recent.noTraffic")
            : (ctx.refreshing ? t("dashboard.traffic.reading") : t("dashboard.traffic.unavailable")),
          message: ctx.events != nil ? t("dashboard.recent.fill") : t("dashboard.recent.pending")
        )
      }
    }
    .panelStyle(padding: 16)
  }

  // MARK: Service health

  @ViewBuilder
  private func healthSection(_ ctx: DashboardContext) -> some View {
    if ctx.healthPending {
      SkeletonBlock(height: 78)
    } else {
      DashboardServiceHealthPanel(
        health: ctx.health,
        compact: true,
        onOpen: { model.navigate(.status) }
      )
    }
  }
}
