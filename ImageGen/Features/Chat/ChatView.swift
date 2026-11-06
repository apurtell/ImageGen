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
  /// Viewport width utilized for responsive column constraints.
  @State private var transcriptWidth: CGFloat?
  /// The transcript's bottom edge is in view, so tail growth should keep it there.
  @State private var isAtBottom = true
  /// A row above the tail was retried: it grows in place until the user scrolls or a new tail arrives.
  @State private var holdingForRetry = false
  @State private var isUserScrolling = false
  /// Timestamp of the most recent discrete wheel or trackpad scroll gesture.
  @State private var lastWheelScroll = Date.distantPast
  /// Monotonically increasing user scroll gesture count used to abort programmatic settling.
  @State private var userScrolls = 0
  /// Vertical offset between transcript content extent and visible viewport bottom edge.
  @State private var distanceFromBottom: CGFloat = 0
  /// Trigger counter for animated scroll to the trailing transcript message.
  @State private var jumpRequests = 0

  /// Presentation payload wrapper for arbitrary details text sheets.
  struct DetailsText: Identifiable {
    let id = UUID()
    let text: String
  }

  init(conversationID: UUID, services: ChatServices) {
    self.conversationID = conversationID
    _model = State(
      initialValue: services.chatModels?.model(for: conversationID, services: services)
        ?? ChatScreenModel(conversationID: conversationID, services: services))
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
    .acceptsImageDrops(model)
    .modifier(ChatToolbar(model: model, renaming: $renaming, showChatSettings: $showChatSettings, confirmDeleteChat: $confirmDeleteChat))
    .publishesChatCommands(commandHandle)
    .renameAlert(isPresented: $renaming, currentTitle: model.title) { name in Task { await model.rename(to: name) } }
    .confirmationDialog(deleteChatTitle, isPresented: $confirmDeleteChat, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { Task { await model.deleteChat() } }
    } message: {
      if let warning = Platform.deleteChatWarning { Text(warning) }
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
    .alert(Platform.actionFailedTitle, isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.alertMessage ?? "")
    }
    .modifier(ImageExportPresenter(model: exporter, toastOffset: 8))
    .viewerCover(item: $viewer) { request in
      ImageViewer(request: request, thumbnails: model.services.thumbnails, log: model.services.log) { id in
        // Restore parent conversation navigation context and focus when navigating from detached viewer.
        let navigator = model.services.navigator
        navigator.open(conversationID)
        navigator.requestComposerFocus(for: conversationID)
        Platform.revealChatWindow()
        Task { await model.pin(id) }
      }
    }
    .sheet(isPresented: $showChatSettings) { ChatSettingsSheet(model: model).sheetSizing(minWidth: 420) }
    .sheet(item: $infoRequest) { ReplyInfoSheet(request: $0).sheetSizing(minWidth: 480, minHeight: 520) }
    .sheet(item: $details) { DetailsSheet(text: $0.text).sheetSizing(minWidth: 480, minHeight: 320) }
    .sensoryFeedback(.impact, trigger: model.sendCount)
    .sensoryFeedback(.selection, trigger: model.pinCount)
    .sensoryFeedback(.selection, trigger: model.isEditingTitle) { _, editing in editing }
    .sensoryFeedback(.success, trigger: model.completedWhileVisible)
    .onChange(of: model.completedWhileVisible) { _, _ in Platform.announce("Reply ready") }
    .task { await model.onAppear() }
    .onDisappear { Task { await model.onDisappear() } }
    .onChange(of: signature) { _, _ in Task { await model.reload() } }
    // Invalidate title upon external rename events.
    .onChange(of: model.services.navigator.titleRevision) { _, _ in Task { await model.reload() } }
  }

  /// Confirmation dialog title customized with associated asset counts where supported.
  private var deleteChatTitle: String {
    Platform.deleteChatWarning == nil
      ? "Delete this chat?" : ChatListView.deleteTitle(imageCount: messages.reduce(0) { $0 + $1.images.count })
  }

  /// Indicates whether a modal sheet, alert, or confirmation dialog is active.
  private var isPresenting: Bool {
    showChatSettings || confirmDeleteChat || renaming || infoRequest != nil || details != nil || deletingMessage != nil
      || model.pendingEdit != nil || model.alertMessage != nil
  }

  /// Constructs the focused command dispatch handle exposing conversation actions to platform menus.
  private var commandHandle: ChatCommandHandle {
    let model = self.model
    let actions = rowActions
    let lastReply = messages.last { $0.messageRole == .model }
    let lastPrompt = messages.last { $0.messageRole == .user }
    let lastRequest = lastReply?.requestID.flatMap { requestsByID[$0] }
    let canRegenerate = model.liveRequest == nil && lastRequest.map { actions.regenerateUnavailableReason($0) == nil } == true
    let latestAsset = messages.reversed().lazy.compactMap { $0.orderedImages.last }.first
    return ChatCommandHandle(
      canStop: model.liveRequest != nil, canJumpToLatest: !messages.isEmpty, canSend: model.canSend,
      canAddImages: model.canAddAttachments, isPresenting: isPresenting,
      stop: { Task { await model.stop() } },
      rename: { model.beginTitleEdit() },
      showSettings: { showChatSettings = true },
      delete: { confirmDeleteChat = true },
      jumpToLatest: { jumpRequests += 1 },
      send: { Task { await model.send() } },
      choosePhotos: { model.requestedPicker = .photos },
      chooseFiles: { model.requestedPicker = .files },
      pasteImage: { pasteImage(into: model) },
      regenerateLastReply: canRegenerate ? { if let id = lastRequest?.id { actions.regenerate(id) } } : nil,
      editLastPrompt: lastPrompt.map { prompt in { actions.editAndResend(prompt.id) } },
      lastReplyInfo: lastRequest.map { request in { infoRequest = request } },
      deleteLastMessage: messages.last.map { message in { deletingMessage = message } },
      latestImage: latestAsset.map { asset in
        ChatCommandHandle.LatestImage(
          view: { actions.view(asset.id) }, export: { actions.export(asset, $0) }, editFromHere: { actions.pin(asset.id) })
      })
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
      .readableColumn()
      .scrollBarIndependentWidth(viewport: transcriptWidth)
    }
    .transcriptBottomMargin()
    .measuresScrollViewportWidth($transcriptWidth)
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .defaultScrollAnchor(.bottom, for: .alignment)
    .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
    .scrollDismissesKeyboard(.interactively)
    .composerScrollEdge()
    .onScrollGeometryChange(for: Bool.self) { geo in
      geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > geo.containerSize.height
    } action: { _, away in
      awayFromBottom = away
    }
    .onScrollGeometryChange(for: CGFloat.self) { geo in
      geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY
    } action: { _, distance in
      distanceFromBottom = distance
      isAtBottom = distance < 44
    }
    .onScrollPhaseChange { _, phase in
      isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      if isUserScrolling { userScrolls += 1 }
      if phase == .interacting { holdingForRetry = false }
    }
    .onUserWheelScroll {
      holdingForRetry = false
      lastWheelScroll = .now
      userScrolls += 1
    }
    .overlay(alignment: .bottomTrailing) {
      if awayFromBottom, let last = messages.last {
        Button {
          holdingForRetry = false
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } label: {
          Image(systemName: "arrow.down").frame(width: Platform.circleButtonSize, height: Platform.circleButtonSize)
        }
        .chromelessButton()
        .glassEffect(.regular.interactive(), in: .circle)
        .tooltip("Jump to the latest message")
        .padding()
        .accessibilityLabel("Jump to latest")
      }
    }
    .safeAreaBar(edge: .bottom) {
      ComposerView(model: model).readableColumn().composerBarSurface()
    }
    .providesTranscriptHeight()
    .onChange(of: jumpRequests) {
      guard let last = messages.last else { return }
      holdingForRetry = false
      withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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

  /// Repeatedly aligns scroll position to accommodate delayed layout passes, aborting if the user initiates manual scrolling.
  private func settleAtBottom(_ proxy: ScrollViewProxy, while shouldContinue: () -> Bool) async {
    let scrollsAtStart = userScrolls
    for delay in TranscriptSettling.delays {
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      let stop = TranscriptSettling.shouldStop(
        userScrolled: userScrolls != scrollsAtStart, isUserScrolling: isUserScrolling,
        sinceLastWheel: Date.now.timeIntervalSince(lastWheelScroll))
      guard !stop, shouldContinue(), let last = messages.last else { return }
      if TranscriptSettling.needsScroll(distanceFromBottom: distanceFromBottom) {
        proxy.scrollTo(last.id, anchor: .bottom)
      }
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
    return ViewerRequest(images: images, startID: id, conversationID: conversationID)
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
      exportItem: { exportItem($0, files: files) },
      regenerateUnavailableReason: { request in
        request.inputs.allSatisfy { files.exists(relative: $0.preparedRelativePath) } ? nil : "An input image was deleted"
      })
  }
}
