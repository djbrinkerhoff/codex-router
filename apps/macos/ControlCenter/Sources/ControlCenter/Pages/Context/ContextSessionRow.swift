import ControlCenterCore
import SwiftUI

/// One indexed session (`SessionRow`).
struct ContextSessionRow: View {
  @EnvironmentObject private var model: AppModel
  let session: JSONValue
  let appAvailable: Bool
  let terminalAvailable: Bool
  let modelOverride: String
  /// Called with the session and `"app"` or `"terminal"`.
  let onOpen: (JSONValue, String) -> Void

  private var harnessId: String { session["harnessId"]?.string ?? "" }
  private var archived: Bool { session["archived"].truthy }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      icon
      main
      actions
        .frame(alignment: .trailing)
    }
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
  }

  // MARK: Icon

  private var icon: some View {
    Image(systemName: harnessId == "codex" ? "brain" : "square.stack.3d.up")
      .font(.system(size: 14))
      .foregroundStyle(harnessId == "codex" ? Palette.accent : Color.secondary)
      .frame(width: 30, height: 30)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill((harnessId == "codex" ? Palette.accent : Color.secondary).opacity(0.12))
      )
      .accessibilityHidden(true)
  }

  // MARK: Main column

  private var main: some View {
    VStack(alignment: .leading, spacing: 4) {
      titleLine
      metaLine
      usageLine
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var titleLine: some View {
    HStack(spacing: 8) {
      Text(session["title"]?.string ?? "")
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      Badge(ContextSupport.harnessName(harnessId), tone: harnessId == "codex" ? .accent : .neutral)
      if let status = session["status"]?.text {
        Badge(
          archived ? model.t("context.row.archived") : ContextSupport.readableStatus(status),
          tone: ContextSupport.tone(for: session)
        )
      }
    }
  }

  private var metaLine: some View {
    HStack(spacing: 14) {
      meta(
        "folder",
        session["workspaceLabel"]?.text ?? model.t("context.row.workspaceMissing")
      )
      meta("brain", session["model"]?.text ?? model.t("context.row.modelMissing"))
      meta("clock", Format.dateTime(session["updatedAt"], model.t))
    }
  }

  private func meta(_ systemImage: String, _ text: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage).font(.system(size: 10))
      Text(text).lineLimit(1)
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  private var usageLine: some View {
    let t = model.t
    let active = session["activeTokens"]?.double
    let total = session["totalTokens"]?.double
    let window = session["contextWindow"]?.double ?? 0
    let activeText = active.map { t("context.row.activeTokens", ["count": Format.compactNumber($0, t)]) }
      ?? t("context.row.activeUnreported")
    let totalText = total.map { t("context.row.totalTokens", ["count": Format.compactNumber($0, t)]) }
      ?? t("context.row.totalUnreported")
    var contextText: String?
    if window != 0, let activeValue = active, activeValue != 0 {
      let percent = min(100, Int((activeValue / window * 100).rounded()))
      contextText = t("context.row.contextPercent", ["percent": percent, "count": Format.compactNumber(window, t)])
    }
    return HStack(spacing: 14) {
      Text(activeText)
      Text(totalText)
      if let contextText { Text(contextText) }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  // MARK: Actions

  @ViewBuilder
  private var actions: some View {
    if archived {
      HStack(spacing: 4) {
        Image(systemName: "archivebox").font(.system(size: 11))
        Text(model.t("context.row.restoreFirst", ["harness": ContextSupport.harnessName(harnessId)]))
          .font(.system(size: 11.5))
          .lineLimit(2)
      }
      .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 8) {
        if harnessId == "codex" {
          Button {
            onOpen(session, "app")
          } label: {
            Label(model.t("context.row.openApp"), systemImage: "macwindow")
          }
          .buttonStyle(.bordered)
          .disabled(!appAvailable)
        }
        resumeButton
      }
    }
  }

  @ViewBuilder
  private var resumeButton: some View {
    let resumable = session["resumable"].truthy
    let help: String = !resumable
      ? model.t("context.row.cursorFirst")
      : modelOverride.isEmpty ? "" : model.t("context.row.resumeWith", ["model": modelOverride])
    let button = Button {
      onOpen(session, "terminal")
    } label: {
      Label(model.t("context.row.resume"), systemImage: "terminal")
    }
    .disabled(!terminalAvailable || !resumable)
    .help(help)
    if harnessId == "codex" {
      button.buttonStyle(.borderless)
    } else {
      button.buttonStyle(.borderedProminent)
    }
  }
}
