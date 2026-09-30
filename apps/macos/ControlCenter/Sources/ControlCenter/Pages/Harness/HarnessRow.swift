import ControlCenterCore
import SwiftUI

/// Column widths shared by the table header and every row so they line up.
enum HarnessColumns {
  static let models: CGFloat = 64
  static let sessions: CGFloat = 64
  static let actions: CGFloat = 232
  static let spacing: CGFloat = 12
}

/// The header above the client rows (`lhc-harness-table-head`).
struct HarnessTableHead: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: HarnessColumns.spacing) {
      Text(model.t("harness.table.client")).frame(maxWidth: .infinity, alignment: .leading)
      Text(model.t("harness.table.models")).frame(width: HarnessColumns.models, alignment: .center)
      Text(model.t("harness.table.sessions")).frame(width: HarnessColumns.sessions, alignment: .center)
      Text(model.t("harness.table.actions")).frame(width: HarnessColumns.actions, alignment: .trailing)
    }
    .font(.system(size: 10.5, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .accessibilityHidden(true)
  }
}

/// The handlers one row can trigger. The page owns every router call.
struct HarnessRowHandlers {
  var toggleRouting: (Bool) -> Void
  var setup: () -> Void
  var open: (String) -> Void
  var update: () -> Void
  var showSessions: () -> Void
  var openDocs: () -> Void
}

/// One coding client (`HarnessRow` plus its action cluster).
struct HarnessRow: View {
  @EnvironmentObject private var model: AppModel
  let harness: JSONValue
  let sessions: Int
  let modelFact: (label: String, title: String)
  let bridge: JSONValue?
  let enabled: Bool
  let busy: Bool
  let terminalAvailable: Bool
  let updateAvailable: Bool
  @Binding var cursorHostname: String
  let handlers: HarnessRowHandlers

