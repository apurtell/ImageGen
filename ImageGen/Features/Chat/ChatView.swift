import SwiftData
import SwiftUI

/// Primary conversation screen presenting the message transcript, prompt composer, and header controls.
///
/// Architectural Design:
/// Integrates live SwiftData queries (`@Query`) for real-time transcript streaming with an observable
/// view model (`ChatScreenModel`) governing interaction mechanics, generation pipelines, and composer state.
/// An aggregated content signature observes record mutations to trigger model snapshot refreshes.
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
  @State private var viewer: ViewerRequest?
  @State private var exporter: ImageExportModel
  @State private var awayFromBottom = false
  @State private var settledLastID: UUID?
  /// The transcript's bottom edge is in view, so tail growth should keep it there.
  @State private var isAtBottom = true
  /// A row above the tail was retried: it grows in place until the user scrolls or a new tail arrives.
  @State private var holdingForRetry = false
  @State private var isUserScrolling = false

  /// Presentation payload wrapper for arbitrary details text sheets.
  struct DetailsText: Identifiable {
    let id = UUID()
    let text: String
  }

  init(conversationID: UUID, services: ChatServices) {
    self.conversationID = conversationID
    _model = State(initialValue: ChatScreenModel(conversationID: conversationID, services: services))
    _exporter = State(initialValue: ImageExportModel(log: services.log))
    _messages = Query(filter: #Predicate<Message> { $0.conversation?.id == conversationID }, sort: \Message.sequence)
    _requests = Query(filter: #Predicate<GenerationRequest> { $0.conversation?.id == conversationID }, sort: \GenerationRequest.createdAt)
  }

  private var requestsByID: [UUID: GenerationRequest] { Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

  /// Compound signature reflecting transcript message cardinality and request lifecycle states.
  private var signature: String {
    "\(messages.count)|" + requests.map { "\($0.id.uuidString.prefix(4))\($0.state)\($0.attempt)" }.joined(separator: ",")
  }

  var body: some View {
    ScrollViewReader { proxy in
      transcript(proxy)
    }
    .inlineNavigationTitle()
    .toolbar {
      ToolbarItem(placement: .principal) {
        // The in-place title edit replaces the title while `model.titleDraft` is non-nil.
        if model.isEditingTitle {
          InlineTitleField(
            text: Binding(get: { model.titleDraft ?? "" }, set: { model.titleDraft = $0 }),
            onSave: { Task { await model.commitTitleEdit() } }, onCancel: { model.cancelTitleEdit() }
          )
          .frame(width: 210)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .glassEffect(.regular.interactive(), in: .capsule)
        } else {
          Text(model.title).font(.headline).lineLimit(1)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.4) { model.beginTitleEdit() }
            .onTapGesture { renaming = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Rename \(model.title)")
            .accessibilityAction(named: "Edit title in place") { model.beginTitleEdit() }
        }
      }
      ToolbarItemGroup(placement: .trailingBar) {
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
    .modifier(ImageExportPresenter(model: exporter, toastOffset: 8))
    .viewerCover(item: $viewer) { request in
      ImageViewer(request: request, thumbnails: model.services.thumbnails, log: model.services.log) { id in
        Task { await model.pin(id) }
      }
    }
    .sheet(isPresented: $showChatSettings) { ChatSettingsSheet(model: model) }
    .sheet(item: $infoRequest) { ReplyInfoSheet(request: $0) }
    .sheet(item: $details) { DetailsSheet(text: $0.text) }
    .sensoryFeedback(.impact, trigger: model.sendCount)
    .sensoryFeedback(.selection, trigger: model.pinCount)
    .sensoryFeedback(.selection, trigger: model.isEditingTitle) { _, editing in editing }
    .sensoryFeedback(.success, trigger: model.completedWhileVisible)
    .task { await model.onAppear() }
    .onDisappear { Task { await model.onDisappear() } }
    .onChange(of: signature) { _, _ in Task { await model.reload() } }
  }

  /// Whether height changes should keep the bottom edge still. Otherwise the top of the visible rows stays still.
  private var followsTail: Bool { isAtBottom && !holdingForRetry }

  /// Renders transcript messages within a lazily stacked scrolling view anchored to the latest message.
  ///
  /// The view only moves on its own to follow the tail: a new last message, or growth of the last rows while
  /// the bottom edge is in view. A row retried further up changes height in place and leaves the position alone.
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
      .scrollTargetLayout()
      .padding(.horizontal)
      .padding(.top, 8)
    }
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .defaultScrollAnchor(.bottom, for: .alignment)
    .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
    .scrollDismissesKeyboard(.interactively)
    .onScrollGeometryChange(for: Bool.self) { geo in
      geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > geo.containerSize.height
    } action: { _, away in
      awayFromBottom = away
    }
    .onScrollGeometryChange(for: CGFloat.self) { geo in
      geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY
    } action: { _, distance in
      isAtBottom = distance < 44
    }
    .onScrollPhaseChange { _, phase in
      isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      if phase == .interacting { holdingForRetry = false }
    }
    .overlay(alignment: .bottomTrailing) {
      if awayFromBottom, let last = messages.last {
        Button {
          holdingForRetry = false
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
    .task(id: messages.last?.id) {
      // A new last message scrolls to it. Skipped on first load, which starts at the bottom already.
      guard let lastID = messages.last?.id, lastID != settledLastID else { return }
      let isFirstLoad = settledLastID == nil
      settledLastID = lastID
      holdingForRetry = false
      if !isFirstLoad { withAnimation { proxy.scrollTo(lastID, anchor: .bottom) } }
      await settleAtBottom(proxy) { true }
    }
    .task(id: signature) {
      // A request changing state can resize the last rows: stay with them if the bottom edge is in view.
      guard followsTail else { return }
      await settleAtBottom(proxy) { followsTail }
    }
  }

  /// Re-aligns to the bottom a few times to absorb delayed image layout, leaving the position to any scroll the user starts.
  private func settleAtBottom(_ proxy: ScrollViewProxy, while shouldContinue: () -> Bool) async {
    for delay in [0.05, 0.35, 0.9] {
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard !isUserScrolling, shouldContinue(), let last = messages.last else { return }
      proxy.scrollTo(last.id, anchor: .bottom)
    }
  }

  private func exportItem(_ asset: ImageAsset, files: FileStore) -> ExportItem {
    ExportItem(
      id: asset.id, url: files.url(relative: asset.relativePath), mimeType: asset.mimeType, byteCount: asset.byteCount,
      pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, createdAt: asset.createdAt)
  }

  /// Builds a viewer presentation request containing ordered image assets and recorded settings for the target message.
  private func viewerRequest(startingAt id: UUID) -> ViewerRequest? {
    guard let message = messages.first(where: { $0.images.contains { $0.id == id } }) else { return nil }
    let files = model.services.files
    let settings = message.requestID.flatMap { requestsByID[$0] }?.recordedSettings
    let images = message.orderedImages.map {
      ViewerImage(item: exportItem($0, files: files), origin: $0.imageOrigin, settings: settings)
    }
    return ViewerRequest(images: images, startID: id)
  }

  /// Verifies existence of the originating prompt message, traversing ancestor request records when evaluating regenerations.
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

  /// Configures message row action handlers delegating to the view model and export coordinator.
  private var rowActions: MessageRowActions {
    let model = self.model
    let files = model.services.files
    return MessageRowActions(
      copy: { text, kind in model.copy(text, kind: kind) },
      regenerate: { id in Task { await model.regenerate(requestID: id) } },
      retry: { id in
        if messages.last?.requestID != id { holdingForRetry = true }
        Task { await model.retry(requestID: id) }
      },
      cancel: { _ in Task { await model.stop() } },
      editRefused: { id in Task { await model.editRefused(requestID: id) } },
      editAndResend: { id in Task { await model.editAndResend(userMessageID: id) } },
      newChat: { Task { await model.newChat() } },
      openSettings: { model.services.navigator.openSettings() },
      openModels: { model.services.navigator.openSettings(.models) },
      showInfo: { infoRequest = $0 },
      showDetails: { details = DetailsText(text: $0) },
      deleteMessage: { deletingMessage = $0 },
      pin: { id in Task { await model.pin(id) } },
      view: { id in viewer = viewerRequest(startingAt: id) },
      export: { asset, action in exporter.perform(action, exportItem(asset, files: files)) },
      regenerateUnavailableReason: { request in
        request.inputs.allSatisfy { files.exists(relative: $0.preparedRelativePath) } ? nil : "An input image was deleted"
      })
  }
}
