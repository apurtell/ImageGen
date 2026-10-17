import SwiftData
import SwiftUI

// The transcript's rows: `MessageRow` picks a `UserBubble` or a `ModelReplyView` and adds the
// message's long-press menu. The rows read SwiftData records (`Message`, `GenerationRequest`)
// directly, on the main actor, from `ChatView`'s queries; SwiftUI redraws a row when a record it
// reads changes. The rows don't call the model: every action goes out through `MessageRowActions`.

/// What a message row asks the chat screen to do. A struct of closures, so the rows depend on no
/// model and previews or tests can pass stubs. `ChatView.rowActions` builds the real one.
@MainActor
struct MessageRowActions {
  var copy: (String, ChatScreenModel.CopyKind) -> Void
  var regenerate: (UUID) -> Void
  var retry: (UUID) -> Void
  var cancel: (UUID) -> Void
  var editRefused: (UUID) -> Void
  var editAndResend: (UUID) -> Void
  var newChat: () -> Void
  var openSettings: () -> Void
  var openModels: () -> Void
  var showInfo: (GenerationRequest) -> Void
  var showDetails: (String) -> Void
  var deleteMessage: (Message) -> Void
  var pin: (UUID) -> Void
  var view: (UUID) -> Void
  var export: (ImageAsset, ImageExportAction) -> Void
  var regenerateUnavailableReason: (GenerationRequest) -> String?
}

/// One transcript row. `request` is the message's request record: for a user message, the request
/// it started; for a reply, the request that produced it. Nil when the record is gone.
struct MessageRow: View {
  let message: Message
  let request: GenerationRequest?
  let isNetworkUnavailable: Bool
  let userMessageExists: Bool
  let actions: MessageRowActions

  var body: some View {
    Group {
      if message.messageRole == .user {
        UserBubble(message: message, request: request, actions: actions)
      } else {
        ModelReplyView(
          message: message, request: request, isNetworkUnavailable: isNetworkUnavailable,
          userMessageExists: userMessageExists, actions: actions)
      }
    }
    .contextMenu {
      MessageSection(message: message, request: request, actions: actions)
    }
  }
}

/// The message's own actions (D§3.6, "Message section"). The row's long-press menu shows them, and so
/// does each image's menu, below the image actions: an image's menu replaces the row's (the inner
/// `contextMenu` wins), so without this an image-only reply would offer no Regenerate, Info or Delete.
struct MessageSection: View {
  let message: Message
  let request: GenerationRequest?
  let actions: MessageRowActions

  var body: some View {
    MessageActionsMenu(
      message: message, request: request,
      regenerateUnavailableReason: request.flatMap(actions.regenerateUnavailableReason),
      onCopy: actions.copy, onRegenerate: { if let r = request { actions.regenerate(r.id) } },
      onInfo: { if let r = request { actions.showInfo(r) } }, onEditAndResend: { actions.editAndResend(message.id) },
      onDelete: { actions.deleteMessage(message) })
  }
}

/// A user message (D§3.4): a right-aligned accent bubble, attachments above the text.
struct UserBubble: View {
  let message: Message
  let request: GenerationRequest?
  let actions: MessageRowActions
  /// The main SwiftData context, which an outer view provides. Used here for one small fetch.
  @Environment(\.modelContext) private var context

  /// The grid's column count from D§3.4: one image full width, two to four in 2 columns, more in 3.
  private var columns: Int {
    switch message.images.count {
    case 0, 1: 1
    case 2...4: 2
    default: 3
    }
  }

  /// The image a pinned or latest send used, for the caption under the bubble.
  private var reusedInput: (reason: SelectionReason, asset: ImageAsset?)? {
    guard let request, let reason = SelectionReason(rawValue: request.selectionReason),
      reason == .pinned || reason == .latest
    else { return nil }
    let id = request.inputs.first?.imageID
    // The reused image belongs to an earlier message, so it is fetched by ID. It can be deleted:
    // the caption then shows without its thumbnail.
    let asset = id.flatMap { id in try? context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { $0.id == id })).first }  // try?: a failed fetch shows no thumbnail
    return (reason, asset)
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      VStack(alignment: .trailing, spacing: 6) {
        if !message.images.isEmpty {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(message.orderedImages) { asset in
              ImageThumbnailView(asset: asset, px: ThumbnailService.listSize, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                  ImageContextMenu(
                onEditFromHere: { actions.pin(asset.id) }, onExport: { actions.export(asset, $0) },
                onView: { actions.view(asset.id) })
                  Section { MessageSection(message: message, request: request, actions: actions) }
                }
            }
          }
          .frame(maxWidth: 260)
        }
        if !message.text.isEmpty {
          Text(message.text)
            .foregroundStyle(.white)
            .textSelection(.enabled)
        }
      }
      .padding(10)
      .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
      if let reused = reusedInput {
        HStack(spacing: 4) {
          if let asset = reused.asset { SquareThumbnail(asset: asset, size: 20, corner: 4) }
          Text(reused.reason == .pinned ? "Edited from pinned image" : "Edited latest image")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(.leading, 48)
  }
}

