import AppKit
import ControlCenterCore
import SwiftUI

// Shared building blocks, ported from `components.tsx`. Pages compose these
// rather than styling their own, so every section reads as one app.

enum Palette {
  static let canvas = Color(nsColor: .windowBackgroundColor)
  static let sidebar = Color(nsColor: .underPageBackgroundColor)
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let border = Color(nsColor: .separatorColor)
  static let selection = Color.accentColor.opacity(0.14)
  static let success = Color(nsColor: .systemGreen)
  static let warning = Color(nsColor: .systemOrange)
  static let danger = Color(nsColor: .systemRed)
  static let accent = Color.accentColor
  static let muted = Color.secondary

  /// A chart series color from the renderer's categorical palette.
  static let series: [Color] = [
    Color(red: 0.34, green: 0.46, blue: 0.66),
    Color(red: 0.55, green: 0.37, blue: 0.56),
    Color(red: 0.28, green: 0.49, blue: 0.45),
    Color(red: 0.64, green: 0.40, blue: 0.28),
    Color(red: 0.43, green: 0.42, blue: 0.64),
    Color(red: 0.49, green: 0.42, blue: 0.29),
  ]

  static func hex(_ value: String) -> Color {
    var text = value.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let number = UInt32(text, radix: 16) else { return .gray }
    return Color(
      red: Double((number >> 16) & 0xFF) / 255,
      green: Double((number >> 8) & 0xFF) / 255,
      blue: Double(number & 0xFF) / 255
    )
  }
}

enum Tone {
  case neutral, success, warning, danger, accent

  var color: Color {
    switch self {
    case .neutral: return .secondary
    case .success: return Palette.success
    case .warning: return Palette.warning
    case .danger: return Palette.danger
    case .accent: return Palette.accent
    }
  }
}

struct Badge: View {
  let text: String
  let tone: Tone

  init(_ text: String, tone: Tone = .neutral) {
    self.text = text
    self.tone = tone
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .semibold))
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
      .background(Capsule().fill(tone.color.opacity(tone == .neutral ? 0.12 : 0.14)))
  }
}

/// A borderless SF Symbol button with an accessibility label and tooltip.
struct IconButton: View {
  let systemImage: String
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .regular))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(label)
    .accessibilityLabel(label)
  }
}

/// The eyebrow / title / description block at the top of every page.
struct PageHeader<Actions: View>: View {
  @EnvironmentObject private var model: AppModel
  let eyebrow: String
  let title: String
  let description: String
  var onRefresh: (() -> Void)?
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(eyebrow.uppercased())
          .font(.system(size: 10.5, weight: .semibold))
          .tracking(0.6)
          .foregroundStyle(.secondary)
        Text(title).font(.system(size: 24, weight: .semibold))
        Text(description)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        actions()
        if let onRefresh {
          Button {
            onRefresh()
          } label: {
            Label(model.t("common.refresh"), systemImage: "arrow.clockwise")
          }
          .disabled(model.refreshing)
          .help(model.t("common.refreshTitle", ["title": title]))
        }
      }
    }
    .padding(.bottom, 4)
  }
}

extension PageHeader where Actions == EmptyView {
  init(eyebrow: String, title: String, description: String, onRefresh: (() -> Void)? = nil) {
    self.init(eyebrow: eyebrow, title: title, description: description, onRefresh: onRefresh, actions: { EmptyView() })
  }
}

struct StatItem: Identifiable {
  var id: String { label }
  let label: String
  let value: String
  var detail: String?
  var tone: Tone = .neutral
}

/// A row of headline figures (`StatStrip`).
struct StatStrip: View {
  let items: [StatItem]

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0 { Divider().padding(.vertical, 4) }
        VStack(alignment: .leading, spacing: 4) {
          Text(item.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(item.value)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(item.tone == .neutral ? Color.primary : item.tone.color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          if let detail = item.detail {
            Text(detail)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      }
    }
    .panelStyle()
  }
}

struct SectionHeading<Action: View>: View {
  let title: String
  var description: String?
  @ViewBuilder var action: () -> Action

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 15, weight: .semibold))
        if let description {
          Text(description)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      action()
    }
  }
}

extension SectionHeading where Action == EmptyView {
  init(title: String, description: String? = nil) {
    self.init(title: title, description: description, action: { EmptyView() })
  }
}