  private var id: String { harness["id"]?.string ?? "" }
  private var name: String { harness["displayName"]?.string ?? id }
  private var isCursor: Bool { id == "cursor" }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: HarnessColumns.spacing) {
        header.frame(maxWidth: .infinity, alignment: .leading)
        catalogFact.frame(width: HarnessColumns.models)
        sessionsButton.frame(width: HarnessColumns.sessions)
        actions.frame(width: HarnessColumns.actions, alignment: .trailing)
      }
      setupControl
    }
    .padding(12)
    .panelStyle()
  }

  // MARK: Identity

  private var statusBadge: some View {
    let configured = harness["configured"].truthy
    let detected = harness["cliInstalled"].truthy || harness["appInstalled"].truthy
    let text = configured
      ? model.t("harness.row.ready")
      : detected ? model.t("harness.row.detected") : model.t("harness.row.missing")
    let tone: Tone = configured ? .success : detected ? .accent : .neutral
    return Badge(text, tone: tone)
      .help(harness["cliVersion"]?.text ?? "")
  }

  private var header: some View {
    HStack(spacing: 12) {
      HarnessMark(id: id, name: name)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
          statusBadge
          docsButton
        }
        if let version = harness["cliVersion"]?.text {
          Text(version)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }
        bridgeLine
      }
    }
  }

  @ViewBuilder
  private var docsButton: some View {
    if let url = harness["docsUrl"]?.text, url.lowercased().hasPrefix("https://") {
      Button(action: handlers.openDocs) {
        Image(systemName: "arrow.up.forward.square").font(.system(size: 11))
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help(model.t("harness.openSiteTitle", ["name": name]))
      .accessibilityLabel(model.t("harness.openSiteTitle", ["name": name]))
    }
  }

  @ViewBuilder
  private var bridgeLine: some View {
    if let bridge = bridge, bridge["installed"].truthy {
      let count = Int(bridge["sessions"]?.double ?? 0)
      Text(count > 0 ? model.t("harness.row.agentCount", ["count": count]) : model.t("harness.row.agent"))
        .font(.system(size: 11))
        .foregroundStyle(Palette.success)
        .help(model.t("harness.row.bridgeTitle"))
    }
  }

  // MARK: Facts

  private var catalogFact: some View {
    Text(modelFact.label)
      .font(.system(size: 13, weight: .medium))
      .frame(maxWidth: .infinity)
      .help(modelFact.title)
  }

  private var sessionsButton: some View {
    Button(action: handlers.showSessions) {
      Text(String(sessions))
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(model.t("harness.row.indexedSessions", ["count": sessions]))
  }

  // MARK: Cursor setup

  @ViewBuilder
  private var setupControl: some View {
    if isCursor && busy {
      cursorProgress
    } else if isCursor && harness["appInstalled"].truthy && !enabled {
      cursorConnect
    }
  }

  private var cursorProgress: some View {
    let operation = model.operation
    let text: String
    if operation?.status == .started {
      text = LocalSupport.or(model.t.backend(operation?.message), model.t("harness.cursor.preparing"))
    } else {
      text = model.t("harness.cursor.refreshing")
    }
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      ProgressView()
        .progressViewStyle(.linear)
        .accessibilityLabel(model.t("harness.cursor.progressAria"))
    }
    .accessibilityElement(children: .contain)
  }

  private var cursorConnect: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "globe").foregroundStyle(.secondary)
        Text(HarnessSupport.cursorTunnelHelp(harness, model.t))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      DisclosureGroup(model.t("harness.cursor.existingHostname")) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.t("harness.cursor.hostname")).font(.system(size: 12, weight: .medium))
          TextField("cursor-router.example.com", text: $cursorHostname)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
          Text(model.t("harness.cursor.hostnameOptional"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
      }
      .font(.system(size: 12))
    }
  }

  // MARK: Actions

  private var actions: some View {
    HStack(spacing: 8) {
      routeToggle
      launchButtons
      if updateAvailable { updateButton }
    }
  }

  private var routeToggle: some View {
    let disabled = busy || (!enabled && !harness["canInstall"].truthy)
    return LocalSwitch(
      isOn: enabled,
      label: model.t("harness.routeToggle", ["name": name]),
      disabled: disabled,
      hint: HarnessSupport.hint(harness, model.t),
      onChange: handlers.toggleRouting
    )
  }

  @ViewBuilder
  private var launchButtons: some View {
    if enabled {
      appButton
      terminalButton
    } else {
      setupButton
    }
  }

  private var appButton: some View {
    let title = harness["appInstalled"].truthy
      ? model.t("harness.openAppTitle", ["name": name])
      : model.t("harness.openSiteTitle", ["name": name])
    return Button {
      handlers.open("app")
    } label: {
      if busy {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: "macwindow")
      }
    }
    .buttonStyle(.borderedProminent)
    .disabled(busy)
    .help(title)
    .accessibilityLabel(model.t("harness.openAppAria", ["name": name]))
  }

  private var terminalButton: some View {
    let title: String
    if !terminalAvailable {
      title = model.t("harness.terminalMacOnly")
    } else if !harness["cliInstalled"].truthy {
      title = model.t("harness.cliNotInstalled", ["name": name])
    } else {
      title = model.t("harness.openTerminalTitle", ["name": name])
    }
    return Button {
      handlers.open("terminal")
    } label: {
      Image(systemName: "terminal")
    }
    .buttonStyle(.bordered)
    .disabled(busy || !harness["cliInstalled"].truthy || !terminalAvailable)
    .help(title)
    .accessibilityLabel(model.t("harness.openTerminalAria", ["name": name]))
  }

  private var setupButton: some View {
    Button {
      handlers.setup()
    } label: {
      if busy {
        ProgressView().controlSize(.small)
      } else {
        Text(isCursor ? model.t("harness.connect") : model.t("harness.setUp"))
      }
    }
    .buttonStyle(.borderedProminent)
    .disabled(busy || !harness["canInstall"].truthy)
    .help(model.t.backend(harness["installRequirement"]?.string))
    .accessibilityLabel(model.t("harness.setupAria", ["name": name]))
  }

  private var updateButton: some View {
    let title: String
    if let command = harness["updateCommand"]?.text {
      title = model.t("harness.runsCommand", ["command": command])
    } else {
      title = model.t("harness.updateTitle", ["name": name])
    }
    return Button {
      handlers.update()
    } label: {
      Image(systemName: "arrow.up.circle")
    }
    .buttonStyle(.borderless)
    .disabled(busy)
    .help(title)
    .accessibilityLabel(model.t("harness.updateAria", ["name": name]))
  }
}
