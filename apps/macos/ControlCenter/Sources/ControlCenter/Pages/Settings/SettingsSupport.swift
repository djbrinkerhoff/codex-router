import ControlCenterCore
import SwiftUI

// Small building blocks and value helpers for the Settings page, ported from
// the `setting-row`, `settings-list`, `surface-summary`, `Toggle`, `Button`,
// `Dialog` and `panel-section` pieces of `SettingsPage.tsx` / `components.tsx`.

/// JavaScript-flavoured reads over the router's lenient JSON, so the page's
/// `||`, `=== true`, `Math.round` and `typeof x === "number"` checks port
/// one to one.
enum SettingsValue {
  /// `typeof value === "number"` and finite; numeric strings do not count.
  static func number(_ value: JSONValue?) -> Double? {
    if case .number(let number)? = value, number.isFinite { return number }
    return nil
  }

  /// A string that is truthy in JavaScript: present and not empty.
  static func nonEmpty(_ value: JSONValue?) -> String? {
    guard let text = value?.string, !text.isEmpty else { return nil }
    return text
  }

  /// `nil` for a missing or `null` value, so `if (!value)` ports as a guard.
  static func present(_ value: JSONValue?) -> JSONValue? {
    guard let value = value, !value.isNull else { return nil }
    return value
  }

  static func exists(_ value: JSONValue?) -> Bool {
    if case .some = present(value) { return true }
    return false
  }

  static func truthy(_ value: JSONValue?) -> Bool {
    guard let value = value else { return false }
    return value.truthy
  }

  /// `Math.round`: halves round toward positive infinity.
  static func roundHalfUp(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    let clamped = max(-1e15, min(1e15, value))
    return Int((clamped + 0.5).rounded(.down))
  }

  /// `String(number)` for the values the router reports (whole hours, days).
  static func numberText(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    return String(value)
  }

  /// `formatBytes` from `SettingsPage.tsx`.
  static func bytes(_ value: Double?) -> String {
    guard let value = value, value.isFinite, value > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = value
    var unit = 0
    while size >= 1024 && unit < units.count - 1 {
      size /= 1024
      unit += 1
    }
    let text: String
    if size >= 10 || unit == 0 {
      text = String(roundHalfUp(size))
    } else {
      text = String(format: "%.1f", size)
    }
    return "\(text) \(units[unit])"
  }
}

/// `panel-section`: a titled panel that groups related settings.
struct SettingsSection<Content: View>: View {
  let title: String
  var description: String?
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: title, description: description)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelStyle(padding: 16)
  }
}

/// `setting-row`: a title and detail on the leading side, its control on the
/// trailing side.
struct SettingsRow<Control: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder var control: () -> Control

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold))
        if let detail = detail {
          Text(detail)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      control()
    }
    .padding(.vertical, 8)
  }
}

/// `surface-summary`: an icon beside a bold line and a footnote.
struct SettingsSummary: View {
  let systemImage: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(detail)
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
  }
}

/// The renderer's `Toggle`.
struct SettingsSwitch: View {
  let label: String
  let isOn: Bool
  var disabled = false
  let onChange: (Bool) -> Void

  var body: some View {
    Toggle(label, isOn: Binding(get: { isOn }, set: { onChange($0) }))
      .labelsHidden()
      .toggleStyle(.switch)
      .disabled(disabled)
      .accessibilityLabel(label)
  }
}

/// The renderer's `<select>`: a menu whose choice is reported once per user
/// selection, while the shown value always follows the router's answer.
struct SettingsMenuPicker<Content: View>: View {
  let label: String
  let selection: String
  var disabled = false
  let onSelect: (String) -> Void
  @ViewBuilder var content: () -> Content

  var body: some View {
    Picker(label, selection: Binding(get: { selection }, set: { onSelect($0) })) {
      content()
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .frame(minWidth: 150, maxWidth: 240)
    .disabled(disabled)
    .accessibilityLabel(label)
  }
}

enum SettingsButtonVariant {
  case primary, secondary, ghost, danger
}

private struct SettingsButtonVariantModifier: ViewModifier {
  let variant: SettingsButtonVariant

  @ViewBuilder func body(content: Content) -> some View {
    switch variant {
    case .primary: content.buttonStyle(.borderedProminent)
    case .secondary: content.buttonStyle(.bordered)
    case .ghost: content.buttonStyle(.borderless)
    case .danger: content.buttonStyle(.bordered).tint(Palette.danger)
    }
  }
}

/// The renderer's `Button` with its variants.
struct SettingsButton: View {
  let title: String
  var systemImage: String?
  var variant: SettingsButtonVariant = .secondary
  var disabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) { label }
      .modifier(SettingsButtonVariantModifier(variant: variant))
      .disabled(disabled)
  }

  @ViewBuilder private var label: some View {
    if let systemImage = systemImage {
      Label(title, systemImage: systemImage)
    } else {
      Text(title)
    }
  }
}

/// The confirmation dialogs, shown as one sheet.
enum SettingsDialog: Identifiable, Equatable {
  case sessionSharing
  case repair
  case trayDisable
  case removeAccount(String)

  var id: String {
    switch self {
    case .sessionSharing: return "session-sharing"
    case .repair: return "repair"
    case .trayDisable: return "tray-disable"
    case .removeAccount(let accountId): return "remove-account:" + accountId
    }
  }
}

/// The renderer's `Dialog` with a copy paragraph and a cancel / confirm row.
struct SettingsConfirmDialog: View {
  let title: String
  let description: String
  let message: String
  let cancelLabel: String
  let confirmLabel: String
  var confirmVariant: SettingsButtonVariant = .primary
  var confirmDisabled = false
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 15, weight: .semibold))
        Text(description)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(message)
        .font(.system(size: 12.5))
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button(cancelLabel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        confirmButton
      }
      .padding(.top, 4)
    }
    .padding(20)
    .frame(width: 440)
  }

  @ViewBuilder private var confirmButton: some View {
    if confirmVariant == .danger {
      SettingsButton(title: confirmLabel, variant: .danger, disabled: confirmDisabled, action: onConfirm)
    } else {
      SettingsButton(title: confirmLabel, variant: .primary, disabled: confirmDisabled, action: onConfirm)
        .keyboardShortcut(.defaultAction)
    }
  }
}
