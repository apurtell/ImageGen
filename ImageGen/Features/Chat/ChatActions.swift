import Foundation

/// Encapsulates conversation lifecycle operations shared across the chat list and conversation screens.
///
/// Stateless action dispatcher coordinating data store persistence, asynchronous generation cancellations,
/// structured activity logging, and UI navigation routing. Operations are designed around atomic store
/// transitions to prevent race conditions across concurrent model and UI operations.
@MainActor
struct ChatActions {
  let store: DataStore
  let generation: any GenerationServicing
  let log: ActivityLog
  let navigator: Navigator

  /// Instantiates a new conversation entity within the backing store and records the event.
  func newChat() async -> UUID? {
    let action = log.begin("New chat", origin: .user, "create an empty chat")
    do {
      let id = try await store.createConversation()
      log.result(action, .success, "chat \(Format.short(id))")
      return id
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
      return nil
    }
  }

  /// Updates the conversation display title, permitting persistence fallback to automatic title generation.
  func rename(_ id: UUID, to name: String) async {
    let old = (try? await store.conversationTitle(id)) ?? ""
    let action = log.begin(
      "Rename chat", origin: .user,
      "chat \(Format.short(id)) · \(private: Self.quoted(old)) → \(private: Self.quoted(name.trimmingCharacters(in: .whitespacesAndNewlines)))")
    do {
      try await store.rename(id, to: name)
      let now = (try? await store.conversationTitle(id)) ?? ""
      log.result(action, .success, "done · title now \(private: Self.quoted(now))")
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
    }
  }

  /// Evaluates and cleans up conversations remaining without messages.
  ///
  /// Employs a pre-check to eliminate redundant logging overhead, followed by an atomic store
  /// conditional deletion to guard against concurrent generation or message ingress.
  func discardIfEmpty(_ id: UUID) async {
    guard (try? await store.messageCount(conv: id)) == 0 else { return }
    let action = log.begin("Delete empty chat", origin: .system, "chat \(Format.short(id)) · left with no messages")
    do {
      let deleted = try await store.deleteIfEmpty(id)
      log.result(action, .success, deleted ? "done" : "kept: it has messages now")
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
    }
  }

  /// Cancels in-flight generation requests, cascades conversation and asset deletions, and dismisses active navigation.
  func deleteChat(_ id: UUID) async {
    let title = (try? await store.conversationTitle(id)) ?? ""
    let images = (try? await store.imageCount(conv: id)) ?? 0
    let live = try? await store.liveRequest(conv: id)
    let action = log.begin(
      "Delete chat", origin: .user,
      "chat \(Format.short(id)) · \(private: Self.quoted(title)) · \(images) image\(images == 1 ? "" : "s") · \(live == nil ? "no live request" : "1 live request to cancel")")
    if let live { await generation.cancel(requestID: live.id) }
    do {
      let result = try await store.deleteConversation(id)
      // Cancel generation tasks that may have transitioned after initial state inspection.
      for request in result.liveRequestIDs where request != live?.id { await generation.cancel(requestID: request) }
      let removed = "files removed \(result.filesRemoved) (\(Format.mb(Int(result.bytesFreed))))"
      if result.failures == 0 {
        log.result(action, .success, "done · \(removed)")
      } else {
        log.result(action, .failed, "\(removed) · \(result.failures) failed: \(result.firstError ?? "unknown")")
      }
      navigator.path.removeAll { $0 == id }
    } catch {
      log.result(action, .failed, "\(error.localizedDescription)")
    }
  }

  static func quoted(_ s: String) -> String { "\"\(s)\"" }
}
