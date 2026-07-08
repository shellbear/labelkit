import AppKit
import LabelKit
import SwiftUI

/// Reliable physical-pixel scale. `@Environment(\.displayScale)` reports 1.0
/// in bare-SPM SwiftUI windows, which halves decode resolution on Retina —
/// the screen's own backing scale factor is the truth.
@MainActor
enum Display {
    static var scale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }
}

/// The editor pane: image + box overlays rendered by SwiftUI in view space
/// (positions scale with zoom, stroke widths don't — always crisp), all
/// pointer AND keyboard input funneled through InputCatcherView.
struct CanvasView: View {
    let store: DatasetStore
    let entry: ImageEntry

    @State private var viewModel: CanvasViewModel
    @State private var detailLoader = DetailImageLoader()
    /// Sidebar thumbnail, shown blurred while the full-res decode is in
    /// flight so fast navigation shows a soft preview instead of a spinner.
    @State private var placeholder: CGImage?
    /// Only true when this image was reached by a held-arrow scrub — a
    /// discrete step skips the blur and shows the sharp image directly.
    @State private var scrubbing = false
    @State private var showInspector = true
    @Environment(AppState.self) private var appState
    @Environment(\.undoManager) private var undoManager

    init(store: DatasetStore, entry: ImageEntry) {
        self.store = store
        self.entry = entry
        _viewModel = State(initialValue: CanvasViewModel(store: store, entry: entry))
    }

    var body: some View {
        GeometryReader { geometry in
            canvas(viewport: geometry.size)
                .onAppear { load(viewport: geometry.size) }
                // Navigation updates this same view in place (no `.id()` on the
                // canvas), so the image swap is an onChange, not a full teardown
                // and rebuild of the canvas + overlays + inspector per keystroke.
                .onChange(of: entry.filename) { load(viewport: geometry.size) }
                .onChange(of: appState.fitTrigger) {
                    viewModel.fit(in: geometry.size)
                }
                .onChange(of: geometry.size) { _, size in
                    viewModel.viewportChanged(to: size)
                    detailLoader.ensure(displayedPixels)
                }
                .onChange(of: viewModel.transform.zoom) {
                    detailLoader.ensure(displayedPixels)
                }
                .onDisappear { detailLoader.cancel() }
                // Same maxPixel as the sidebar row, so a visible row's thumbnail
                // is already cached and this is an instant hit; off-screen jumps
                // fall back to a ~1 ms 80 px decode (vs the full image's 100+ ms).
                .task(id: entry.filename) {
                    guard !entry.imageFileMissing else { return }
                    placeholder = await ThumbnailProvider.shared.thumbnail(
                        for: store.imageURL(for: entry), maxPixel: 40 * Display.scale)
                }
        }
        .background(.black.opacity(0.9))
        .inspector(isPresented: $showInspector) {
            LabelPickerView(store: store, entry: entry, viewModel: viewModel)
                .inspectorColumnWidth(min: 180, ideal: 220)
        }
    }

    /// Physical pixels the image's largest dimension currently occupies.
    private var displayedPixels: CGFloat {
        max(viewModel.imageSize.width, viewModel.imageSize.height)
            * viewModel.transform.zoom * Display.scale
    }

