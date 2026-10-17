import Foundation
import SwiftData

/// Builds the SwiftData `ModelContainer` (the database) for `AppEnvironment`, which then gives it to
/// `DataStore`. It runs once at launch. An in-memory store serves tests, and is the fallback when
/// the file cannot be opened. A caseless `enum` is a namespace for static functions.
enum StoreFactory {
  /// The container for `root/default.store`, or an in-memory one.
  static func makeContainer(root: URL, inMemory: Bool) throws -> ModelContainer {
    let schema = Schema(versionedSchema: SchemaV1.self)
    let configuration: ModelConfiguration
    if inMemory {
      configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    } else {
      try FileStore.createDirectory(root)
      configuration = ModelConfiguration(schema: schema, url: root.appendingPathComponent("default.store"))
    }
    // The migration plan lets a later schema version upgrade an existing store file in place.
    return try ModelContainer(for: schema, migrationPlan: ImageGenMigrationPlan.self, configurations: [configuration])
  }
}
