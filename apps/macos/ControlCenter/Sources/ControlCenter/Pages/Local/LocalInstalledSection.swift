import ControlCenterCore
import SwiftUI

/// The installed-models table and the read-only runtime facts beside it.
struct LocalInstalledSection: View {
  @EnvironmentObject private var model: AppModel
  let d: LocalDerived
  /// The switch value for a model tag, settled against the router.
  let isEnabled: (JSONValue) -> Bool
  let onToggle: (JSONValue, Bool) -> Void
  let onRemove: (String) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      installedPanel
        .frame(maxWidth: .infinity, alignment: .topLeading)
      detailsPanel
        .frame(width: 290, alignment: .topLeading)
    }
  }

  // MARK: Installed models

  private var installedPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: model.t("local.installed.title"),
        description: model.t("local.installed.description")
      ) {
        runtimeActions
      }
      if d.installed.isEmpty {
        EmptyStateView(
          systemImage: "internaldrive",
          title: model.t("local.installed.emptyTitle"),
          message: model.t("local.installed.emptyBody")
        )
      } else {
        VStack(spacing: 0) {
          ForEach(Array(d.installed.enumerated()), id: \.offset) { index, item in
            if index > 0 { Divider() }
            LocalModelRow(
              item: item,
              enabled: isEnabled(item),
              onToggle: { next in onToggle(item, next) },
              onBenchmark: {
                let tag = item["tag"]?.string ?? ""
                LocalActions.run(model, model.t("local.action.benchmark", ["tag": tag])) { api in
                  try await api.benchmarkLocalModel(tag)
                }
              },
              onRemove: { onRemove(item["tag"]?.string ?? "") }
            )
          }
        }
      }
    }
    .panelStyle(padding: 14)
  }

  private var runtimeActions: some View {
    HStack(spacing: 8) {
      if !d.runtimeRunning {
        Button {
          LocalActions.run(model, model.t("local.action.startRuntime")) { api in
            try await api.controlLocalRuntime("start")
          }
        } label: {
          Label(model.t("local.installed.startRuntime"), systemImage: "play")
        }
        .buttonStyle(.borderless)
      }
      if d.runtimeInstalled {
        Button {
          LocalActions.run(model, model.t("local.action.updateRuntime")) { api in
            try await api.controlLocalRuntime("update")
          }
        } label: {
          Label(model.t("local.installed.updateOllama"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  // MARK: Runtime details

  private var detailsPanel: some View {
    let runtime = d.local?["runtime"]
    let state = d.runtimeRunning
      ? model.t("local.details.running")
      : d.runtimeInstalled ? model.t("local.details.stopped") : model.t("local.details.notInstalled")
    let version = runtime?["version"]?.text ?? model.t("local.details.notReported")
    let managed = (runtime?["managed"]).truthy
    let path = runtime?["modelsPath"]?.text
    return VStack(alignment: .leading, spacing: 10) {
      SectionHeading(title: model.t("local.details.title"), description: model.t("local.details.description"))
      DetailRow(label: model.t("local.details.state"), value: state)
      DetailRow(label: model.t("local.details.version"), value: version)
      DetailRow(
        label: model.t("local.details.managed"),
        value: managed ? model.t("local.details.routerManaged") : model.t("local.details.external")
      )
      DetailRow(label: model.t("local.details.modelsPath"), value: path ?? model.t("local.details.ollamaDefault"))
        .help(path ?? "")
    }
    .panelStyle(padding: 14)
  }
}

/// One installed Ollama model (`LocalModelRow`).
private struct LocalModelRow: View {
  @EnvironmentObject private var model: AppModel
  let item: JSONValue
  let enabled: Bool
  let onToggle: (Bool) -> Void
  let onBenchmark: () -> Void
  let onRemove: () -> Void

  var body: some View {
    let tag = item["tag"]?.string ?? ""
    let maker = LocalSupport.brand(for: item)
    HStack(alignment: .center, spacing: 14) {
      HStack(spacing: 10) {
        BrandLogo(brand: maker, size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(LocalSupport.modelName(item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          Text(maker.name).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
          Text(verbatim: "local/\(tag)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      facts
      controls(tag: tag)
    }
    .padding(.vertical, 9)
  }

  private var facts: some View {
    let speedValue = item["observedTokensPerSecond"]?.double ?? item["speed"]?.double
    let contextValue = item["context"]?.double ?? 0
    let context = contextValue != 0
      ? model.t("local.model.context", ["count": Format.compactNumber(contextValue, model.t)])
      : model.t("local.model.contextUnreported")
    let speed = speedValue.map { String(format: "%.1f tok/s", $0) } ?? model.t("local.model.speedUnmeasured")
    return VStack(alignment: .trailing, spacing: 1) {
      Text(Format.bytesGb(item["sizeGb"]?.double, model.t)).font(.system(size: 11.5))
      Text(context).font(.system(size: 11)).foregroundStyle(.secondary)
      Text(speed).font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func controls(tag: String) -> some View {
    HStack(spacing: 8) {
      Button(action: onBenchmark) {
        Label(model.t("local.model.measure"), systemImage: "gauge")
      }
      .buttonStyle(.borderless)
      IconButton(systemImage: "trash", label: model.t("local.action.remove", ["tag": tag]), action: onRemove)
      VStack(spacing: 2) {
        Text("Codex").font(.system(size: 10.5)).foregroundStyle(.secondary)
        LocalSwitch(isOn: enabled, label: model.t("local.model.enableAria", ["tag": tag]), onChange: onToggle)
      }
    }
  }
}