struct EmptyStateView<Action: View>: View {
  var systemImage: String?
  let title: String
  let message: String
  @ViewBuilder var action: () -> Action

  var body: some View {
    VStack(spacing: 8) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 22))
          .foregroundStyle(.secondary)
      }
      Text(title).font(.system(size: 14, weight: .semibold))
      Text(message)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      action()
    }
    .frame(maxWidth: .infinity)
    .padding(24)
  }
}

extension EmptyStateView where Action == EmptyView {
  init(systemImage: String? = nil, title: String, message: String) {
    self.init(systemImage: systemImage, title: title, message: message, action: { EmptyView() })
  }
}

struct InlineNotice: View {
  enum NoticeTone { case neutral, success, warning, danger }
  let tone: NoticeTone
  let title: String
  var message: String?

  private var color: Color {
    switch tone {
    case .neutral: return .secondary
    case .success: return Palette.success
    case .warning: return Palette.warning
    case .danger: return Palette.danger
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: tone == .success ? "checkmark.circle" : "exclamationmark.triangle")
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 12.5, weight: .semibold))
        if let message, !message.isEmpty {
          Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(color.opacity(0.25)))
  }
}

/// A shimmer-free placeholder block while a source loads.
struct SkeletonBlock: View {
  var height: CGFloat = 14
  var width: CGFloat?

  var body: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(Color.secondary.opacity(0.12))
      .frame(width: width, height: height)
      .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
      .accessibilityHidden(true)
  }
}

/// A whole-page loading placeholder (`LoadingState`).
struct LoadingStateView: View {
  @EnvironmentObject private var model: AppModel
  var label: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SkeletonBlock(height: 10, width: 80)
      SkeletonBlock(height: 24, width: 240)
      SkeletonBlock(height: 12, width: 380)
      HStack(spacing: 12) {
        ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 64) }
      }
      SkeletonBlock(height: 160)
      ForEach(0..<5, id: \.self) { _ in SkeletonBlock(height: 28) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? model.t("common.loadingRouterData"))
  }
}

/// A list or card-grid placeholder inside one panel (`PanelSkeleton`).
struct PanelSkeleton: View {
  @EnvironmentObject private var model: AppModel
  var label: String?
  var count = 4

  var body: some View {
    VStack(spacing: 8) {
      ForEach(0..<count, id: \.self) { _ in SkeletonBlock(height: 34) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? model.t("common.loadingContent"))
  }
}

struct SearchField: View {
  @EnvironmentObject private var model: AppModel
  @Binding var text: String
  var placeholder: String?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(placeholder ?? model.t("common.search"), text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .accessibilityLabel(model.t("common.clearSearch"))
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.panel))
    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.border))
    .frame(maxWidth: 280)
  }
}

/// A labelled horizontal meter, e.g. "% left" of a quota.
struct MeterBar: View {
  /// 0...100.
  let percent: Double
  var tone: Tone = .accent

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.15))
        Capsule()
          .fill(tone.color)
          .frame(width: proxy.size.width * CGFloat(min(100, max(0, percent)) / 100))
      }
    }
    .frame(height: 6)
    .accessibilityValue("\(Int(percent.rounded()))%")
  }
}

/// The rounded, bordered surface every card and table sits on.
struct PanelStyle: ViewModifier {
  var padding: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panel))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.border))
  }
}

extension View {
  func panelStyle(padding: CGFloat = 0) -> some View {
    modifier(PanelStyle(padding: padding))
  }
}

/// A titled panel with optional trailing accessory.
struct Card<Content: View, Accessory: View>: View {
  let title: String
  var subtitle: String?
  @ViewBuilder var accessory: () -> Accessory
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 13.5, weight: .semibold))
          if let subtitle {
            Text(subtitle)
              .font(.system(size: 11.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        accessory()
      }
      content()
    }
    .panelStyle(padding: 14)
  }
}

extension Card where Accessory == EmptyView {
  init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
  }
}

/// A key / value line inside a card.
struct DetailRow: View {
  let label: String
  let value: String
  var tone: Tone = .neutral

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

/// Grid of equal-width cards that wraps to the window width.
struct CardGrid<Content: View>: View {
  var minimum: CGFloat = 260
  @ViewBuilder var content: () -> Content

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
      content()
    }
  }
}
