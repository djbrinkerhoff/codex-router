import ControlCenterCore
import SwiftUI

// The left column's sections other than the account pool: routing, the
// background service, and Token maxxing (tool-result aging).

// MARK: - Routing

struct SettingsRoutingSection: View {
  @EnvironmentObject private var model: AppModel
  @ObservedObject var toggles: OptimisticValues<Bool>
  @Binding var dialog: SettingsDialog?

  private var t: Translator { model.t }
  private var target: JSONValue? { SettingsValue.present(model.target) }
  /// The client-only status wins; the snapshot's projection is the fallback.
  private var session: JSONValue? {
    SettingsValue.present(model.chatgptSession) ?? SettingsValue.present(model.snapshot?["chatgptSession"])
  }
  private var sharingEnabled: Bool { session?["sharing"]?.string == "enabled" }

  private var sessionLoginLabel: String {
    let state = session?["session"]?.string
    if state == "usable" {
      if let hours = SettingsValue.number(session?["expiresInHours"]) {
        return t("settings.chatgptSession.status.loginUsableHours", ["hours": SettingsValue.numberText(hours)])
      }
      return t("settings.chatgptSession.status.loginUsable")
    }
    if state == "expired" { return t("settings.chatgptSession.status.loginExpired") }
    if SettingsValue.truthy(session?["present"]) { return t("settings.chatgptSession.status.loginUnavailableDetected") }
    return t("settings.chatgptSession.status.loginUnavailableLogin")
  }

  private var sessionSharingLabel: String {
    guard SettingsValue.exists(session) else { return t("settings.chatgptSession.status.unavailable") }
    let sharing = t(sharingEnabled
      ? "settings.chatgptSession.status.sharingEnabled"
      : "settings.chatgptSession.status.sharingDisabled")
    return "\(sharing) · \(sessionLoginLabel)"
  }

  var body: some View {
    SettingsSection(title: t("settings.routing.title"), description: t("settings.routing.description")) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(title: t("settings.signedRouting.title"), detail: t("settings.signedRouting.detail")) {
          SettingsSwitch(
            label: t("settings.signedRouting.title"),
            isOn: toggles.value("signed-routing", fallback: target?["signedRouting"]?.bool == true),
            disabled: !SettingsValue.exists(target)
          ) { enabled in
            toggles.mutate(
              "signed-routing",
              to: enabled,
              label: t("app.action.changeSignedRouting"),
              model: model
            ) { api in
              try await api.setSignedRouting(enabled)
            }
          }
        }
        Divider()
        SettingsRow(
          title: t("settings.chatgptSession.title"),
          detail: "\(t("settings.chatgptSession.detail")) \(sessionSharingLabel)"
        ) {
          SettingsSwitch(
            label: t("settings.chatgptSession.title"),
            isOn: sharingEnabled,
            disabled: !SettingsValue.exists(session) || (!sharingEnabled && session?["session"]?.string != "usable")
          ) { enabled in
            if enabled {
              dialog = .sessionSharing
            } else {
              model.perform(t("settings.chatgptSession.action.disable")) { api in
                try await api.setChatGptSessionSharing(false)
              }
            }
          }
        }
      }
      InlineNotice(tone: .neutral, title: t("settings.restart.title"), message: t("settings.restart.body"))
    }
  }
}

// MARK: - Background service

struct SettingsServiceSection: View {
  @EnvironmentObject private var model: AppModel
  private var t: Translator { model.t }
  private var running: Bool { SettingsValue.truthy(model.health?["ok"]) }

  var body: some View {
    SettingsSection(title: t("settings.service.title"), description: t("settings.service.description")) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(title: t("settings.presence.title"), detail: t("settings.presence.detail")) {
          SettingsMenuPicker(
            label: t("settings.presence.title"),
            selection: SettingsValue.nonEmpty(model.presence?["mode"]) ?? "always",
            onSelect: { mode in
              model.perform(t("app.action.changePresenceMode")) { api in
                try await api.setPresence(mode)
              }
            }
          ) {
            Text(t("settings.presence.always")).tag("always")
            Text(t("settings.presence.followCodex")).tag("follow-codex")
          }
        }
        Divider()
        SettingsRow(title: t("settings.serviceState.title"), detail: t("settings.serviceState.detail")) {
          Badge(
            running ? t("settings.serviceState.running") : t("settings.serviceState.offline"),
            tone: running ? .success : .danger
          )
        }
      }
      HStack(spacing: 8) {
        // Stop and restart stay terminal-only: only `start` is offered here.
        SettingsButton(title: t("settings.action.start"), systemImage: "server.rack", variant: .secondary) {
          model.perform(t("app.action.startService")) { api in
            try await api.controlService("start")
          }
        }
      }
    }
  }
}

