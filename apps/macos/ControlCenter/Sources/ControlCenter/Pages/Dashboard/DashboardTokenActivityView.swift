import ControlCenterCore
import SwiftUI

/// The year-long token heatmap (`TokenActivity`).
///
/// It reads only the values it is given, never the app model, and compares
/// them in `==`, so the once-a-second health poll that re-renders the page
/// does not rebuild 371 cells and their tooltips. Like the renderer's
/// `useMemo`, it recomputes when the events, the provider usage, or the
/// language change.
struct DashboardTokenActivityView: View, Equatable {
  private let events: [DashboardEvent]?
  private let providerUsage: JSONValue?
  private let refreshing: Bool
  private let loading: Bool
  private let t: Translator
  @State private var mode: DashboardActivityMode = .daily

  init(events: [DashboardEvent]?, providerUsage: JSONValue?, refreshing: Bool, loading: Bool, t: Translator) {
    self.events = events
    self.providerUsage = providerUsage
    self.refreshing = refreshing
    self.loading = loading
    self.t = t
  }

  static func == (lhs: DashboardTokenActivityView, rhs: DashboardTokenActivityView) -> Bool {
    lhs.t.language == rhs.t.language
      && lhs.refreshing == rhs.refreshing
      && lhs.loading == rhs.loading
      && lhs.providerUsage == rhs.providerUsage
      && lhs.events == rhs.events
  }

  var body: some View {
    let activity = DashboardStats.buildTokenActivity(
      events: events,
      providerUsage: providerUsage,
      now: DashboardTime.nowMillis(),
      t: t
    )
    let viewDays = DashboardStats.tokenActivityForMode(activity.days, mode: mode, t: t)
    let maximum = DashboardStats.tokenActivityMax(viewDays.map { $0.displayTokens })
    let total = activity.days.reduce(0.0) { $0 + $1.tokens }
    let activeDays = activity.days.filter { $0.tokens > 0 }.count

    VStack(alignment: .leading, spacing: 14) {
      heading(total: total)
      if loading {
        PanelSkeleton(label: t("dashboard.loading.activity"), count: 2)
      } else {
        DashboardActivityGrid(
          viewDays: viewDays,
          months: activity.months,
          today: activity.today,
          maximum: maximum,
          summary: t("dashboard.activity.gridAria", ["mode": t(mode.messageId)])
        )
        footer(activeDays: activeDays)
      }
    }
    .panelStyle(padding: 16)
  }

  private func heading(total: Double) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(t("dashboard.activity.title")).font(.system(size: 15, weight: .semibold))
        Text(description(total: total))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Picker(t("dashboard.activity.modeAria"), selection: $mode) {
        ForEach(DashboardActivityMode.allCases, id: \.self) { option in
          Text(t(option.messageId)).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 250)
      .accessibilityLabel(t("dashboard.activity.modeAria"))
    }
  }

  private func description(total: Double) -> String {
    if providerUsage.truthy {
      return t("dashboard.activity.lastYear", ["count": Format.exactNumber(total, t)])
    }
    if refreshing { return t("dashboard.activity.reading") }
    if events != nil { return t("dashboard.activity.eventsOnly") }
    return t("dashboard.activity.pending")
  }

  private func footer(activeDays: Int) -> some View {
    let activeText: String
    if activeDays > 0 {
      activeText = t(
        activeDays == 1 ? "dashboard.activity.activeDay" : "dashboard.activity.activeDays",
        ["count": Format.exactNumber(Double(activeDays), t)]
      )
    } else {
      activeText = t("dashboard.activity.noActivity")
    }
    return HStack(spacing: 8) {
      Text(activeText)
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        Text(t("dashboard.activity.less"))
        ForEach(0..<5, id: \.self) { level in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(DashboardActivityGrid.levelColor(level))
            .frame(width: 10, height: 10)
        }
        Text(t("dashboard.activity.more"))
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(t("dashboard.activity.scaleAria"))
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }
}

/// The week-per-column grid with month labels underneath.
private struct DashboardActivityGrid: View {
  let viewDays: [DashboardActivityViewDay]
  let months: [DashboardActivityMonth]
  let today: Double
  let maximum: Double
  let summary: String

  private var weeks: Int { DashboardStats.tokenActivityWeeks }
  private var gap: CGFloat { 2 }
  private var minimumCell: CGFloat { 9 }

  static func levelColor(_ level: Int) -> Color {
    switch level {
    case 1: return Palette.accent.opacity(0.28)
    case 2: return Palette.accent.opacity(0.5)
    case 3: return Palette.accent.opacity(0.75)
    case 4: return Palette.accent
    default: return Color.secondary.opacity(0.14)
    }
  }

  var body: some View {
    let minimumWidth = CGFloat(weeks) * minimumCell + CGFloat(weeks - 1) * gap
    // Below the minimum cell size the calendar scrolls instead of shrinking
    // (`.db-token-calendar-scroll`).
    ViewThatFits(in: .horizontal) {
      calendar.frame(minWidth: minimumWidth)
      ScrollView(.horizontal, showsIndicators: true) {
        calendar.frame(width: minimumWidth)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(summary)
  }

  private var calendar: some View {
    let labels = Dictionary(months.map { ($0.weekIndex, $0.label) }, uniquingKeysWith: { first, _ in first })
    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: gap) {
        ForEach(0..<weeks, id: \.self) { week in
          VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { day in
              cell(week * 7 + day)
            }
          }
        }
      }
      HStack(spacing: gap) {
        ForEach(0..<weeks, id: \.self) { week in
          Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .overlay(alignment: .leading) {
              if let label = labels[week] {
                Text(label)
                  .font(.system(size: 9.5))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .fixedSize()
              }
            }
        }
      }
      .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func cell(_ index: Int) -> some View {
    if index < viewDays.count {
      let item = viewDays[index]
      let level = DashboardStats.levelForTokenActivity(item.displayTokens, max: maximum)
      let isFuture = item.day.millis > today
      let square = RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(Self.levelColor(level))
        .aspectRatio(1, contentMode: .fit)
        .opacity(isFuture ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.tooltip)
      if isFuture {
        square
      } else {
        square.help(item.tooltip)
      }
    } else {
      Color.clear.aspectRatio(1, contentMode: .fit)
    }
  }
}
