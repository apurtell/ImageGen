import Foundation

/// Formatting utilities standardizing telemetry representations for byte quantities, durations,
/// truncated identifiers, media types, and network error codes.
enum Format {
  /// Formats byte quantities into mebibytes (2^20 bytes) with single-decimal precision.
  static func mb(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }

  /// Formats a `Duration` value into decimal seconds with tenths precision.
  static func seconds(_ d: Duration) -> String {
    let c = d.components
    return String(format: "%.1f s", Double(c.seconds) + Double(c.attoseconds) / 1e18)
  }

  /// Returns the leading four hexadecimal characters of a UUID for concise logging.
  static func short(_ id: UUID) -> String {
    String(id.uuidString.lowercased().prefix(4))
  }

  /// Maps image MIME type identifiers to canonical display labels.
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

  /// Assembles a compound description string containing dimensions, format label, and payload size.
  static func image(width: Int, height: Int, mimeType: String, bytes: Int) -> String {
    "\(width)×\(height) \(type(mimeType)) \(mb(bytes))"
  }

  /// Translates standard `URLError.Code` cases to readable symbolic names.
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
