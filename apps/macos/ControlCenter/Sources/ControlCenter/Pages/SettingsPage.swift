import ControlCenterCore
import SwiftUI

/// Placeholder until the Settings page port lands.
struct SettingsPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("settings.eyebrow"),
      title: model.label(for: .settings),
      description: model.description(for: .settings)
    )
  }
}
