import ControlCenterCore
import SwiftUI

// Small controls shared by the Models page's rows, menus, and dialogs.

/// A `Toggle` styled as a switch whose value the caller owns. The caller
/// usually reads it from an `OptimisticValues`, so the switch answers a click
/// at once and settles to the router's answer.
struct ModelsSwitch: View {
  let checked: Bool
  var disabled = false
  let label: String
  let onChange: (Bool) -> Void

  var body: some View {
    Toggle(label, isOn: Binding(get: { checked }, set: { onChange($0) }))
      .toggleStyle(.switch)
      .labelsHidden()
      .controlSize(.small)
      .disabled(disabled)
      .help(label)
  }
}

/// What stands in the action slot of a row whose provider is mid-connection.
/// It names what is happening and leaves a blank exactly where the control
/// that does not exist yet will go, so the wait reads as the switch being
/// prepared rather than as a button that stopped working.
struct ModelsConnectingSlot: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(model.t("models.connection.connecting"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      SkeletonBlock(height: 20, width: 44)
    }
    .accessibilityElement(children: .combine)
  }
}

/// An icon and one sentence on a tinted surface: the dialogs' warning rows.
struct ModelsNoteRow: View {
  let systemImage: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08)))
  }
}

/// The title, description, and padding every dialog shares.
struct ModelsDialogFrame<Content: View>: View {
  let title: String
  var description: String?
  var width: CGFloat = 460
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 15, weight: .semibold))
        if let description, !description.isEmpty {
          Text(description)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content()
    }
    .padding(20)
    .frame(width: width)
  }
}

/// The subagent switch of a route, with its On/Off word. The route row and
/// the single-route details panel must say the same thing about subagents, so
/// they share the control rather than the wording.
struct ModelsSubagentToggle: View {
  @EnvironmentObject private var model: AppModel
  let route: ModelsRoute
  let providerName: String
  let selected: Bool
  let onChange: (Bool) -> Void

  var body: some View {
    // Turning the switch on adds the route to the subagent selection, and the
    // router publishes it as v2 with an agent definition Codex can spawn by
    // name. A registry-proven route and one the operator chose look the same
    // on purpose: both are spawnable.
    let hint = route.subagentCertification == "v2"
      ? model.t("models.subagent.v2Hint")
      : model.t("models.subagent.enableHint")
    HStack(spacing: 8) {
      ModelsSwitch(
        checked: selected,
        label: model.t("models.route.subagentLabel", ["model": route.displayName, "provider": providerName]),
        onChange: onChange
      )
      Text(selected ? model.t("models.status.on") : model.t("models.status.off"))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .help(hint)
  }
}

/// The subagent reasoning-effort menu of a route.
struct ModelsEffortMenu: View {
  @EnvironmentObject private var model: AppModel
  let route: ModelsRoute
  let providerName: String
  let selected: Bool
  let effort: String
  let onChange: (String) -> Void

  var body: some View {
    // Nothing to choose on a route that is off, or one with a single-level
    // ladder. An empty cell reads better than a menu nobody can use.
    if !selected || route.reasoningLevels.count < 2 {
      Text("—")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    } else {
      menu(["default"] + route.reasoningLevels)
    }
  }

  private func menu(_ choices: [String]) -> some View {
    Menu {
      ForEach(Array(choices.enumerated()), id: \.offset) { item in
        Button {
          if item.element != effort { onChange(item.element) }
        } label: {
          if item.element == effort {
            Label(Format.effortLabel(item.element, model.t), systemImage: "checkmark")
          } else {
            Text(Format.effortLabel(item.element, model.t))
          }
        }
      }
    } label: {
      Text(Format.effortLabel(effort, model.t))
        .font(.system(size: 12))
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel(
      model.t("models.route.subagentEffortAria", ["model": route.displayName, "provider": providerName])
    )
  }
}
