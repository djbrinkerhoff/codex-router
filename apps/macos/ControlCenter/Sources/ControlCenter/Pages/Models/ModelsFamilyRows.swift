import ControlCenterCore
import SwiftUI

// The model list: one row per model family, expanding to the provider routes
// that can serve it. Ports `ModelFamilyRow`, `ModelDetails`, `ModelRouteRow`,
// and `PendingModelRows`.

/// One family with its derived state, computed by the page from the current
/// (optimistic) picker values.
struct ModelsFamilyRowData: Identifiable {
  let family: ModelsFamily
  let usable: [ModelsRoute]
  let inPicker: [ModelsRoute]
  let on: Bool

  var id: String { family.id }
}

/// Reads a row needs from the page.
struct ModelsRowValues {
  let providerNames: [String: String]
  let isConnecting: (String) -> Bool
  let pickerValue: (ModelsRoute) -> Bool
  let subagentValue: (ModelsRoute) -> Bool
  let effortValue: (ModelsRoute) -> String
}

/// Writes a row can request from the page.
struct ModelsRowActions {
  let toggleExpanded: () -> Void
  let familyPicker: (Bool) -> Void
  let routePicker: (ModelsRoute, Bool) -> Void
  let subagent: (ModelsRoute, Bool) -> Void
  let effort: (ModelsRoute, String) -> Void
  let connect: (String) -> Void
  let removeLocal: (ModelsRoute) -> Void
}

private enum ModelsColumn {
  static let context: CGFloat = 78
  static let input: CGFloat = 96
  static let picker: CGFloat = 64
  static let subagent: CGFloat = 96
  static let effort: CGFloat = 118
  static let remove: CGFloat = 28
}

struct ModelsFamilyRow: View {
  @EnvironmentObject private var model: AppModel
  let row: ModelsFamilyRowData
  let expanded: Bool
  let values: ModelsRowValues
  let actions: ModelsRowActions

  private var providerIds: [String] {
    var seen = Set<String>()
    return row.family.routes.map { $0.provider }.filter { seen.insert($0).inserted }
  }

  private func providerName(_ providerId: String) -> String {
    ModelsLogic.nonEmpty(
      values.providerNames[providerId] ?? "",
      or: ModelsLogic.providerDisplayName(providerId, model.t)
    )
  }

