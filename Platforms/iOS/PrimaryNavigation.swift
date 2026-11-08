import SwiftUI

/// Root adaptive navigation controller coordinating between hierarchical stack and split-view presentations on iOS.
///
/// Both layouts synchronize active conversation state through `Navigator.path`. During size class transitions on iPad,
/// underlying conversation state, drafts, and scroll anchors are preserved via `ChatModelCache` and view model caches,
/// while modal image viewers remain presented above navigation boundaries.
struct PrimaryNavigation: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Bindable private var viewers = ViewerCoverController.shared

  private var layout: NavigationLayout {
    NavigationLayout.choose(isPad: Platform.isPad, isRegularWidth: sizeClass == .regular)
  }

  var body: some View {
    Group {
      switch layout {
      case .stack: StackNavigation()
      case .split: SplitNavigation()
      }
    }
    .environment(\.navigationLayout, layout)
    .fullScreenCover(item: $viewers.cover) { $0.content }
  }
}

/// Global presentation controller managing full-window image viewer presentations independent of adaptive layout rebuilds.
@Observable @MainActor
final class ViewerCoverController {
  struct Cover: Identifiable {
    let id = UUID()
    let content: AnyView
  }

  static let shared = ViewerCoverController()
  var cover: Cover?

  func show(_ content: AnyView) { cover = Cover(content: content) }
}

extension Navigator {
  /// Indicates whether active modal presentations (such as Settings or Image Viewer) obscure the primary conversation.
  var isChatCovered: Bool { showSettings || ViewerCoverController.shared.cover != nil }
}

/// Hierarchical single-column navigation stack presentation.
private struct StackNavigation: View {
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

/// Multi-column split navigation presentation displaying conversation list sidebar alongside active detail conversation.
private struct SplitNavigation: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    NavigationSplitView {
      ChatListView()
    } detail: {
      if let id = env.navigator.path.last {
        ChatView(conversationID: id, services: env.chatServices())
          .id(id)
      } else {
        ContentUnavailableView {
          Label("No Chat Selected", systemImage: "photo.on.rectangle.angled")
        } description: {
          Text("Choose a chat from the sidebar or start a new one.")
        }
        .toolbar {
          ToolbarItem(placement: .trailingBar) { DeveloperMenu() }
        }
      }
    }
  }
}

/// View modifier managing modal presentation of application settings.
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
