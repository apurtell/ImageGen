import SwiftUI

/// An image in the viewer, with what its Info shows (D§3.7).
struct ViewerImage: Identifiable, Equatable, Sendable {
  let item: ExportItem
  let origin: ImageOrigin
  /// The settings of the request the image belongs to, when known.
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

/// What opens the viewer: the images of one message and the one to show first.
struct ViewerRequest: Identifiable {
  let images: [ViewerImage]
  let startID: UUID
  var id: UUID { startID }
}

/// The full-screen viewer (D§3.7): pages through a message's images, each zoomable; a single tap
/// toggles the chrome; ✕ or a downward swipe at the minimum zoom dismisses.
struct ImageViewer: View {
  let request: ViewerRequest
  let thumbnails: ThumbnailService
  let onEditFromHere: (UUID) -> Void
  @State private var exporter: ImageExportModel
  @State private var current: UUID
  @State private var showsChrome = true
  @State private var info: ViewerImage?
  @Environment(\.dismiss) private var dismiss

  init(request: ViewerRequest, thumbnails: ThumbnailService, log: ActivityLog, onEditFromHere: @escaping (UUID) -> Void) {
    self.request = request
    self.thumbnails = thumbnails
    self.onEditFromHere = onEditFromHere
    _exporter = State(initialValue: ImageExportModel(log: log))
    _current = State(initialValue: request.startID)
  }

  private var currentImage: ViewerImage? { request.images.first { $0.id == current } ?? request.images.first }
  private var position: Int { (request.images.firstIndex { $0.id == current } ?? 0) + 1 }

  var body: some View {
    TabView(selection: $current) {
      ForEach(request.images) { image in
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
    .background(Color.black.ignoresSafeArea())
    .ignoresSafeArea()
    .overlay(alignment: .top) {
      if showsChrome { topBar.transition(.opacity) }
    }
    .overlay(alignment: .bottom) {
      if showsChrome, let image = currentImage {
        ViewerToolbar(
          onExport: { exporter.perform($0, image.item) },
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
    .modifier(ImageExportPresenter(model: exporter, toastOffset: 64))
    .sheet(item: $info) { ViewerInfoSheet(image: $0) }
    .preferredColorScheme(.dark)
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

/// The viewer's Info: pixel size, type, bytes, source, model and settings (D§3.7).
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