// MARK: - Token maxxing

struct SettingsContextSection: View {
  /// Mirrors RETENTION_MIN/MAX/DEFAULT_TTL_DAYS in src/tool-result-retention.mjs.
  /// `0` is not "no retention": it is the stored answer meaning "keep the
  /// archived originals until I say otherwise", so it has its own option.
  static let retentionDefaultTtlDays = 7
  static let retentionChoices: [Double] = [1, 3, 7, 14, 30, 90]

  @EnvironmentObject private var model: AppModel
  @ObservedObject var toggles: OptimisticValues<Bool>

  private var t: Translator { model.t }
  private var aging: JSONValue? { SettingsValue.present(model.target?["modelSettings"]?["toolResultAging"]) }

  var body: some View {
    SettingsSection(title: t("settings.context.title"), description: t("settings.context.description")) {
      if let aging = aging {
        agingContent(aging)
      } else {
        InlineNotice(tone: .neutral, title: t("settings.context.title"), message: t("settings.context.unavailable"))
      }
    }
  }

  /// `retentionTtlDays` is absent only when nobody has answered, which is a
  /// different state from a stored 0. Keep them apart in the select.
  private func ttlValue(_ aging: JSONValue) -> String {
    guard let days = SettingsValue.number(aging["retentionTtlDays"]) else { return "default" }
    return SettingsValue.numberText(days)
  }

  private func ttlChoices(_ aging: JSONValue) -> [Double] {
    var choices = Self.retentionChoices
    if let days = SettingsValue.number(aging["retentionTtlDays"]), days > 0, !choices.contains(days) {
      choices.append(days)
      choices.sort()
    }
    return choices
  }

  private func savingsText(_ aging: JSONValue) -> String {
    let stats = aging["stats"]
    let saved = SettingsValue.number(stats?["estimatedTokensSaved"]) ?? 0
    guard saved > 0 else { return t("settings.context.noSavings") }
    return t("settings.context.savings", [
      "tokens": Format.compactNumber(stats?["estimatedTokensSaved"]?.double, t),
      "size": SettingsValue.bytes(stats?["bytesSaved"]?.double),
      "requests": Format.compactNumber(stats?["requests"]?.double, t),
    ])
  }

  @ViewBuilder private func agingContent(_ aging: JSONValue) -> some View {
    let locked = aging["environmentOverride"]?.bool == true
    let enabled = toggles.value("tool-result-aging", fallback: aging["enabled"]?.bool == true)
    VStack(alignment: .leading, spacing: 0) {
      SettingsRow(title: t("settings.context.enable.title"), detail: t("settings.context.enable.detail")) {
        SettingsSwitch(label: t("settings.context.enable.title"), isOn: enabled, disabled: locked) { next in
          toggles.mutate(
            "tool-result-aging",
            to: next,
            label: t("app.action.changeTokenMaxxing"),
            model: model
          ) { api in
            try await api.setToolResultAging(next)
          }
        }
      }
      Divider()
      SettingsRow(title: t("settings.context.native.title"), detail: t("settings.context.native.detail")) {
        SettingsSwitch(
          label: t("settings.context.native.title"),
          isOn: toggles.value("native-tool-result-aging", fallback: aging["nativeEnabled"]?.bool == true),
          disabled: locked || !enabled
        ) { next in
          toggles.mutate(
            "native-tool-result-aging",
            to: next,
            label: t("app.action.changeNativeCompaction"),
            model: model
          ) { api in
            try await api.setNativeToolResultAging(next)
          }
        }
      }
      Divider()
      SettingsRow(title: t("settings.context.ttl.title"), detail: t("settings.context.ttl.detail")) {
        SettingsMenuPicker(
          label: t("settings.context.ttl.title"),
          selection: ttlValue(aging),
          disabled: locked,
          onSelect: { raw in
            let days: JSONValue = raw == "default" ? .string("default") : .number(Double(raw) ?? 0)
            model.perform(t("app.action.changeRetentionWindow")) { api in
              try await api.setToolResultRetentionTtl(days)
            }
          }
        ) {
          Text(t("settings.context.ttl.default", ["days": Self.retentionDefaultTtlDays])).tag("default")
          ForEach(ttlChoices(aging), id: \.self) { days in
            Text(t("settings.context.ttl.days", ["days": SettingsValue.numberText(days)]))
              .tag(SettingsValue.numberText(days))
          }
          Text(t("settings.context.ttl.forever")).tag("0")
        }
      }
    }
    if locked {
      InlineNotice(
        tone: .warning,
        title: t("settings.context.envOverride.title"),
        message: t("settings.context.envOverride.body")
      )
    }
    Text(savingsText(aging))
      .font(.system(size: 11.5))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
