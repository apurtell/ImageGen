import SwiftData

/// Schema migration plan defining version history and stage transformations for the persistent store.
enum ImageGenMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}