  var body: some View {
    let preferred = ModelsLogic.preferredRoute(row.family)
    VStack(alignment: .leading, spacing: 0) {
      summary(preferred)
      if expanded {
        panel
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .opacity(row.usable.isEmpty ? 0.86 : 1)
  }

  // MARK: Summary line

  private func maker(_ preferred: ModelsRoute?) -> ProviderBrand {
    guard let preferred else { return ProviderBranding.forProvider("") }
    return ProviderBranding.forModel(
      provider: preferred.provider,
      slug: preferred.slug,
      displayName: preferred.displayName,
      gatewayModel: preferred.gatewayModel
    )
  }

  /// One muted line under the name instead of a row of columns. Reading left
  /// to right beats hunting the same fact in four different x-positions.
  private func facts(_ preferred: ModelsRoute?, _ brand: ProviderBrand) -> String {
    let t = model.t
    var result: [String] = []
    if providerIds.count > 1 {
      result.append(t("models.fact.providers", ["count": providerIds.count]))
    } else {
      let name = values.providerNames[providerIds.first ?? ""] ?? ""
      result.append(name.isEmpty ? brand.name : name)
    }
    if let context = preferred?.contextWindow, context != 0 {
      result.append(Format.context(context, t))
    }
    let hasImage = row.family.routes.contains(where: { $0.inputModalities.contains("image") })
    result.append(hasImage ? t("models.fact.textImage") : t("models.fact.text"))
    if row.family.routes.contains(where: { $0.isFree }) { result.append(t("models.fact.free")) }
    if row.family.routes.count > 1 {
      result.append(t("models.fact.routes", ["count": row.family.routes.count]))
    }
    return result.joined(separator: " · ")
  }

  private func summary(_ preferred: ModelsRoute?) -> some View {
    let brand = maker(preferred)
    return HStack(spacing: 10) {
      // The disclosure sits at the far left, where a caret means "open this".
      Button(action: actions.toggleExpanded) {
        HStack(spacing: 10) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12)
          BrandLogo(brand: brand, size: 28)
          VStack(alignment: .leading, spacing: 2) {
            Text(row.family.displayName)
              .font(.system(size: 13.5, weight: .semibold))
              .lineLimit(1)
            Text(facts(preferred, brand))
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(.isButton)
      action
    }
  }

  @ViewBuilder private var action: some View {
    let blocked = row.usable.isEmpty
    let connecting = providerIds.contains(where: { values.isConnecting($0) })
    let managedByClient = !row.usable.isEmpty && row.usable.allSatisfy { ModelsLogic.nativeClientManaged($0) }
    if blocked && connecting {
      ModelsConnectingSlot()
    } else if blocked {
      Button {
        actions.connect(providerIds.first ?? "")
      } label: {
        Text(
          providerIds.count > 1
            ? model.t("models.family.connectProvider")
            : model.t("models.family.connectName", ["name": providerName(providerIds.first ?? "")])
        )
      }
    } else {
      HStack(spacing: 8) {
        Text(row.on ? model.t("models.status.on") : model.t("models.status.off"))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        ModelsSwitch(
          checked: row.on,
          disabled: managedByClient,
          label: managedByClient
            ? model.t("models.family.managedByCodex", ["name": row.family.displayName])
            : model.t("models.family.useInCodex", ["name": row.family.displayName]),
          onChange: actions.familyPicker
        )
      }
    }
  }

  // MARK: Expanded panel

  @ViewBuilder private var panel: some View {
    let routes = row.family.routes
    if routes.count > 1 {
      VStack(alignment: .leading, spacing: 10) {
        Text(model.t("models.family.multiRouteNote"))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        routeTable(routes)
      }
      .padding(.top, 10)
      .padding(.leading, 22)
    } else if let route = routes.first {
      // A single-route model already showed its name and provider in the row
      // above, so the panel carries only what the summary had to leave out.
      ModelsDetails(
        route: route,
        providerName: providerName(route.provider),
        selected: values.subagentValue(route),
        effort: values.effortValue(route),
        onSubagent: { actions.subagent(route, $0) },
        onEffort: { actions.effort(route, $0) },
        onRemove: { actions.removeLocal(route) }
      )
      .padding(.top, 10)
      .padding(.leading, 22)
    }
  }

  private func routeTable(_ routes: [ModelsRoute]) -> some View {
    // The actions column exists only for a family that actually has a locally
    // curated route.
    let removable = routes.contains(where: { $0.local })
    return VStack(alignment: .leading, spacing: 6) {
      routeHeader(removable)
      Divider()
      ForEach(Array(routes.enumerated()), id: \.offset) { item in
        ModelsRouteRow(
          route: item.element,
          providerName: providerName(item.element.provider),
          showRemoveColumn: removable,
          connecting: values.isConnecting(item.element.provider),
          pickerVisible: values.pickerValue(item.element),
          selectedInSettings: values.subagentValue(item.element),
          effort: values.effortValue(item.element),
          onPicker: { actions.routePicker(item.element, $0) },
          onSubagent: { actions.subagent(item.element, $0) },
          onEffort: { actions.effort(item.element, $0) },
          onConnect: { actions.connect(item.element.provider) },
          onRemove: { actions.removeLocal(item.element) }
        )
      }
    }
    .accessibilityLabel(model.t("models.family.routesAria", ["name": row.family.displayName]))
  }

  /// One header for one shared set of columns, instead of labelling every row.
  private func routeHeader(_ removable: Bool) -> some View {
    HStack(spacing: 10) {
      Text(model.t("models.route.account")).frame(maxWidth: .infinity, alignment: .leading)
      Text(model.t("models.route.context")).frame(width: ModelsColumn.context, alignment: .leading)
      Text(model.t("models.route.input")).frame(width: ModelsColumn.input, alignment: .leading)
      Text(model.t("models.route.inPicker")).frame(width: ModelsColumn.picker, alignment: .leading)
      Text(model.t("models.route.subagents")).frame(width: ModelsColumn.subagent, alignment: .leading)
      Text(model.t("models.route.thinking")).frame(width: ModelsColumn.effort, alignment: .leading)
      if removable { Spacer().frame(width: ModelsColumn.remove) }
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .accessibilityHidden(true)
  }
}

// MARK: - Route row

private struct ModelsRouteIdentity: View {
  @EnvironmentObject private var model: AppModel
  let route: ModelsRoute
  let providerName: String

  var body: some View {
    HStack(spacing: 8) {
      ProviderLogo(providerId: route.provider, displayName: providerName, size: 22)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(providerName)
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
          if route.isFree { Badge(model.t("models.fact.free"), tone: .success) }
          // Says why this one route can be deleted when its neighbours cannot:
          // the operator curated it locally, so nothing this checkout ships is
          // at stake.
          if route.local { Badge(model.t("models.fact.local"), tone: .accent) }
        }
        Text(route.slug)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(route.slug)
      }
    }
  }
}

struct ModelsRouteRow: View {
  @EnvironmentObject private var model: AppModel
  let route: ModelsRoute
  let providerName: String
  let showRemoveColumn: Bool
  let connecting: Bool
  let pickerVisible: Bool
  let selectedInSettings: Bool
  let effort: String
  let onPicker: (Bool) -> Void
  let onSubagent: (Bool) -> Void
  let onEffort: (String) -> Void
  let onConnect: () -> Void
  let onRemove: () -> Void

  private var context: String {
    if let window = route.contextWindow, window != 0 { return Format.context(window, model.t) }
    return "—"
  }

  private var input: String {
    route.inputModalities.contains("image") ? model.t("models.fact.textImage") : model.t("models.fact.text")
  }

  var body: some View {
    if !ModelsLogic.routeUsable(route) {
      unavailableRow
    } else {
      usableRow
    }
  }

  private var unavailableRow: some View {
    HStack(spacing: 10) {
      ModelsRouteIdentity(route: route, providerName: providerName)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(context).font(.system(size: 12)).frame(width: ModelsColumn.context, alignment: .leading)
      Text(input).font(.system(size: 12)).frame(width: ModelsColumn.input, alignment: .leading)
      // The same slot the switches occupy, so the right edge answers one
      // question all the way down: what can I do with this route.
      if connecting {
        ModelsConnectingSlot()
      } else {
        Button(action: onConnect) {
          Text(model.t("models.family.connectName", ["name": providerName]))
        }
      }
    }
  }

  private var usableRow: some View {
    let managed = ModelsLogic.nativeClientManaged(route)
    return HStack(spacing: 10) {
      ModelsRouteIdentity(route: route, providerName: providerName)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(context).font(.system(size: 12)).frame(width: ModelsColumn.context, alignment: .leading)
      Text(input).font(.system(size: 12)).frame(width: ModelsColumn.input, alignment: .leading)
      ModelsSwitch(
        checked: pickerVisible,
        disabled: managed,
        label: managed
          ? model.t("models.family.managedByCodex", ["name": route.displayName])
          : model.t("models.route.pickerLabel", ["model": route.displayName, "provider": providerName]),
        onChange: onPicker
      )
      .frame(width: ModelsColumn.picker, alignment: .leading)
      ModelsSubagentToggle(
        route: route,
        providerName: providerName,
        selected: selectedInSettings,
        onChange: onSubagent
      )
      .frame(width: ModelsColumn.subagent, alignment: .leading)
      ModelsEffortMenu(
        route: route,
        providerName: providerName,
        selected: selectedInSettings,
        effort: effort,
        onChange: onEffort
      )
      .frame(width: ModelsColumn.effort, alignment: .leading)
      if showRemoveColumn {
        Group {
          if route.local {
            IconButton(
              systemImage: "trash",
              label: model.t("models.local.removeAction", ["model": route.displayName, "provider": providerName]),
              action: onRemove
            )
          } else {
            Color.clear
          }
        }
        .frame(width: ModelsColumn.remove)
      }
    }
  }
}

// MARK: - Single-route details

private struct ModelsDetailLine<Content: View>: View {
  let label: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 96, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
  }
}

struct ModelsDetails: View {
  @EnvironmentObject private var model: AppModel
  let route: ModelsRoute
  let providerName: String
  let selected: Bool
  let effort: String
  let onSubagent: (Bool) -> Void
  let onEffort: (String) -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ModelsDetailLine(label: model.t("models.details.modelId")) {
        Text(route.slug)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
      }
      ModelsDetailLine(label: model.t("models.details.route")) {
        Text("\(providerName) · \(ModelsLogic.routeKind(route))")
          .font(.system(size: 12))
      }
      if ModelsLogic.routeUsable(route) {
        ModelsDetailLine(label: model.t("models.details.subagents")) {
          HStack(spacing: 14) {
            ModelsSubagentToggle(route: route, providerName: providerName, selected: selected, onChange: onSubagent)
            ModelsEffortMenu(
              route: route,
              providerName: providerName,
              selected: selected,
              effort: effort,
              onChange: onEffort
            )
          }
        }
      } else {
        ModelsDetailLine(label: model.t("models.details.status")) {
          Text(model.t("models.details.connectToUse", ["name": providerName]))
            .font(.system(size: 12))
        }
      }
      // A single-route family never renders the route table, so without this
      // the only locally curated models that could be deleted would be the
      // ones that happen to share a name with other routes.
      if route.local {
        ModelsDetailLine(label: model.t("models.details.curation")) {
          Button(role: .destructive, action: onRemove) {
            Label(model.t("models.local.remove"), systemImage: "trash")
          }
        }
      }
    }
  }
}

// MARK: - Pending rows

/// Placeholder rows for models being published to the picker. They carry the
/// slug rather than a bare shimmer: the operator picked those names a moment
/// ago, and seeing them is what says the click landed on the right ones.
struct ModelsPendingRows: View {
  @EnvironmentObject private var model: AppModel
  let slugs: [String]

  var body: some View {
    ForEach(Array(slugs.enumerated()), id: \.offset) { item in
      HStack(spacing: 10) {
        SkeletonBlock(height: 28, width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.element)
            .font(.system(size: 13.5, weight: .semibold))
            .lineLimit(1)
          Text(model.t("models.pending.adding"))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        SkeletonBlock(height: 20, width: 44)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .accessibilityElement(children: .combine)
    }
  }
}
