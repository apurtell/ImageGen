import Foundation
import Photos

/// The parts of `PHPhotoLibrary` the saver uses; tests substitute a fake.
protocol PhotoLibraryAccess: Sendable {
  func requestAddAuthorization() async -> PHAuthorizationStatus
  func addPhoto(fileURL: URL, originalFilename: String) async throws
}

struct SystemPhotoLibrary: PhotoLibraryAccess {
  func requestAddAuthorization() async -> PHAuthorizationStatus {
    await PHPhotoLibrary.requestAuthorization(for: .addOnly)
  }

  /// Adds the original file as is (its bytes and type); never through `UIImage`.
  func addPhoto(fileURL: URL, originalFilename: String) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = originalFilename
      options.shouldMoveFile = false
      PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: options)
    }
  }
}

enum PhotoSaveResult: Equatable, Sendable {
  case saved
  case denied
  case failed(String)
}

/// Save to Photos (D§4.9), logged as one action (D§4.13).
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
    @unknown default: "unknown"
    }
  }
}
