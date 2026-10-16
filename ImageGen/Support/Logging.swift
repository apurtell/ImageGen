import Foundation
import OSLog

/// OSLog categories (D§7). From M2 on the activity log mirrors every entry through these; other
/// code logs through `ActivityLog`, except DEBUG-only diagnostics and the smoke test.
enum Log {
  static let subsystem = Bundle.main.bundleIdentifier ?? "com.andrewpurtell.imagegen"

  static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
  static let transport = Logger(subsystem: subsystem, category: "transport")
  static let store = Logger(subsystem: subsystem, category: "store")
  static let imaging = Logger(subsystem: subsystem, category: "imaging")
  static let smoke = Logger(subsystem: subsystem, category: "smoke")
}
