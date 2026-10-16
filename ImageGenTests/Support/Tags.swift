import Testing

extension Tag {
  /// No I/O.
  @Tag static var pure: Self
  /// Temporary files.
  @Tag static var io: Self
  /// Transport plus store.
  @Tag static var integration: Self
  /// Network; opt-in.
  @Tag static var live: Self
}
