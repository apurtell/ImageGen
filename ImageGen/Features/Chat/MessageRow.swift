import SwiftData
import SwiftUI

/// Action delegate dispatch table providing decoupled handling for transcript row interactions.
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

/// Transcript row view dispatching presentation to user prompt or assistant reply layouts.
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

/// Context menu section exposing message-level commands for message rows and nested image attachments.
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

/// Renders a user prompt message bubble with optional attachment thumbnails and provenance annotations.
struct UserBubble: View {
  let message: Message
  let request: GenerationRequest?
  let actions: MessageRowActions
  @Environment(\.modelContext) private var context

  private var columns: Int {
    switch message.images.count {
    case 0, 1: 1
    case 2...4: 2
    default: 3
    }
  }

  /// Evaluates referenced input image provenance for contextual subtitle presentation.
  private var reusedInput: (reason: SelectionReason, asset: ImageAsset?)? {
    guard let request, let reason = SelectionReason(rawValue: request.selectionReason),
      reason == .pinned || reason == .latest
    else { return nil }
    let id = request.inputs.first?.imageID
    let asset = id.flatMap { id in try? context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { $0.id == id })).first }
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

/// Renders model responses across pending generation, terminal error cards, and successful multipart payloads.
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

  @ViewBuilder
  private func content(_ request: GenerationRequest) -> some View {
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

  /// Sequence of received content parts rendered in ordinal arrival sequence.
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