/// A model reply (D§3.4): parts in order, or the pending card, or the status card.
///
/// The reply message exists from the moment of the send, empty, with its request. So the same row
/// shows the pending card, then the card or the parts, as the request's state changes; SwiftUI
/// redraws it because the row reads `request.requestState`.
struct ModelReplyView: View {
  let message: Message
  let request: GenerationRequest?
  let isNetworkUnavailable: Bool
  let userMessageExists: Bool
  let actions: MessageRowActions

  private var assets: [UUID: ImageAsset] { Dictionary(message.images.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if message.regenerateOfRequestID != nil, let request {
        Text("↻ Regenerated · “\(String(request.promptText.prefix(40)))\(request.promptText.count > 40 ? "…" : "")”")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let request {
        content(request)
      } else {
        parts
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// `@ViewBuilder` lets this function list views and use `switch` and `if` to choose among them;
  /// SwiftUI combines the result into one view (a result builder).
  @ViewBuilder
  private func content(_ request: GenerationRequest) -> some View {
    // All the presentation rules are in `ReplyPresentation`; this view only copies the fields.
    let presentation = ReplyPresentation.make(
      ReplyPresentation.Input(
        state: request.requestState, httpStatus: request.httpStatus, errorStatus: request.errorStatus,
        errorMessage: request.errorMessage, details: request.details, refusalReason: request.refusalReason,
        finishReason: request.finishReason, modelID: request.modelID, aspectRatio: request.aspectRatio,
        imageSize: request.imageSize, userMessageExists: userMessageExists, autoRetriesUsed: request.autoRetriesUsed,
        maxAutoRetries: request.maxAutoRetries, nextAttemptAt: request.nextAttemptAt,
        nextAttemptCreatedInBackground: request.nextAttemptCreatedInBackground, isNetworkUnavailable: isNetworkUnavailable))
    switch presentation {
    case .pending:
      PendingReplyCard(request: request, isNetworkUnavailable: isNetworkUnavailable) { actions.cancel(request.id) }
    case .card(let card):
      ReplyStatusCard(card: card) { button in
        switch button {
        case .retry: actions.retry(request.id)
        case .edit: actions.editRefused(request.id)
        case .newChat: actions.newChat()
        case .settings: actions.openSettings()
        case .openModels: actions.openModels()
        case .details: actions.showDetails(request.details ?? "")
        }
      }
    case .success:
      parts
      if !message.parts.contains(where: { $0.kind == .image }) {
        Label("No image returned", systemImage: "photo.badge.exclamationmark")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(request.notices, id: \.self) { notice in
        Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
      }
      if let finish = request.finishReason, finish != "STOP" {
        Text("Finished: \(finish)").font(.caption).foregroundStyle(.secondary)
      }
      ReplyMetadataLine(request: request)
    }
  }

  /// The reply's parts in the order returned. Identified by position, because a part has no ID of
  /// its own and the list doesn't change order.
  @ViewBuilder
  private var parts: some View {
    ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
      switch part.kind {
      case .text:
        MarkdownView(part.text ?? "")
      case .image:
        if let id = part.imageID, let asset = assets[id] {
          ImageThumbnailView(asset: asset)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contextMenu {
              ImageContextMenu(
                onEditFromHere: { actions.pin(asset.id) }, onExport: { actions.export(asset, $0) },
                onView: { actions.view(asset.id) })
              Section { MessageSection(message: message, request: request, actions: actions) }
            } preview: {
              ImageThumbnailView(asset: asset)
            }
        }
      }
    }
  }
}
