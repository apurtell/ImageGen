import CoreGraphics
import Foundation

/// Immutable snapshot of transcript scroll viewport geometry and content boundaries.
struct TranscriptScrollMetrics: Equatable {
  /// Vertical scroll offset in platform coordinate space.
  var offset: CGFloat
  /// Vertical inset applied to account for overlapping top navigation chrome.
  var topInset: CGFloat
  /// Vertical distance from the bottom of visible viewport to the trailing content boundary. Negative when content extent is smaller than viewport height.
  var distanceFromBottom: CGFloat
  var containerSize: CGSize

  /// Visible content top coordinate adjusted for navigation chrome insets.
  var visibleTop: CGFloat { offset + topInset }
  var isAtBottom: Bool { distanceFromBottom < 44 }
}

/// Scroll anchor representation binding a visible row identifier to a relative vertical offset, preserving reading context across row dimension changes.
struct TranscriptPlace: Equatable {
  var rowID: UUID
  /// Vertical distance from the target row's top origin to the visible viewport top edge.
  var offsetIntoRow: CGFloat
  /// Reference row height recorded at the time of anchor capture.
  var rowHeight: CGFloat
  /// Governs whether vertical positioning uses absolute points or proportional height ratios.
  /// While proportional offsets preserve visual focus during window resizes, absolute offsets anchor content
  /// when earlier messages regenerate downward, ensuring preceding content remains stationary.
  var holdsRowTop = false

  /// Identifies the uppermost row intersecting the visible viewport given relative content frames.
  static func first(in rows: [UUID: CGRect], visibleTop: CGFloat) -> TranscriptPlace? {
    let visible = rows.filter { $0.value.maxY > visibleTop + 0.5 }
    guard let (id, frame) = visible.min(by: { $0.value.minY < $1.value.minY }), frame.height > 0 else { return nil }
    return TranscriptPlace(rowID: id, offsetIntoRow: visibleTop - frame.minY, rowHeight: frame.height)
  }

  /// Calculates target viewport top coordinate required to restore the anchor position for a given row frame.
  func visibleTop(rowFrame frame: CGRect) -> CGFloat {
    guard !holdsRowTop, offsetIntoRow > 0, rowHeight > 0 else { return frame.minY + offsetIntoRow }
    return frame.minY + offsetIntoRow / rowHeight * frame.height
  }
}

/// Spatial proximity state indicating viewport visibility, observed by row-level image loaders to manage memory allocation independently.
@Observable @MainActor
final class TranscriptRowPresence {
  var isNear = false
}

/// Pure state machine coordinating scroll anchor preservation across dynamic viewport and layout resizing episodes.
///
/// During active resize episodes, geometric shifts can mimic user scrolling (e.g. shrinking viewport height resembling
/// an upward scroll). The state machine locks pre-resize anchoring intent (tail following vs. content row anchor)
/// and continuously computes offset corrections until resizing settles or interactive user scrolling intervenes.
struct TranscriptReflowState {
  /// Vertical prefetch and retention margin beyond viewport bounds for resident image decoding.
  static let presenceMargin: CGFloat = 800

  /// Cached row bounding boxes mapped by message identifier in content coordinate space.
  private(set) var rows: [UUID: CGRect] = [:]
  private(set) var metrics: TranscriptScrollMetrics?
  /// Active scroll anchor reference. Locked during resizing episodes to prevent drift.
  private(set) var place: TranscriptPlace?
  /// Indicates whether the active resize episode is anchored to the trailing edge rather than a specific row anchor.
  private(set) var episodeFollowsTail: Bool?
  /// Preserves row-anchored placement across episodes, preventing incidental bottom proximity resulting from viewport expansion from triggering automatic tail-following.
  private(set) var keepsPlace = false
  /// Indicates that the desired anchor exceeded available content bounds, preserved so subsequent dimension restorations can re-establish the target offset.
  private(set) var placeIsOutOfReach = false
  private var settledOffset: CGFloat?

  var isInEpisode: Bool { episodeFollowsTail != nil }

  /// Initiates a resize episode if not already active, locking tail-following intent from pre-transition state.
  mutating func beginEpisode(isFollowingTail: Bool) {
    guard !isInEpisode else { return }
    episodeFollowsTail = isFollowingTail && !keepsPlace
  }

  /// Initiates an anchor-locking episode prior to row regeneration, freezing top-aligned row geometry.
  mutating func holdPlaceForRetry() {
    beginEpisode(isFollowingTail: false)
    place?.holdsRowTop = true
  }

  /// Ingests updated scroll metrics. Initiates a resize episode upon container dimension changes, returning updated bottom-anchored status when resolved.
  mutating func update(metrics new: TranscriptScrollMetrics, isFollowingTail: Bool) -> Bool? {
    let previous = metrics
    metrics = new
    if let previous, previous.containerSize != new.containerSize { beginEpisode(isFollowingTail: isFollowingTail) }
    guard !isInEpisode else { return nil }
    releaseIfMoved()
    return keepsPlace ? false : new.isAtBottom
  }

