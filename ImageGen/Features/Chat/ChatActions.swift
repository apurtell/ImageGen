import Foundation

/// Chat-level actions shared by the chat list and the chat screen, each logged (D§4.13).
@MainActor
struct ChatActions {
  let store: DataStore
  let generation: any GenerationServicing
  let log: ActivityLog
  let navigator: Navigator

  /// Creates an empty chat; the caller decides how to navigate to it.
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

  /// Deletes a chat left with no messages (D§3.3). Logged only when there's something to delete.
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

  /// Cancels the chat's live request first, then deletes it and its files.
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
