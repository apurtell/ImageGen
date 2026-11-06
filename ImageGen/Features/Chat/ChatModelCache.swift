import Foundation

/// In-memory cache retaining `ChatScreenModel` instances across view presentation lifecycles.
///
/// Preserves transient composer state—specifically staged uncommitted attachment artifacts—when navigating
/// between conversations. Cached models remain valid until the associated conversation entity is explicitly deleted.
@MainActor
final class ChatModelCache {
  private var models: [UUID: ChatScreenModel] = [:]

  /// Retrieves an existing view model or instantiates and registers a new instance for the specified conversation.
  func model(for conversationID: UUID, services: ChatServices) -> ChatScreenModel {
    if let model = models[conversationID] { return model }
    let model = ChatScreenModel(conversationID: conversationID, services: services)
    models[conversationID] = model
    return model
  }

  /// Invalidates and removes the cached model for the specified conversation, purging uncommitted staging artifacts.
  func remove(_ conversationID: UUID) {
    models.removeValue(forKey: conversationID)?.discardTray()
  }

  func removeAll() {
    for model in models.values { model.discardTray() }
    models = [:]
  }

  /// Flushes pending drafts and executes empty conversation maintenance across all cached view models during termination.
  func saveForTermination() async {
    for model in Array(models.values) { await model.saveForTermination() }
  }
}