  /// Clears preserved anchor state once scroll offset diverges from post-episode coordinates.
  private mutating func releaseIfMoved() {
    guard let metrics, let settledOffset, abs(metrics.offset - settledOffset) > 1 else { return }
    keepsPlace = false
    placeIsOutOfReach = false
  }

  /// Refreshes scroll metrics without triggering state transitions or resize episodes.
  mutating func refresh(metrics new: TranscriptScrollMetrics) {
    metrics = new
  }

  mutating func update(rowID: UUID, frame: CGRect) {
    rows[rowID] = frame
  }

  mutating func keepRows(_ ids: Set<UUID>) {
    rows = rows.filter { ids.contains($0.key) }
  }

  /// Evaluates whether a row bounding box falls within the prefetch and retention margin of the visible viewport.
  func isNear(_ frame: CGRect) -> Bool {
    guard let metrics else { return false }
    let top = metrics.visibleTop - Self.presenceMargin
    return frame.maxY > top && frame.minY < metrics.visibleTop + metrics.containerSize.height + Self.presenceMargin
  }

  /// Evaluates whether layout mutations to the specified row affect active anchor calculations.
  func isPlaceRow(_ id: UUID) -> Bool { place?.rowID == id }

  /// Computes required viewport top alignment to satisfy the active anchor, returning .infinity for trailing edge anchoring or nil if aligned.
  var correction: CGFloat? {
    guard let episodeFollowsTail, let metrics else { return nil }
    if episodeFollowsTail { return metrics.distanceFromBottom > 0.5 ? .infinity : nil }
    guard let place, let frame = rows[place.rowID] else { return nil }
    let wanted = place.visibleTop(rowFrame: frame)
    return abs(wanted - metrics.visibleTop) > 0.5 ? wanted : nil
  }

  /// Captures current scroll anchor from visible row geometry when outside active resize episodes.
  mutating func capturePlace() {
    guard !isInEpisode, let metrics else { return }
    releaseIfMoved()
    guard !placeIsOutOfReach else { return }
    place = TranscriptPlace.first(in: rows, visibleTop: metrics.visibleTop) ?? place
  }

  /// Concludes the active resize episode after geometry quiescence, committing final viewport positioning state.
  mutating func endEpisode() -> Bool? {
    guard let followed = episodeFollowsTail, let metrics else {
      episodeFollowsTail = nil
      return nil
    }
    let wasCorrecting = correction
    episodeFollowsTail = nil
    settledOffset = metrics.offset
    keepsPlace = !followed
    if followed { return true }
    // Unachieved target offset indicates content boundary limits prevented full scroll restoration.
    placeIsOutOfReach = wasCorrecting != nil
    return false
  }

  /// Handles external or user-driven scroll position changes, terminating active resize episodes and releasing cached anchors.
  mutating func positionWasMoved() -> Bool? {
    guard isInEpisode else {
      guard keepsPlace else { return nil }
      keepsPlace = false
      placeIsOutOfReach = false
      return metrics?.isAtBottom
    }
    return cancelEpisode()
  }

  /// Re-establishes a saved scroll anchor following view hierarchy reconstruction.
  mutating func restore(_ place: TranscriptPlace) {
    self.place = place
    beginEpisode(isFollowingTail: false)
  }

  /// Aborts active resize episode in response to external scroll gestures.
  mutating func cancelEpisode() -> Bool? {
    episodeFollowsTail = nil
    keepsPlace = false
    placeIsOutOfReach = false
    capturePlace()
    return metrics?.isAtBottom
  }
}

/// Coordinates TranscriptReflowState execution against host platform scroll view APIs.
/// Maintained as non-observable state to process high-frequency geometry updates without triggering SwiftUI redraw passes.
@MainActor
final class TranscriptReflow {
  /// Quiescence threshold before concluding an active resize episode.
  static let quietPeriod: Duration = .milliseconds(300)

  private(set) var state = TranscriptReflowState()
  private var endEpisodeTask: Task<Void, Never>?
  private var captureIsPending = false
  private var presenceUpdateIsPending = false
  private var presences: [UUID: TranscriptRowPresence] = [:]

  /// Platform scroll dispatch hook positioning the visible content top, or trailing bottom when infinite.
  var scrollTo: ((_ visibleTop: CGFloat, _ topInset: CGFloat) -> Void)?
  /// Platform hook querying authoritative scroll offset and trailing margin directly from underlying scroll view presentation layers.
  var position: (() -> (offset: CGFloat, distanceFromBottom: CGFloat)?)?
  /// Completion callback invoked upon episode termination reporting trailing edge alignment status.
  var onEpisodeEnd: ((_ isAtBottom: Bool, _ followedTail: Bool) -> Void)?

  /// First visible message identifier reported by platform scroll view hierarchies lacking explicit row geometry frames.
  var firstVisibleRow: UUID?

  private var isEnabled: Bool { scrollTo != nil }

