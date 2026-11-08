import SwiftUI

/// Transient progress card representing an in-flight generation request with aspect ratio matched geometry,
/// animated shimmering, elapsed execution duration, and cancellation affordances.
struct PendingReplyCard: View {
  let request: GenerationRequest
  let isNetworkUnavailable: Bool
  let onCancel: () -> Void

  /// Target aspect ratio for placeholder geometry reservation, defaulting to square when unspecified.
  private var aspect: CGFloat {
    guard let pixels = request.aspectRatio.flatMap(AspectRatio.init(rawValue:))?.oneKPixels else { return 1 }
    return CGFloat(pixels.width) / CGFloat(pixels.height)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Reserve identical aspect layout dimensions as the eventual completed image to prevent height shifts on completion.
      shimmer
      .aspectRatio(aspect, contentMode: .fit)
      .overlay {
        TimelineView(.periodic(from: request.startedAt ?? request.createdAt, by: 1)) { context in
          status(at: context.date)
        }
      }
      .clipped()
      .replyImageSizing(aspect: aspect)
      Button("Cancel", systemImage: "xmark.circle", role: .cancel, action: onCancel)
        .font(.callout)
        .replyFooterSizing(expectsText: request.includeTextModality)
    }
  }

  /// Placeholder surface rendering a GPU-driven shimmer animation.
  private var shimmer: some View {
    ZStack {
      RoundedRectangle(cornerRadius: ShimmerAnimation.cornerRadius)
        .fill(.quaternary)
      ShimmerBand(aspect: aspect)
    }
  }

  /// Request status text formatted for compact or standard card heights.
  private func status(at date: Date) -> some View {
    let title = Text("Generating… \(elapsed(at: date))").font(.callout.monospacedDigit())
    let detail = label(at: date).map { Text($0).font(.caption).foregroundStyle(.secondary) }
    return ViewThatFits(in: .vertical) {
      VStack(spacing: 6) {
        title
        detail
      }
      HStack(spacing: 8) {
        title
        detail
      }
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
    .padding(.horizontal, 8)
  }

  /// Formats the elapsed generation duration since request initialization.
  private func elapsed(at date: Date) -> String {
    let start = request.startedAt ?? request.createdAt
    let s = max(0, Int(date.timeIntervalSince(start)))
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  /// Evaluates dynamic contextual status descriptors corresponding to current request execution or retry scheduling.
  private func label(at date: Date) -> String? {
    let input = ReplyPresentation.Input(
      state: request.requestState, modelID: request.modelID, autoRetriesUsed: request.autoRetriesUsed,
      maxAutoRetries: request.maxAutoRetries, nextAttemptAt: request.nextAttemptAt,
      nextAttemptCreatedInBackground: request.nextAttemptCreatedInBackground, isNetworkUnavailable: isNetworkUnavailable,
      now: date)
    if case .pending(let label) = ReplyPresentation.make(input) { return label }
    return nil
  }
}
