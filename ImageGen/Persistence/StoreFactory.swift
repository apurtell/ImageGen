import Foundation
import SwiftData

/// Factory initializing the persistent SwiftData `ModelContainer` configured with schema migration rules.
enum StoreFactory {
  /// Instantiates a persistent disk backed or ephemeral in-memory container configuration.
  static func makeContainer(root: URL, inMemory: Bool) throws -> ModelContainer {
    let schema = Schema(versionedSchema: SchemaV1.self)
    let configuration: ModelConfiguration
    if inMemory {
      configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    } else {
      try FileStore.createDirectory(root)
      configuration = ModelConfiguration(schema: schema, url: root.appendingPathComponent("default.store"))
    }
    return try ModelContainer(for: schema, migrationPlan: ImageGenMigrationPlan.self, configurations: [configuration])
  }
}