    @ViewBuilder
    private func canvas(viewport: CGSize) -> some View {
        if entry.imageFileMissing {
            ContentUnavailableView(
                "Image Missing on Disk",
                systemImage: "exclamationmark.triangle",
                description: Text("The annotations entry is preserved and will be saved unchanged."))
        } else {
            ZStack(alignment: .topLeading) {
                imageLayer
                boxOverlays
                if let rubberBand = viewModel.rubberBand {
                    let viewRect = viewModel.transform.toView(rubberBand)
                    Rectangle()
                        .stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: viewRect.width, height: viewRect.height)
                        .offset(x: viewRect.minX, y: viewRect.minY)
                }
                InputCatcherView(
                    onDown: { viewModel.pointerDown(at: $0, undoManager: undoManager) },
                    onDrag: { viewModel.pointerDragged(to: $0, undoManager: undoManager) },
                    onUp: { viewModel.pointerUp(at: $0, undoManager: undoManager) },
                    onScroll: { viewModel.scroll(by: $0, at: $1, zooming: $2) },
                    onMagnify: { viewModel.magnify(by: $0, at: $1) },
                    onKey: { handle(key: $0) },
                    cursorProvider: { viewModel.cursor(at: $0) }
                )
            }
            .clipped()
        }
    }

    private func handle(key: CanvasKey) -> Bool {
        switch key {
        case .delete:
            guard viewModel.selectedBoxID != nil else { return false }
            viewModel.deleteSelected(undoManager: undoManager)
            return true
        case .left, .up:
            appState.selectNeighbor(offset: -1)
            return true
        case .right, .down:
            appState.selectNeighbor(offset: 1)
            return true
        case .digit(let digit):
            viewModel.assignLabel(digit: digit, undoManager: undoManager)
            return true
        case .toggleHide:
            guard viewModel.selectedBoxID != nil else { return false }
            viewModel.toggleHiddenSelected()
            return true
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        let size = viewModel.imageSize
        let viewRect = viewModel.transform.toView(CGRect(origin: .zero, size: size))
        // Blurred thumbnail underlay while scrubbing: an instant, recognizable
        // stand-in during the debounced decode. Box overlays draw above this
        // in view space, so they stay crisp over the blur. Each image carries
        // its own exact frame (fills reliably); there is deliberately NO
        // implicit animation here — an ambient one animated the frame's
        // width/height when navigating to a differently-sized image.
        if detailLoader.image == nil, scrubbing, let placeholder {
            Image(decorative: placeholder, scale: 1)
                .resizable()
                .interpolation(.high)
                .blur(radius: 6)
                .frame(width: viewRect.width, height: viewRect.height)
                .offset(x: viewRect.minX, y: viewRect.minY)
                .clipped()
        }
        if let image = detailLoader.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(viewModel.transform.zoom > 4 ? .none : .high)
                .frame(width: viewRect.width, height: viewRect.height)
                .offset(x: viewRect.minX, y: viewRect.minY)
        }
        if detailLoader.image == nil, placeholder == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var boxOverlays: some View {
        ForEach(entry.boxes.filter { !$0.isHidden }) { box in
            BoxOverlayView(
                box: box,
                viewRect: viewModel.transform.toView(box.rect),
                color: LabelColors.color(for: box.label, in: store.labels),
                isSelected: box.id == viewModel.selectedBoxID
            )
        }
    }

    /// First appearance and every navigation: point the persistent view model
    /// and loader at `entry`, drop the previous placeholder, and kick the
    /// decode. Used by both `.onAppear` and `.onChange(of: entry.filename)`.
    private func load(viewport: CGSize) {
        placeholder = nil
        if entry.pixelSize == nil {
            entry.pixelSize = ImageMetadata.pixelSize(of: store.imageURL(for: entry))
        }
        viewModel.bind(to: entry, viewport: viewport)
        // A held-arrow scrub shows the blur + debounces; a discrete step
        // decodes immediately and goes straight to the sharp image.
        scrubbing = appState.isRapidNavigation
        // Report the fit resolution so AppState prefetches neighbours to match.
        appState.detailDisplayPixels = displayedPixels
        guard !entry.imageFileMissing else { detailLoader.cancel(); return }
        detailLoader.display(
            url: store.imageURL(for: entry),
            imageSize: viewModel.imageSize,
            neededMaxPixel: displayedPixels,
            immediate: !scrubbing
        )
    }
}

enum LabelColors {
    private static let palette: [Color] =
        [.green, .orange, .cyan, .pink, .yellow, .purple, .red, .mint, .indigo, .teal]

    static func color(for label: String, in registry: LabelRegistry) -> Color {
        palette[(registry.index(of: label) ?? 0) % palette.count]
    }
}
