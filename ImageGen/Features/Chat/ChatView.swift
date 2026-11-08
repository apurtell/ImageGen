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
  @Environment(\.navigationLayout) private var layout
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
  /// Indicates whether the initial transcript layout and positioning pass has completed.
  @State private var hasSettled = false
  /// Coordinates scroll anchor preservation across container geometry and orientation changes.
  @State private var reflow = TranscriptReflow()
  /// Counter tracking completed container resizes where the scroll viewport remained anchored to the bottom.
  @State private var followedResizes = 0
  /// The transcript's bottom edge is in view, so tail growth should keep it there.
  @State private var isAtBottom = true
  /// Suspends automatic anchoring to the latest message while an earlier row regenerates or while restoring a preserved scroll position.
  @State private var holdingForRetry = false
  /// Tracks user-initiated scroll gestures to coordinate programmatic scroll settling.
  @State private var userScrolling = TranscriptUserScrolling()
  /// Action counter triggering programmatic scroll to the latest transcript message.
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

  /// Request index mapped by identifier, queried across transcript rows to resolve generation parameters.
  private var requestsByID: [UUID: GenerationRequest] { Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

  /// Compound signature reflecting transcript message cardinality and request lifecycle states.
  private var signature: String {
    "\(messages.count)|" + requests.map { "\($0.id.uuidString.prefix(4))\($0.state)\($0.attempt)" }.joined(separator: ",")
  }

  var body: some View {
    dialogs(on: screen)
    .modifier(ImageExportPresenter(model: exporter, toastOffset: 8))
    .viewerCover(item: $viewer) { imageViewer($0) }
    .sheet(isPresented: $showChatSettings) { ChatSettingsSheet(model: model).sheetSizing(minWidth: 420) }
    .sheet(item: $infoRequest) { ReplyInfoSheet(request: $0).sheetSizing(minWidth: 480, minHeight: 520) }
    .sheet(item: $details) { DetailsSheet(text: $0.text).sheetSizing(minWidth: 480, minHeight: 320) }
    .sensoryFeedback(.impact, trigger: model.sendCount)
    .sensoryFeedback(.selection, trigger: model.pinCount)
    .sensoryFeedback(.selection, trigger: model.isEditingTitle) { _, editing in editing }
    .sensoryFeedback(.success, trigger: model.completedWhileVisible)
    .onChange(of: model.completedWhileVisible) { _, _ in Platform.announce("Reply ready") }
    .task { await model.onAppear() }
    .onDisappear(perform: screenDidDisappear)
    .onChange(of: signature) { _, _ in
      reflow.keepRows(Set(messages.map(\.id)))
      // Maintain relative viewport offset when an offscreen regenerated row changes dimensions.
      if holdingForRetry { reflow.holdPlaceForRetry() }
      Task { await model.reload() }
    }
    // Refresh title when modified externally (e.g. from the sidebar).
    .onChange(of: model.services.navigator.titleRevision) { _, _ in Task { await model.reload() } }
  }

  private var screen: some View {
    ScrollViewReader { proxy in
      transcript(proxy)
    }
    .acceptsImageDrops(model)
    .modifier(ChatToolbar(model: model, renaming: $renaming, showChatSettings: $showChatSettings, confirmDeleteChat: $confirmDeleteChat))
    .modifier(commandPublisher)
  }

  private func dialogs(on screen: some View) -> some View {
    screen
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
  }

  private var commandPublisher: ChatCommandPublisher {
    ChatCommandPublisher(model: model) { commandHandle(canSend: $0) }
  }

  /// Preserves current scroll anchor in the view model when undergoing adaptive layout transitions.
  private func screenDidDisappear() {
    if hasSettled { model.placeAcrossRebuild = isAtBottom ? nil : reflow.readersPlace }
    Task { await model.onDisappear() }
  }

  private func imageViewer(_ request: ViewerRequest) -> ImageViewer {
    let (model, conversationID) = (self.model, self.conversationID)
    return ImageViewer(request: request, thumbnails: model.services.thumbnails, log: model.services.log) { id in
      // Ensure navigation returns to the originating conversation if dismissed after selection changes.
      model.services.navigator.open(conversationID)
      Platform.revealChatWindow()
      Task { await model.pin(id) }
    }
  }

  /// Confirmation dialog title customized with associated asset counts where supported.
  private var deleteChatTitle: String {
    // Evaluated on demand during dialog presentation to avoid scanning image faults during standard body evaluations.
    guard confirmDeleteChat, Platform.deleteChatWarning != nil else { return "Delete this chat?" }
    return ChatListView.deleteTitle(imageCount: messages.reduce(0) { $0 + $1.images.count })
  }

  /// Indicates whether a modal sheet, alert, or confirmation dialog is active.
  private var isPresenting: Bool {
    showChatSettings || confirmDeleteChat || renaming || infoRequest != nil || details != nil || deletingMessage != nil
      || model.pendingEdit != nil || model.alertMessage != nil || exporter.isPresenting || model.isPickingAttachment
  }

  /// Generates contextual command dispatch handle reflecting active conversation capabilities.
  private func commandHandle(canSend: Bool) -> ChatCommandHandle {
    let model = self.model
    let actions = rowActions
    let lastReply = messages.last { $0.messageRole == .model }
    let lastPrompt = messages.last { $0.messageRole == .user }
    let lastRequest = lastReply?.requestID.flatMap { requestsByID[$0] }
    let canRegenerate = model.liveRequest == nil && lastRequest.map { actions.regenerateUnavailableReason($0) == nil } == true
    let latestAsset = messages.reversed().lazy.compactMap { $0.orderedImages.last }.first
    return ChatCommandHandle(
      canStop: model.liveRequest != nil, canJumpToLatest: !messages.isEmpty, canSend: canSend,
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

  /// Renders transcript messages within a scrolling stack anchored to the latest message.
  ///
  /// The view only moves on its own to follow the tail: a new last message, or growth of the last rows while
  /// the bottom edge is in view. A row retried further up changes height in place and leaves the position alone.
  private func transcript(_ proxy: ScrollViewProxy) -> some View {
    let requestsByID = self.requestsByID
    let messageIDs = Set(messages.map(\.id))
    let actions = rowActions
    return ScrollView {
      TranscriptStack(spacing: 16) {
        ForEach(messages) { message in
          let request = message.requestID.flatMap { requestsByID[$0] }
          MessageRow(
            message: message, request: request, isNetworkUnavailable: model.showsWaitingForNetwork,
            userMessageExists: userMessageExists(for: request, in: requestsByID, messageIDs: messageIDs), actions: actions)
          .reportsTranscriptRow(id: message.id, to: reflow)
          .id(message.id)
        }
      }
      .padding(.horizontal)
      .padding(.top, 8)
      .scrollBarIndependentColumn(reflow: reflow)
    }
    .transcriptBottomMargin()
    .fillsTranscriptWidth()
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .defaultScrollAnchor(.bottom, for: .alignment)
    .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
    .scrollDismissesKeyboard(.interactively)
    .composerScrollEdge()
    .tracksFirstVisibleRow(in: reflow)
    .onScrollGeometryChange(for: Bool.self) { geo in
      geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > geo.containerSize.height
    } action: { _, away in
      awayFromBottom = away
    }
    .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geo in
      TranscriptScrollMetrics(
        offset: geo.contentOffset.y, topInset: geo.contentInsets.top,
        distanceFromBottom: geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY,
        containerSize: geo.containerSize)
    } action: { _, metrics in
      if let atBottom = reflow.update(metrics: metrics, isFollowingTail: followsTail) { isAtBottom = atBottom }
    }
    .onScrollPhaseChange { _, phase in
      userScrolling.isScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      if userScrolling.isScrolling {
        userScrolling.count += 1
        positionWasMoved()
      }
      if phase == .interacting { holdingForRetry = false }
    }
    .onUserWheelScroll {
      holdingForRetry = false
      userScrolling.lastWheel = .now
      userScrolling.count += 1
      positionWasMoved()
    }
    .overlay(alignment: .bottomTrailing) {
      if layout != .split { jumpToLatestButton(proxy).padding() }
    }
    .safeAreaBar(edge: .bottom) {
      // In split navigation layouts, anchor the Jump button inside the composer accessory row to avoid content overlap.
      ComposerView(model: model) {
        if layout == .split { jumpToLatestButton(proxy) }
      }
      .readableColumn()
      .composerBarSurface()
    }
    .measuresTranscriptViewport { reflow.viewportWillChange(isFollowingTail: followsTail) }
    .onAppear {
      reflow.onEpisodeEnd = { atBottom, followedTail in
        isAtBottom = atBottom
        if followedTail { followedResizes += 1 }
      }
    }
    .onChange(of: jumpRequests) {
      guard let last = messages.last else { return }
      holdingForRetry = false
      positionWasMoved()
      withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
    }
    .task(id: messages.last?.id) {
      // Automatically scroll to newly appended messages, bypassing on initial load unless restoring a historical scroll offset.
      guard let lastID = messages.last?.id, lastID != settledLastID else { return }
      let isFirstLoad = settledLastID == nil
      settledLastID = lastID
      holdingForRetry = false
      positionWasMoved()
      if isFirstLoad, model.services.rebuildsChatOnLayoutChange {
        // Defer scroll restoration if the preceding view model has not yet committed its anchor offset.
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        if let place = model.placeAcrossRebuild, messages.contains(where: { $0.id == place.rowID }) {
          await returnToPlace(place, proxy)
          hasSettled = true
          return
        }
      }
      hasSettled = true
      if !isFirstLoad { withAnimation { proxy.scrollTo(lastID, anchor: .bottom) } }
      await settleAtBottom(proxy) { true }
    }
    .task(id: signature) {
      // A request changing state can resize the last rows: stay with them if the bottom edge is in view.
      guard followsTail else { return }
      await settleAtBottom(proxy) { followsTail }
    }
    .task(id: followedResizes) {
      // Re-anchor scroll viewport after container resize completes to accommodate newly materialized row layouts.
      guard followedResizes > 0, followsTail else { return }
      await settleAtBottom(proxy) { followsTail }
    }
  }

  /// Floating action button navigating directly to the trailing transcript message when scrolled out of view.
  @ViewBuilder
  private func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
    if awayFromBottom, let last = messages.last {
      Button {
        holdingForRetry = false
        positionWasMoved()
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
      } label: {
        Image(systemName: "arrow.down").frame(width: Platform.circleButtonSize, height: Platform.circleButtonSize)
      }
      .chromelessButton()
      .glassEffect(.regular.interactive(), in: .circle)
      .tooltip("Jump to the latest message")
      .accessibilityLabel("Jump to latest")
    }
  }

  /// Invalidates programmatic reflow tracking when user interaction repositions the scroll view.
  private func positionWasMoved() {
    if let atBottom = reflow.positionWasMoved() { isAtBottom = atBottom }
  }

  /// Restores scroll position following adaptive layout reconstruction, retrying across layout frames until target row geometries resolve.
  private func returnToPlace(_ place: TranscriptPlace, _ proxy: ScrollViewProxy) async {
    holdingForRetry = true
    let scrollsAtStart = userScrolling.count
    for delay in [0] + TranscriptSettling.delays {
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard userScrolling.count == scrollsAtStart, !userScrolling.isScrolling else { break }
      // Fall back to identifier-based scrolling when row geometry frames are unavailable.
      if reflow.state.rows[place.rowID] == nil { proxy.scrollTo(place.rowID, anchor: .top) }
      reflow.restore(place)
    }
    holdingForRetry = false
  }

  /// Repeatedly aligns scroll position to accommodate delayed layout passes, aborting if the user initiates manual scrolling.
  private func settleAtBottom(_ proxy: ScrollViewProxy, while shouldContinue: () -> Bool) async {
    let scrollsAtStart = userScrolling.count
    for delay in TranscriptSettling.delays {
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      let stop = TranscriptSettling.shouldStop(
        userScrolled: userScrolling.count != scrollsAtStart, isUserScrolling: userScrolling.isScrolling,
        sinceLastWheel: Date.now.timeIntervalSince(userScrolling.lastWheel))
      guard !stop, shouldContinue(), let last = messages.last else { return }
      if TranscriptSettling.needsScroll(distanceFromBottom: reflow.distanceFromBottom) {
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
  private func userMessageExists(
    for request: GenerationRequest?, in requestsByID: [UUID: GenerationRequest], messageIDs: Set<UUID>
  ) -> Bool {
    guard let request else { return true }
    var current: GenerationRequest? = request
    var hops = 0
    while let r = current, hops < 32 {
      if let user = r.userMessageID { return messageIDs.contains(user) }
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

/// Publishes active conversation commands to the application menu hierarchy.
/// Isolates send validation state to prevent transcript re-evaluations on input text modifications.
private struct ChatCommandPublisher: ViewModifier {
  let model: ChatScreenModel
  let handle: (_ canSend: Bool) -> ChatCommandHandle
  @State private var canSend = false

  func body(content: Self.Content) -> some View {
    content
      .publishesChatCommands(handle(canSend))
      .background(CanSendReader(model: model, canSend: $canSend))
  }
}

private struct CanSendReader: View {
  let model: ChatScreenModel
  @Binding var canSend: Bool

  var body: some View {
    Color.clear.onChange(of: model.canSend, initial: true) { _, new in canSend = new }
  }
}
