import SwiftData

/// The list of schema versions and the steps between them (D§4.3). There is one version, so there are
/// no stages yet. A `SchemaV2` adds itself to `schemas` and one `MigrationStage` here.
enum ImageGenMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
  static var stages: [MigrationStage] { [] }
}
