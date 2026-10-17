import Testing

extension Tag {
  /// Fast, in-memory tests executing without disk or network I/O.
  @Tag static var pure: Self
  /// File-backed tests operating on isolated temporary file trees.
  @Tag static var io: Self
  /// End-to-end integration tests exercising combined store, transport, and pipeline layers.
  @Tag static var integration: Self
  /// Live network tests requiring explicit external API credentials.
  @Tag static var live: Self
}
