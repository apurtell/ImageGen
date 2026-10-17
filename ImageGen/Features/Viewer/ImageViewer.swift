import SwiftUI

/// An immutable, sendable representation of an image presented within the full screen viewer, encapsulating
/// export metadata, origin provenance, and request generation parameters.
struct ViewerImage: Identifiable, Equatable, Sendable {
  let item: ExportItem
  let origin: ImageOrigin
  /// Generation configuration associated with the image request, when applicable.
  let settings: EffectiveSettings?

  var id: UUID { item.id }

  var sourceDescription: String {
    switch origin {
    case .model: "Generated"
    case .photos: "Photos"
    case .files: "Files"
    case .paste: "Pasted"
    }
  }
}

/// Presentation payload supplied to initiate the full-screen viewer, specifying the collection of images
/// associated with a message and the initial selection identifier.
struct ViewerRequest: Identifiable {
  let images: [ViewerImage]
  let startID: UUID
  var id: UUID { startID }
}

/// Full-screen image viewer supporting horizontal paging across message assets, interactive pinch and double-tap
/// zooming, dismiss gestures, and contextual export actions.
///
/// Hosted as a modal presentation over the chat interface. Each image is rendered in an isolated zoomable
/// container that coordinates progressive loading from local thumbnails to full-resolution decodes. The viewer
/// encapsulates its own export state machine to present system share sheets directly above the immersive canvas.
struct ImageViewer: View {
  let request: ViewerRequest
  let thumbnails: ThumbnailService
  let onEditFromHere: (UUID) -> Void
  @State private var exporter: ImageExportModel
  /// Active page identifier driving pager selection and tracking across layout transitions.
  @State private var current: UUID
  @State private var showsChrome = true
  /// Active image payload currently presented in the detailed inspection sheet.
  @State private var info: ViewerImage?
  @Environment(\.dismiss) private var dismiss

  init(request: ViewerRequest, thumbnails: ThumbnailService, log: ActivityLog, onEditFromHere: @escaping (UUID) -> Void) {
    self.request = request
    self.thumbnails = thumbnails
    self.onEditFromHere = onEditFromHere
    // Initialize state-backed export model and initial page selection.
    _exporter = State(initialValue: ImageExportModel(log: log))
    _current = State(initialValue: request.startID)
  }

  /// Resolved image corresponding to the active selection, falling back to the initial asset.
  private var currentImage: ViewerImage? { request.images.first { $0.id == current } ?? request.images.first }
  private var position: Int { (request.images.firstIndex { $0.id == current } ?? 0) + 1 }

  var body: some View {
    GeometryReader { geo in
      pager
        // Recreate the paging hierarchy when geometry changes across interface orientation shifts,
        // preventing stale container frame calculations while relying on cache retention for decoded bitmaps.
        .id("\(Int(geo.size.width))x\(Int(geo.size.height))")
    }
    .ignoresSafeArea()
    .background(Color.black.ignoresSafeArea())
    .overlay(alignment: .top) {
      if showsChrome { topBar.transition(.opacity) }
    }
    .overlay(alignment: .bottom) {
      if showsChrome, let image = currentImage {
        ViewerToolbar(
          onExport: { exporter.perform($0, image.item) },
          // Stage the selected asset into the composer attachment context and dismiss the viewer.
          onEditFromHere: {
            onEditFromHere(image.id)
            dismiss()
          },
          onInfo: { info = image }
        )
        .padding(.bottom, 8)
        .transition(.opacity)
      }
    }
    .statusBarHidden(!showsChrome)
    // Coordinate dismissal of secondary presentation sheets when dismissing the viewer hierarchy.
    .modifier(ImageExportPresenter(model: exporter, toastOffset: 64))
    .sheet(item: $info) { ViewerInfoSheet(image: $0) }
    // Evict cached high-resolution decoded representations upon dismissing the viewer hierarchy.
    .onDisappear { Task { await FullDecoder.shared.clear() } }
    .preferredColorScheme(.dark)
  }

  private var pager: some View {
    TabView(selection: $current) {
      ForEach(request.images) { image in
        // Notify the target page view of active selection status to reset zoom levels when paged out.
        ZoomableImageView(
          image: image, thumbnails: thumbnails, isCurrent: image.id == current,
          onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() } },
          onDismiss: { dismiss() }
        )
        .ignoresSafeArea()
        .tag(image.id)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
  }

  private var topBar: some View {
    HStack {
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
      }
      .glassEffect(.regular.interactive(), in: .circle)
      .accessibilityLabel("Close")
      Spacer()
      if request.images.count > 1 {
        Text("\(position) of \(request.images.count)")
          .font(.subheadline.monospacedDigit())
          .padding(.horizontal, 12).padding(.vertical, 8)
          .glassEffect()
          .accessibilityLabel("Image \(position) of \(request.images.count)")
      }
    }
    .padding(.horizontal)
  }
}

/// Detailed asset metadata inspector displaying dimensions, encoding MIME type, payload size, source provenance,
/// and model inference configurations.
struct ViewerInfoSheet: View {
  let image: ViewerImage
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        LabeledContent("Pixel size", value: "\(image.item.pixelWidth)×\(image.item.pixelHeight)")
        LabeledContent("Type", value: image.item.mimeType)
        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(image.item.byteCount), countStyle: .file))
        LabeledContent("Source", value: image.sourceDescription)
        if let s = image.settings {
          LabeledContent("Model", value: ModelCatalog.descriptor(for: s.modelID).displayName)
          LabeledContent("Aspect", value: s.aspectRatio?.rawValue ?? "omitted")
          LabeledContent("Resolution", value: s.imageSize?.rawValue ?? "omitted")
        }
        LabeledContent("File name", value: image.item.suggestedName)
      }
      .navigationTitle("Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .presentationDetents([.medium])
  }
}
