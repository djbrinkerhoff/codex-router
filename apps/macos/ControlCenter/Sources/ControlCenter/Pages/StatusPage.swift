import ControlCenterCore
import SwiftUI

/// Placeholder until the Status page port lands.
struct StatusPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("status.eyebrow"),
      title: model.label(for: .status),
      description: model.description(for: .status)
    )
  }
}
