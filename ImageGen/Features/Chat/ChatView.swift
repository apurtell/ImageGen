import SwiftData
import SwiftUI

/// The chat screen (D§3.4): transcript, composer, title (tap to rename) and the chat menu.
struct ChatView: View {
  let conversationID: UUID
  @State private var model: ChatScreenModel
  @Query private var messages: [Message]
  @Query private var requests: [GenerationRequest]
  @State private var renaming = false
  @State private var confirmDeleteChat = false
  @State private var showChatSettings = false
  @State private var infoRequest: GenerationRequest?
  @State private var details: DetailsText?
  @State private var deletingMessage: Message?
  @State private var viewerPlaceholder = false
  @State private var awayFromBottom = false
  @State private var settledLastID: UUID?

  struct DetailsText: Identifiable {
    let id = UUID()
    let text: String
  }

  init(conversationID: UUID, services: ChatServices) {
    self.conversationID = conversationID
    _model = State(initialValue: ChatScreenModel(conversationID: conversationID, services: services))
    _messages = Query(filter: #Predicate<Message> { $0.conversation?.id == conversationID }, sort: \Message.sequence)
    _requests = Query(filter: #Predicate<GenerationRequest> { $0.conversation?.id == conversationID }, sort: \GenerationRequest.createdAt)
  }

  private var requestsByID: [UUID: GenerationRequest] { Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

  /// Changes whenever the transcript's content or a request's state changes.
  private var signature: String {
    "\(messages.count)|" + requests.map { "\($0.id.uuidString.prefix(4))\($0.state)\($0.attempt)" }.joined(separator: ",")
  }

  var body: some View {
    ScrollViewReader { proxy in
      transcript(proxy)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Button { renaming = true } label: {
          Text(model.title).font(.headline).lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rename \(model.title)")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        DeveloperMenu()
        Menu {
          Button("Rename", systemImage: "pencil") { renaming = true }
          Button("Chat settings…", systemImage: "slider.horizontal.3") { showChatSettings = true }
          Button("Delete chat", systemImage: "trash", role: .destructive) { confirmDeleteChat = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Chat menu")
      }
    }
    .renameAlert(isPresented: $renaming, currentTitle: model.title) { name in Task { await model.rename(to: name) } }
    .confirmationDialog("Delete this chat?", isPresented: $confirmDeleteChat, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { Task { await model.deleteChat() } }
    }
    .confirmationDialog(
      "Delete this message?", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let id = deletingMessage?.id { Task { await model.deleteMessage(id) } }
      }
    }
    .confirmationDialog(
      "Replace the current draft?", isPresented: Binding(get: { model.pendingEdit != nil }, set: { if !$0 { model.pendingEdit = nil } }),
      titleVisibility: .visible
    ) {
      Button("Replace Draft", role: .destructive) {
        if let p = model.pendingEdit { Task { await model.editAndResend(userMessageID: p.userMessageID, requestID: p.requestID, confirmed: true) } }
      }
    }
    .alert("Couldn't do that", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.alertMessage ?? "")
    }
    .alert("The image viewer arrives in a later version.", isPresented: $viewerPlaceholder) { Button("OK", role: .cancel) {} }
    .sheet(isPresented: $showChatSettings) { ChatSettingsSheet(model: model) }
    .sheet(item: $infoRequest) { ReplyInfoSheet(request: $0) }
    .sheet(item: $details) { DetailsSheet(text: $0.text) }
    .sensoryFeedback(.impact, trigger: model.sendCount)
    .sensoryFeedback(.success, trigger: model.completedWhileVisible)
    .task { await model.onAppear() }
    .onDisappear { Task { await model.onDisappear() } }
    .onChange(of: signature) { _, _ in Task { await model.reload() } }
  }

  private func transcript(_ proxy: ScrollViewProxy) -> some View {
      ScrollView {
      LazyVStack(spacing: 16) {
        ForEach(messages) { message in
          let request = message.requestID.flatMap { requestsByID[$0] }
          MessageRow(
            message: message, request: request, isNetworkUnavailable: model.showsWaitingForNetwork,
            userMessageExists: userMessageExists(for: request), actions: rowActions)
          .id(message.id)
        }
      }
      .padding(.horizontal)
      .padding(.top, 8)
    }
    .defaultScrollAnchor(.bottom)
    .scrollDismissesKeyboard(.interactively)
    .onScrollGeometryChange(for: Bool.self) { geo in
      geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > geo.containerSize.height
    } action: { _, away in
      awayFromBottom = away
    }
    .overlay(alignment: .bottomTrailing) {
      if awayFromBottom, let last = messages.last {
        Button {
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } label: {
          Image(systemName: "arrow.down").frame(width: 36, height: 36)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .padding()
        .accessibilityLabel("Jump to latest")
      }
    }
    .safeAreaBar(edge: .bottom) {
      ComposerView(model: model)
    }
    .onChange(of: messages.count) { _, _ in
      if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
    }
    .task(id: "\(messages.last?.id.uuidString ?? "")|\(signature)") {
      // Images load after the first layout, and a pending card grows when its reply lands: settle
      // at the bottom. A state change alone doesn't pull back a user who scrolled away.
      let lastID = messages.last?.id
      guard lastID != settledLastID || !awayFromBottom else { return }
      settledLastID = lastID
      for delay in [0.05, 0.35, 0.9] {
        try? await Task.sleep(for: .seconds(delay))
        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  private func userMessageExists(for request: GenerationRequest?) -> Bool {
    guard let request else { return true }
    var current: GenerationRequest? = request
    var hops = 0
    while let r = current, hops < 32 {
      if let user = r.userMessageID { return messages.contains { $0.id == user } }
      current = r.sourceRequestID.flatMap { requestsByID[$0] }
      hops += 1
    }
    return false
  }

  private var rowActions: MessageRowActions {
    let model = self.model
    let files = model.services.files
    return MessageRowActions(
      copy: { text, kind in model.copy(text, kind: kind) },
      regenerate: { id in Task { await model.regenerate(requestID: id) } },
      retry: { id in Task { await model.retry(requestID: id) } },
      cancel: { _ in Task { await model.stop() } },
      editRefused: { id in Task { await model.editRefused(requestID: id) } },
      editAndResend: { id in Task { await model.editAndResend(userMessageID: id) } },
      newChat: { Task { await model.newChat() } },
      openSettings: { model.services.navigator.showSettings = true },
      showInfo: { infoRequest = $0 },
      showDetails: { details = DetailsText(text: $0) },
      deleteMessage: { deletingMessage = $0 },
      pin: { id in Task { await model.pin(id) } },
      view: { _ in viewerPlaceholder = true },
      regenerateUnavailableReason: { request in
        request.inputs.allSatisfy { files.exists(relative: $0.preparedRelativePath) } ? nil : "An input image was deleted"
      })
  }
}
