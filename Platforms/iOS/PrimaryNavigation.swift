import SwiftUI

/// Primary stack navigation host coordinating list presentation and conversation push routing on iOS.
struct PrimaryNavigation: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    @Bindable var navigator = env.navigator
    NavigationStack(path: $navigator.path) {
      ChatListView()
        .navigationDestination(for: UUID.self) { id in
          ChatView(conversationID: id, services: env.chatServices())
            .id(id)
        }
    }
  }
}

/// Presents the application settings interface within a modal sheet.
private struct SettingsSheetPresenter: ViewModifier {
  @Environment(AppEnvironment.self) private var env

  func body(content: Self.Content) -> some View {
    @Bindable var navigator = env.navigator
    content.sheet(isPresented: $navigator.showSettings) {
      SettingsView(keyModel: env.apiKeySectionModel(), model: env.settingsModel())
    }
  }
}

extension View {
  func settingsPresentation() -> some View { modifier(SettingsSheetPresenter()) }
}

/// Settings navigation link row routing to the model catalog configuration view.
struct SettingsModelsRow: View {
  let enabledCount: Int

  var body: some View {
    NavigationLink(value: SettingsPage.models) {
      LabeledContent("Models", value: "\(enabledCount) enabled")
    }
  }
}

/// Container list styling for model catalog settings on iOS.
struct SettingsList<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    List { content }
  }
}

/// Interactive settings action row displaying an asynchronous execution spinner.
struct SettingsProgressButton: View {
  let title: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        if isBusy { ProgressView() }
      }
    }
  }
}

/// Container layout presenting independent settings button items on iOS.
struct SettingsActionRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View { content }
}

/// Row view displaying a configured custom model identifier.
struct CustomModelRow: View {
  let id: String
  let onRemove: () -> Void

  var body: some View {
    Text(id).font(.body.monospaced())
  }
}

/// Informational banner displaying external API credential acquisition URL.
struct APIKeySourceLink: View {
  var body: some View {
    Text("Get a key at aistudio.google.com/apikey")
      .font(.callout.monospaced())
      .textSelection(.enabled)
  }
}
