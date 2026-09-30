import ControlCenterCore
import SwiftUI

/// The provider-route switches (`RouteDashboardPanel`). Each switch responds
/// at once through `OptimisticValues` and settles to the router's answer; the
/// write itself is `setProviderEnabled` through the shared action runner, so
/// it gets the same operation indicator, toast, and refresh as every other
/// action.
struct DashboardRoutesPanel: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject private var routeMutations: OptimisticValues<Bool>
  private let providers: [JSONValue]
  private let loading: Bool

  init(providers: [JSONValue], routeMutations: OptimisticValues<Bool>, loading: Bool) {
    self.providers = providers
    self.routeMutations = routeMutations
    self.loading = loading
  }

  /// `kind !== "per-model"`: those routes are managed with their models.
  private var visible: [JSONValue] {
    providers.filter { $0["kind"]?.string != "per-model" }
  }

  var body: some View {
    let t = model.t
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: t("dashboard.routes.title"),
        description: t("dashboard.routes.description"),
        action: {
          Button(t("dashboard.routes.manage")) {
            model.navigate(.models)
          }
        }
      )
      content(visible: visible, t: t)
    }
    .panelStyle(padding: 16)
  }

  @ViewBuilder
  private func content(visible: [JSONValue], t: Translator) -> some View {
    if loading {
      PanelSkeleton(label: t("dashboard.loading.routes"), count: 3)
    } else if visible.isEmpty {
      EmptyStateView(
        title: t("dashboard.routes.empty"),
        message: t("dashboard.routes.emptyBody")
      )
    } else {
      VStack(spacing: 0) {
        ForEach(Array(visible.enumerated()), id: \.offset) { index, provider in
          if index > 0 { Divider() }
          routeRow(provider, t: t)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(t("dashboard.routes.aria"))
    }
  }

  private func routeRow(_ provider: JSONValue, t: Translator) -> some View {
    let id = provider["id"]?.string ?? ""
    let displayName = provider["displayName"]?.string ?? ""
    let enabled = routeMutations.value(id, fallback: provider["enabled"]?.bool ?? false)
    let verb = enabled ? t("dashboard.routes.disable") : t("dashboard.routes.enable")
    return HStack(spacing: 12) {
      ProviderLogo(providerId: id, displayName: displayName, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        Text(enabled ? t("dashboard.routes.enabled") : t("dashboard.routes.disabled"))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Badge(
        enabled ? t("dashboard.routes.enabledBadge") : t("dashboard.routes.disabledBadge"),
        tone: enabled ? .success : .neutral
      )
      toggleButton(enabled: enabled, title: verb) {
        let next = !enabled
        let label = "\(next ? t("dashboard.routes.enable") : t("dashboard.routes.disable")) \(displayName)"
        routeMutations.mutate(id, to: next, label: label, model: model) { api in
          try await api.setProviderEnabled(id, next)
        }
      }
      .accessibilityLabel("\(verb) \(displayName)")
    }
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private func toggleButton(enabled: Bool, title: String, action: @escaping () -> Void) -> some View {
    if enabled {
      Button(title, action: action).buttonStyle(.bordered)
    } else {
      Button(title, action: action).buttonStyle(.borderedProminent)
    }
  }
}
