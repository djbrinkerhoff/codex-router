import ControlCenterCore
import SwiftUI

/// Placeholder until the Models page port lands.
struct ModelsPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("models.eyebrow"),
      title: model.label(for: .models),
      description: model.description(for: .models)
    )
  }
}
