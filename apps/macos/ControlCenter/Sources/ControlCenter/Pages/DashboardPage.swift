import ControlCenterCore
import SwiftUI

/// Placeholder until the Dashboard page port lands.
struct DashboardPage: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    PageHeader(
      eyebrow: model.t("dashboard.eyebrow"),
      title: model.label(for: .dashboard),
      description: model.description(for: .dashboard)
    )
  }
}
