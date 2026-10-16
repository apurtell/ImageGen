import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The log view's text as a `.txt` file for Share (D§3.10).
struct LogTextFile: Transferable {
  let text: String
  let date: Date
  var timeZone: TimeZone = .current

  var fileName: String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "ImageGen-log-%04d-%02d-%02d-%02d%02d.txt", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
  }

  /// Writes the file to a fresh temporary folder.
  func write() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(fileName)
    try Data(text.utf8).write(to: url)
    return url
  }

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { file in
      SentTransferredFile(try file.write())
    }
  }
}
