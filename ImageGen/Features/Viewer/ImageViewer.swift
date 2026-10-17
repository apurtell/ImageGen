import SwiftUI

/// An image in the viewer, with what its Info shows (D§3.7).
/// A `Sendable` value with no record objects, so it can be built from a snapshot and passed to the
/// decode task freely.
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
/// The chat screen sets one to present the viewer with `.fullScreenCover(item:)`.
struct ViewerRequest: Identifiable {
  let images: [ViewerImage]
  let startID: UUID
  var id: UUID { startID }
}

/// The full-screen viewer (D§3.7): pages through a message's images, each zoomable; a single tap
/// toggles the chrome; ✕ or a downward swipe at the minimum zoom dismisses.
///
/// `ChatView` presents it as a full-screen cover. A page `TabView` holds one `ZoomableImageView` per
/// image; each page loads its own thumbnail and full decode. The viewer owns its own
/// `ImageExportModel` for the toolbar's export buttons, so Share and Save to Files present over the
/// viewer, and any export still open is closed when the viewer goes away. The view runs on the main
/// actor; the only background work is each page's decode.
struct ImageViewer: View {
  let request: ViewerRequest
  let thumbnails: ThumbnailService
  let onEditFromHere: (UUID) -> Void
  @State private var exporter: ImageExportModel
  /// The ID of the page on screen. It is the pager's selection, and it survives the pager's rebuild.
  @State private var current: UUID
  @State private var showsChrome = true
  /// The image whose Info sheet is open, or nil.
  @State private var info: ViewerImage?
  @Environment(\.dismiss) private var dismiss

  init(request: ViewerRequest, thumbnails: ThumbnailService, log: ActivityLog, onEditFromHere: @escaping (UUID) -> Void) {
    self.request = request
    self.thumbnails = thumbnails
    self.onEditFromHere = onEditFromHere
    // `_exporter` is the `@State` storage itself. SwiftUI uses this initial value only the first
    // time; when it calls `init` again, the existing model and page are kept.
    _exporter = State(initialValue: ImageExportModel(log: log))
    _current = State(initialValue: request.startID)
  }

  /// Falls back to the first image if `current` matches none.
  private var currentImage: ViewerImage? { request.images.first { $0.id == current } ?? request.images.first }
  private var position: Int { (request.images.firstIndex { $0.id == current } ?? 0) + 1 }

  var body: some View {
    GeometryReader { geo in
      pager
        // A page TabView keeps a stale container frame after a live rotation (a 10 pt strip on
        // iOS 26.5), so it's rebuilt for each size; the selection is kept in `current`.
        // A new `.id` makes SwiftUI discard the old pages and build new ones. Each old page's
        // load is cancelled (`dismantleUIView`); the new current page gets its full image from the
        // `FullDecoder`, which kept it, so a rotation doesn't decode it again.
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
          // The chat pins the image (the composer then shows its chip), then the viewer closes (D§3.7).
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
    // The viewer's own presenter: its `.onDisappear` closes an open Share or Save to Files when the
    // viewer goes away.
    .modifier(ImageExportPresenter(model: exporter, toastOffset: 64))
    .sheet(item: $info) { ViewerInfoSheet(image: $0) }
    // The decoder's kept image is for this viewer only; closing the viewer releases it.
    .onDisappear { Task { await FullDecoder.shared.clear() } }
    .preferredColorScheme(.dark)
  }

  private var pager: some View {
    TabView(selection: $current) {
      ForEach(request.images) { image in
        // `isCurrent` lets a page that is swiped away reset its zoom (each page starts fitted).
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

/// The viewer's Info: pixel size, type, bytes, source, model and settings (D§3.7).
/// A read-only list over a `ViewerImage` value.
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
