import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Transferable file representation of activity log entries exported as plai text files
/// for system share sheet distribution and diagnostics archiving.
struct LogTextFile: Transferable {
  let text: String
  let date: Date
  var timeZone: TimeZone = .current

  /// Formats deterministic timestamped filenames (e.g. `ImageGen-log-YYYY-MM-DD-HHmm.txt`)
  /// using the Gregorian calendar and specified time zone.
  var fileName: String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "ImageGen-log-%04d-%02d-%02d-%02d%02d.txt", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
  }

  /// Serializes formatted log text to an isolated export scratch folder, returning its file URL.
  func write() throws -> URL {
    let url = try ExportScratch.newFolder().appendingPathComponent(fileName)
    try Data(text.utf8).write(to: url)
    return url
  }

  /// Export transfer representation generating on-demand temporary text files upon consumer request.
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { file in
      SentTransferredFile(try file.write())
    }
  }
}