  /// Current scroll anchor captured for persistence across view transitions.
  var readersPlace: TranscriptPlace? {
    state.place ?? firstVisibleRow.map { TranscriptPlace(rowID: $0, offsetIntoRow: 0, rowHeight: 0) }
  }

  /// Restores preserved scroll anchor coordinates following view reconstruction.
  func restore(_ place: TranscriptPlace) {
    guard isEnabled else { return }
    state.restore(place)
    scheduleEpisodeEnd()
    correct()
  }

  /// Signals impending container dimension changes, initiating a resize episode.
  func viewportWillChange(isFollowingTail: Bool) {
    guard isEnabled else { return }
    state.beginEpisode(isFollowingTail: isFollowingTail)
    scheduleEpisodeEnd()
    correct()
  }

  /// Anchors scroll position prior to message regeneration to prevent layout jumps from upward dimension growth.
  func holdPlaceForRetry() {
    guard isEnabled else { return }
    state.holdPlaceForRetry()
    scheduleEpisodeEnd()
  }

  /// Synchronizes internal state with native scroll view layout passes, recalculating row proximity and applying episode corrections.
  func scrollViewDidChange() {
    guard isEnabled else { return }
    schedulePresenceUpdate()
    if state.isInEpisode { correct() }
  }

  /// Ingests updated scroll geometry metrics, advancing active episodes or scheduling anchor captures.
  func update(metrics reported: TranscriptScrollMetrics, isFollowingTail: Bool) -> Bool? {
    guard isEnabled else {
      state.refresh(metrics: reported)
      return reported.isAtBottom
    }
    var metrics = reported
    if let position = position?() {
      metrics.offset = position.offset
      metrics.distanceFromBottom = position.distanceFromBottom
    }
    schedulePresenceUpdate()
    let wasInEpisode = state.isInEpisode
    let atBottom = state.update(metrics: metrics, isFollowingTail: isFollowingTail)
    if state.isInEpisode {
      if !wasInEpisode { scheduleEpisodeEnd() }
      correct()
    } else {
      // Schedule anchor capture outside active episodes to reflect potential user scroll repositioning.
      scheduleCapture()
    }
    return atBottom
  }

  /// Updates cached row geometry and evaluates episode corrections if mutating the active anchor row.
  func update(rowID: UUID, frame: CGRect) {
    let isExistingRow = state.rows[rowID] != nil
    state.update(rowID: rowID, frame: frame)
    schedulePresenceUpdate()
    guard isEnabled else { return }
    if state.isInEpisode {
      if state.isPlaceRow(rowID) { correct() }
    } else if isExistingRow || state.place == nil {
      scheduleCapture()
    }
  }

  /// Purges cached geometries and presence trackers for message records no longer present in the transcript.
  func keepRows(_ ids: Set<UUID>) {
    state.keepRows(ids)
    presences = presences.filter { ids.contains($0.key) }
  }

  /// Provides the observable spatial proximity token for a given message row.
  func presence(of id: UUID) -> TranscriptRowPresence {
    if let presence = presences[id] { return presence }
    let presence = TranscriptRowPresence()
    presences[id] = presence
    return presence
  }

  /// Coalesces row presence evaluation into an asynchronous pass per layout or scroll cycle.
  private func schedulePresenceUpdate() {
    guard !presenceUpdateIsPending else { return }
    presenceUpdateIsPending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      presenceUpdateIsPending = false
      refreshPosition()
      for (id, frame) in state.rows {
        let isNear = state.isNear(frame)
        if let presence = presences[id], presence.isNear != isNear { presence.isNear = isNear }
      }
    }
  }

  /// Signals external or interactive scroll repositioning, aborting active episodes.
  func positionWasMoved() -> Bool? {
    if state.isInEpisode { endEpisodeTask?.cancel() }
    return state.positionWasMoved()
  }

  /// Authoritative trailing distance from viewport bottom to content end.
  var distanceFromBottom: CGFloat { position?()?.distanceFromBottom ?? state.metrics?.distanceFromBottom ?? 0 }

  private func refreshPosition() {
    guard var metrics = state.metrics, let position = position?() else { return }
    metrics.offset = position.offset
    metrics.distanceFromBottom = position.distanceFromBottom
    state.refresh(metrics: metrics)
  }

  private func correct() {
    refreshPosition()
    guard let target = state.correction, let metrics = state.metrics else { return }
    scrollTo?(target, metrics.topInset)
  }

  /// Defers anchor capture to the end of the run loop pass to allow layout passes to stabilize.
  private func scheduleCapture() {
    guard !captureIsPending else { return }
    captureIsPending = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      captureIsPending = false
      refreshPosition()
      state.capturePlace()
    }
  }

  private func scheduleEpisodeEnd() {
    endEpisodeTask?.cancel()
    endEpisodeTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: Self.quietPeriod) } catch { return }
      guard let self else { return }
      correct()
      refreshPosition()
      let followed = state.episodeFollowsTail == true
      if let atBottom = state.endEpisode() { onEpisodeEnd?(atBottom, followed) }
      state.capturePlace()
    }
  }
}
