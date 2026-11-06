import SwiftUI

/// Settings scene view organizing preferences across General and Models tabs on macOS.
///
/// Tab selection is driven bidirectionally by `Navigator.settingsPath` to support programmatic deep linking.
struct MacSettingsView: View {
  enum Tab: Hashable { case general, models }

  @State var keyModel: APIKeySectionModel
  @State var model: SettingsModel
  @Environment(Navigator.self) private var navigator

  var body: some View {
    TabView(selection: tab) {
      Form { SettingsSections(keyModel: keyModel, model: model) }
        .formStyle(.grouped)
        .tabItem { Label("General", systemImage: "gearshape") }
        .tag(Tab.general)
      ModelsSettingsView(model: model)
        .formStyle(.grouped)
        .tabItem { Label("Models", systemImage: "square.stack.3d.up") }
        .tag(Tab.models)
    }
    .frame(width: 520, height: 600)
    .toast(model.toast, offset: 8)
    .task {
      await model.refreshSizes()
      await model.refreshNotificationStatus()
    }
  }

  private var tab: Binding<Tab> {
    Binding(
      get: { navigator.settingsPath.contains(.models) ? .models : .general },
      set: { navigator.settingsPath = $0 == .models ? [.models] : [] })
  }
}
