import Foundation
import Photos

/// The parts of `PHPhotoLibrary` the saver uses; tests substitute a fake.
protocol PhotoLibraryAccess: Sendable {
  /// Asks for add-only access. The system shows its prompt only the first time.
  func requestAddAuthorization() async -> PHAuthorizationStatus
  func addPhoto(fileURL: URL, originalFilename: String) async throws
}

/// The real photo library.
struct SystemPhotoLibrary: PhotoLibraryAccess {
  func requestAddAuthorization() async -> PHAuthorizationStatus {
    await PHPhotoLibrary.requestAuthorization(for: .addOnly)
  }

  /// Adds the original file as is (its bytes and type); never through `UIImage`.
  func addPhoto(fileURL: URL, originalFilename: String) async throws {
    // `performChanges` runs the closure on a queue of the Photos framework and resumes this task when
    // the change is saved. `shouldMoveFile = false` makes Photos copy the file, so our original stays.
    try await PHPhotoLibrary.shared().performChanges {
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = originalFilename
      options.shouldMoveFile = false
      PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: options)
    }
  }
}

/// What the screen shows: `denied` leads to the alert that offers Open Settings (D§4.9).
enum PhotoSaveResult: Equatable, Sendable {
  case saved
  case denied
  case failed(String)
}

/// Save to Photos (D§4.9), logged as one action (D§4.13).
/// `ImageExportModel` calls `save` from a task on the main actor. The two awaits (authorization, then
/// the add) are points where the main thread stays free. The saver holds no state that can change, so
/// it is `Sendable`. Each path writes exactly one Result.
struct PhotoLibrarySaver: Sendable {
  let library: any PhotoLibraryAccess
  let log: ActivityLog

  func save(_ item: ExportItem) async -> PhotoSaveResult {
    let action = log.begin("Save to Photos", origin: .user, "\(item.logDescription)")
    let status = await library.requestAddAuthorization()
    let auth = "authorization \(Self.name(status))"
    guard status == .authorized || status == .limited else {
      log.result(action, .failed, "\(auth) · not saved")
      return .denied
    }
    do {
      try await library.addPhoto(fileURL: item.url, originalFilename: item.suggestedName)
      log.result(action, .success, "\(auth) · saved as \(item.suggestedName)")
      return .saved
    } catch {
      log.result(action, .failed, "\(auth) · \(error.localizedDescription)")
      return .failed(error.localizedDescription)
    }
  }

  static func name(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .authorized: "authorized"
    case .limited: "limited"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "not determined"
    // `@unknown default` handles a status that a later iOS adds.
    @unknown default: "unknown"
    }
  }
}
