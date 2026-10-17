import Foundation
import Photos

/// Abstraction layer decoupling photo library authorization and asset creation routines for testing and isolation.
protocol PhotoLibraryAccess: Sendable {
  /// Requests add-only photo library authorization asynchronously.
  func requestAddAuthorization() async -> PHAuthorizationStatus
  /// Persists a photo asset directly from a local file URL with preserved filename metadata.
  func addPhoto(fileURL: URL, originalFilename: String) async throws
}

/// Concrete adapter delegating asset storage operations to `PHPhotoLibrary`.
struct SystemPhotoLibrary: PhotoLibraryAccess {
  func requestAddAuthorization() async -> PHAuthorizationStatus {
    await PHPhotoLibrary.requestAuthorization(for: .addOnly)
  }

  /// Persists the original image asset to the Photos library preserving pristine binary bytes and file extension.
  func addPhoto(fileURL: URL, originalFilename: String) async throws {
    // Stage asset creation within the Photos framework transaction, copying the source file.
    try await PHPhotoLibrary.shared().performChanges {
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = originalFilename
      options.shouldMoveFile = false
      PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: options)
    }
  }
}

/// Terminal disposition outcomes for photo library export operations.
enum PhotoSaveResult: Equatable, Sendable {
  case saved
  case denied
  case failed(String)
}

/// Coordinates photo library permission validation, asset creation, and diagnostic telemetry logging.
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
