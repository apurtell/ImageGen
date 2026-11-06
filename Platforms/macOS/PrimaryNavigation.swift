import SwiftUI

/// Root split view navigation on macOS, presenting the conversation list alongside the active chat.
///
/// Tracks selected conversations via `Navigator.path`.
struct PrimaryNavigation: View {
  @Environment(AppEnvironment.self) private var env
  @Environment(Navigator.self) private var navigator

  var body: some View {
    NavigationSplitView {
      ChatListView()
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      if let id = navigator.path.last {
        ChatView(conversationID: id, services: env.chatServices())
          .id(id)
      } else {
        ContentUnavailableView {
          Label("No Chat Selected", systemImage: "photo.on.rectangle.angled")
        } description: {
          Text("Choose a chat from the sidebar or start a new one.")
        }
        .navigationTitle("ImageGen")
        .onAppear { navigator.chatTitle = nil }
      }
    }
    .modifier(DeveloperPresenter())
  }
}

/// Presents developer confirmation dialogs requested by menu actions.
private struct DeveloperPresenter: ViewModifier {
  @Environment(DeveloperMenuModel.self) private var model

  func body(content: Self.Content) -> some View {
    @Bindable var model = model
    content
      .confirmationDialog("Clear the activity log?", isPresented: $model.confirmingClear, titleVisibility: .visible) {
        Button("Clear Log", role: .destructive) { Task { await model.clearLog() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Every entry is deleted. This can't be undone.")
      }
  }
}

/// Coordinates opening the settings scene in response to navigation state changes.
private struct SettingsOpener: ViewModifier {
  @Environment(Navigator.self) private var navigator
  @Environment(\.openSettings) private var openSettings

  func body(content: Self.Content) -> some View {
    content.onChange(of: navigator.showSettings, initial: true) { _, show in
      guard show else { return }
      navigator.showSettings = false
      openSettings()
      NSApp.activate()
    }
  }
}

extension View {
  func settingsPresentation() -> some View { modifier(SettingsOpener()) }
}

/// Settings row displaying enabled model counts and routing navigation to the models configuration tab.
struct SettingsModelsRow: View {
  let enabledCount: Int
  @Environment(Navigator.self) private var navigator

  var body: some View {
    LabeledContent("Models") {
      Button("\(enabledCount) enabled") { navigator.settingsPath = [.models] }
        .buttonStyle(.link)
    }
  }
}

/// Form container for model configuration views.
struct SettingsList<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Form { content }
  }
}

/// Action button displaying an inline progress indicator during asynchronous operations.
struct SettingsProgressButton: View {
  let title: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    HStack {
      if isBusy { ProgressView().controlSize(.small) }
      Button(title, action: action)
    }
  }
}

/// Trailing-aligned container for settings action buttons.
struct SettingsActionRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack {
      Spacer()
      content
    }
  }
}

/// Row representing a custom model entry with explicit removal controls.
struct CustomModelRow: View {
  let id: String
  let onRemove: () -> Void

  var body: some View {
    LabeledContent {
      Button("Remove", role: .destructive, action: onRemove)
    } label: {
      Text(id).font(.body.monospaced())
    }
    .contextMenu { Button("Remove", role: .destructive, action: onRemove) }
  }
}

/// Hyperlink navigating to the API key provisioning portal.
struct APIKeySourceLink: View {
  var body: some View {
    Link("Get a key at aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
      .font(.callout)
  }
}
