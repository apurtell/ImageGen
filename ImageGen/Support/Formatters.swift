import Foundation

/// The activity log's conventions (D§4.13 Messages).
/// Callers use these to build `ActivityMessage` text, so every message spells sizes, durations and
/// IDs the same way. Pure functions, callable from any thread or actor.
enum Format {
  /// "1.3 MB": megabytes (2^20) with one decimal.
  static func mb(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  /// "14.2 s"
  /// `Duration` stores whole seconds plus attoseconds (10^-18 s).
  static func seconds(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.1f s", Double(c.seconds) + Double(c.attoseconds) / 1e18)
  }

  /// The first four hex digits of a UUID: "img 7f3a".
  static func short(_ id: UUID) -> String {
    String(id.uuidString.lowercased().prefix(4))
  }

  /// "PNG", "JPEG" from a MIME type.
  static func type(_ mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/jpeg": "JPEG"
    case "image/png": "PNG"
    case "image/heic": "HEIC"
    case "image/heif": "HEIF"
    case "image/webp": "WebP"
    case "image/gif": "GIF"
    default: mimeType
    }
  }

  /// "2752×1536 PNG 6.4 MB"
  static func image(width: Int, height: Int, mimeType: String, bytes: Int) -> String {
    "\(width)×\(height) \(type(mimeType)) \(mb(bytes))"
  }

  /// A readable `URLError` code name. The type has no name text of its own; a code not listed here
  /// shows its number.
  static func urlError(_ code: URLError.Code) -> String {
    switch code {
    case .timedOut: "timedOut"
    case .notConnectedToInternet: "notConnectedToInternet"
    case .networkConnectionLost: "networkConnectionLost"
    case .cannotConnectToHost: "cannotConnectToHost"
    case .cannotFindHost: "cannotFindHost"
    case .dnsLookupFailed: "dnsLookupFailed"
    case .secureConnectionFailed: "secureConnectionFailed"
    case .cancelled: "cancelled"
    case .badURL: "badURL"
    case .badServerResponse: "badServerResponse"
    case .resourceUnavailable: "resourceUnavailable"
    case .dataNotAllowed: "dataNotAllowed"
    case .internationalRoamingOff: "internationalRoamingOff"
    default: "URLError \(code.rawValue)"
    }
  }
}
