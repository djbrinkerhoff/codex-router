import ControlCenterCore
import SwiftUI

/// Placeholder until the Local page port lands.
struct LocalPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("local.eyebrow"),
      title: model.label(for: .local),
      description: model.description(for: .local)
    )
  }
}
