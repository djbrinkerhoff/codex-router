import ControlCenterCore
import SwiftUI

/// The window: sidebar, title row, the active page, search, and toasts.
/// Ported from the shell in `App.tsx`.
struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 0) {
      if model.sidebarOpen {
        Sidebar()
          .frame(width: 232)
          .transition(.move(edge: .leading))
        Divider()
      }
      VStack(spacing: 0) {
        TitleRow()
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if let message = model.loadError ?? model.firstReadError {
              InlineNotice(tone: .warning, title: model.t("app.data.loadError"), message: model.t.backend(message))
            }
            page
          }
          .padding(.horizontal, 28)
          .padding(.vertical, 22)
          .frame(maxWidth: 1180, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .top)
        }
        .id(model.view)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.canvas)
    }
    .overlay(alignment: .bottomTrailing) {
      if let toast = model.toast {
        ToastView(toast: toast)
          .padding(20)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .sheet(isPresented: $model.searchOpen) {
      SearchSheet()
        .environmentObject(model)
    }
    .animation(.easeOut(duration: 0.18), value: model.sidebarOpen)
    .animation(.easeOut(duration: 0.18), value: model.toast)
    .environment(\.layoutDirection, model.t.option.rtl ? .rightToLeft : .leftToRight)
    .environment(\.locale, model.t.locale)
  }

  @ViewBuilder private var page: some View {
    switch model.view {
    case .dashboard: DashboardPage()
    case .usage: UsagePage()
    case .status: StatusPage()
    case .models: ModelsPage()
    case .local: LocalPage()
    case .harness: HarnessPage()
    case .context: ContextPage()
    case .settings: SettingsPage()
    }
  }
}

private struct Sidebar: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Spacer().frame(width: 70) // traffic lights
        IconButton(systemImage: "sidebar.left", label: model.t("app.sidebar.collapse")) { model.sidebarOpen = false }
        IconButton(systemImage: "chevron.left", label: model.t("app.nav.back")) { model.back() }
          .disabled(!model.canGoBack)
        IconButton(systemImage: "chevron.right", label: model.t("app.nav.forward")) { model.forward() }
          .disabled(!model.canGoForward)
        Spacer()
      }
      .frame(height: 44)

      HStack {
        Text("Codex Router").font(.system(size: 15, weight: .semibold))
        Spacer()
        IconButton(systemImage: "magnifyingglass", label: model.t("app.search.aria")) { model.searchOpen = true }
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 10)

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(ViewID.allCases) { item in
            SidebarItem(item: item)
          }
        }
        .padding(.horizontal, 8)
      }

      Spacer(minLength: 0)
      Divider()
      SidebarFooter()
        .padding(12)
    }
    .background(Palette.sidebar)
  }
}

private struct SidebarItem: View {
  @EnvironmentObject private var model: AppModel
  let item: ViewID

  var body: some View {
    let selected = model.view == item
    Button {
      model.navigate(item)
    } label: {
      HStack(spacing: 9) {
        Image(systemName: item.systemImage)
          .frame(width: 16)
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        Text(model.label(for: item))
          .font(.system(size: 13, weight: selected ? .semibold : .regular))
          .lineLimit(1)
        Spacer(minLength: 4)
        if item.experimental {
          Badge(model.t("nav.harness.experimental"), tone: .warning)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(selected ? Palette.selection : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(model.description(for: item))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct SidebarFooter: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let online = model.health?["ok"]?.bool == true
    let activity = model.health?["activity"]
    let activeCount = activity?["activeCount"]?.int ?? 0
    let providerCount = model.target?["enabledProviders"]?.items.count ?? 0
    HStack(spacing: 10) {
      Circle()
        .fill(online ? Palette.success : Palette.danger)
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text(online ? model.t("app.health.online") : model.t("app.health.offline"))
          .font(.system(size: 12, weight: .semibold))
        Group {
          if activity?["state"]?.string == "generating" {
            Text(model.t("app.health.thinking"))
          } else if activeCount > 0 {
            Text(model.t("app.health.activeCount", ["count": activeCount]))
          } else if providerCount > 0 {
            Text(model.t("app.health.providerRoutes", ["count": providerCount]))
          } else {
            Text(model.t("app.health.waitingForSetup"))
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer()
      IconButton(
        systemImage: model.isDark ? "sun.max" : "moon",
        label: model.isDark ? model.t("app.theme.switchToLight") : model.t("app.theme.switchToDark")
      ) {
        model.theme = model.isDark ? .light : .dark
      }
    }
  }
}

private struct TitleRow: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 10) {
      if !model.sidebarOpen {
        Spacer().frame(width: 70)
        IconButton(systemImage: "sidebar.left", label: model.t("app.sidebar.expand")) { model.sidebarOpen = true }
      }
      Text(model.label(for: model.view)).font(.system(size: 13, weight: .semibold))
      Text(model.t("app.title.overview")).font(.system(size: 13)).foregroundStyle(.secondary)
      if model.view.experimental {
        Badge(model.t("nav.harness.experimental"), tone: .warning)
      }
      Spacer()
      if let operation = model.operation, operation.status == .started {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(model.t.backend(operation.message ?? operation.action))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      IconButton(systemImage: "arrow.clockwise", label: model.t("app.refreshAll")) {
        Task { await model.refreshAll() }
      }
      .disabled(model.refreshing)
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
  }
}

private struct ToastView: View {
  @EnvironmentObject private var model: AppModel
  let toast: Toast

  var body: some View {
    HStack(spacing: 10) {
      switch toast.tone {
      case .success: Badge(model.t("app.toast.done"), tone: .success)
      case .danger: Badge(model.t("app.toast.error"), tone: .danger)
      case .neutral: Badge(model.t("app.toast.started"), tone: .neutral)
      }
      Text(model.t.backend(toast.message))
        .font(.system(size: 12.5))
        .lineLimit(3)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 460, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.border))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .accessibilityElement(children: .combine)
  }
}

/// Section search (the renderer's `SearchDialog`).
private struct SearchSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @FocusState private var focused: Bool

  private var matches: [ViewID] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return ViewID.allCases }
    return ViewID.allCases.filter {
      model.label(for: $0).lowercased().contains(needle)
        || model.description(for: $0).lowercased().contains(needle)
        || $0.rawValue.contains(needle)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField(model.t("searchDialog.placeholder"), text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit { if let first = matches.first { choose(first) } }
        .accessibilityLabel(model.t("searchDialog.inputAria"))
      Text(matches.count == 1
        ? model.t("searchDialog.resultCountOne", ["count": 1])
        : model.t("searchDialog.resultCount", ["count": matches.count]))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      if matches.isEmpty {
        EmptyStateView(systemImage: "magnifyingglass", title: model.t("searchDialog.emptyTitle"), message: model.t("searchDialog.emptyBody"))
      } else {
        VStack(spacing: 2) {
          ForEach(matches) { item in
            Button { choose(item) } label: {
              HStack(spacing: 10) {
                Image(systemName: item.systemImage).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                  Text(model.label(for: item)).font(.system(size: 13, weight: .medium))
                  Text(model.description(for: item)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if item == model.view { Badge(model.t("searchDialog.current"), tone: .accent) }
              }
              .padding(8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
      HStack {
        Spacer()
        Button(model.t("searchDialog.hintClose")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(18)
    .frame(width: 440)
    .onAppear { focused = true }
  }

  private func choose(_ item: ViewID) {
    model.navigate(item)
    dismiss()
  }
}
