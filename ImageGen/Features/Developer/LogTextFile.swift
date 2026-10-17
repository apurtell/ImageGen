import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The log view's text as a `.txt` file for Share (D§3.10).
///
/// `Transferable` is the system protocol for values that can be shared, dragged or copied. The
/// sheet's `ShareLink` holds one of these. The file is written only when the user picks a share
/// target, not when the sheet opens. A value type with no shared state: the write can run on any
/// thread the system chooses.
struct LogTextFile: Transferable {
  let text: String
  let date: Date
  var timeZone: TimeZone = .current

  /// Like `ImageGen-log-2026-10-16-1402.txt`, in local time. A Gregorian calendar is fixed, so the
  /// name does not depend on the user's calendar setting.
  var fileName: String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "ImageGen-log-%04d-%02d-%02d-%02d%02d.txt", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
  }

  /// Writes the file to a fresh temporary folder. A new folder for each write lets two shares in the
  /// same minute have the same file name without a collision.
  func write() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(fileName)
    try Data(text.utf8).write(to: url)
    return url
  }

  /// One representation: a plain-text file. The closure runs when the share target asks for the
  /// data; a thrown error fails that share.
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { file in
      SentTransferredFile(try file.write())
    }
  }
}
