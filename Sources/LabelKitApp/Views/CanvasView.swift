import LabelKit
import SwiftUI

/// The editor pane: image + box overlays rendered by SwiftUI in view space
/// (positions scale with zoom, stroke widths don't — always crisp), all
/// pointer input funneled through InputCatcherView → EditorStateMachine.
struct CanvasView: View {
    let store: DatasetStore
    let entry: ImageEntry

    @State private var viewModel: CanvasViewModel
    @State private var detailLoader = DetailImageLoader()
    @State private var showInspector = true
    @Environment(AppState.self) private var appState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    init(store: DatasetStore, entry: ImageEntry) {
        self.store = store
        self.entry = entry
        _viewModel = State(initialValue: CanvasViewModel(store: store, entry: entry))
    }

    var body: some View {
        GeometryReader { geometry in
            canvas(viewport: geometry.size)
                .onAppear { open(viewport: geometry.size) }
                .onChange(of: appState.fitTrigger) {
                    viewModel.fit(in: geometry.size)
                }
                .onChange(of: viewModel.transform.zoom) { _, zoom in
                    detailLoader.zoomChanged(
                        displayZoom: zoom * displayScale,
                        viewportMaxPixel: max(geometry.size.width, geometry.size.height) * displayScale
                    )
                }
        }
        .background(.black.opacity(0.9))
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .up: appState.selectNeighbor(offset: -1)
            case .right, .down: appState.selectNeighbor(offset: 1)
            @unknown default: break
            }
        }
        .onDeleteCommand {
            viewModel.deleteSelected(undoManager: undoManager)
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = press.characters.first?.wholeNumberValue else { return .ignored }
            viewModel.assignLabel(digit: digit, undoManager: undoManager)
            return .handled
        }
        .inspector(isPresented: $showInspector) {
            LabelPickerView(store: store, entry: entry, viewModel: viewModel)
                .inspectorColumnWidth(min: 180, ideal: 220)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Labels", systemImage: "tag")
                }
            }
        }
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
                    cursorProvider: { viewModel.cursor(at: $0) }
                )
            }
            .clipped()
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        if let image = detailLoader.image {
            let size = viewModel.imageSize
            let viewRect = viewModel.transform.toView(CGRect(origin: .zero, size: size))
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(viewModel.transform.zoom > 4 ? .none : .high)
                .frame(width: viewRect.width, height: viewRect.height)
                .offset(x: viewRect.minX, y: viewRect.minY)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var boxOverlays: some View {
        ForEach(entry.boxes) { box in
            BoxOverlayView(
                box: box,
                viewRect: viewModel.transform.toView(box.rect),
                color: LabelColors.color(for: box.label, in: store.labels),
                isSelected: box.id == viewModel.selectedBoxID
            )
        }
    }

    private func open(viewport: CGSize) {
        if entry.pixelSize == nil {
            entry.pixelSize = ImageMetadata.pixelSize(of: store.imageURL(for: entry))
        }
        viewModel.fit(in: viewport)
        detailLoader.display(
            url: store.imageURL(for: entry),
            imageSize: viewModel.imageSize,
            viewportMaxPixel: max(viewport.width, viewport.height) * displayScale
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
