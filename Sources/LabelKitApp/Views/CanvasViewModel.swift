import AppKit
import LabelKit
import Observation
import SwiftUI

/// Bridges raw pointer events to the headless EditorStateMachine and applies
/// its effects to the store. Owns the view transform (zoom/pan).
@Observable
@MainActor
final class CanvasViewModel {
    var transform = CanvasTransform()
    var selectedBoxID: UUID?
    var rubberBand: CGRect?
    /// Label applied to newly drawn boxes (last used wins).
    var drawLabel = "object"
    /// False until the user zooms or pans manually. While false, the canvas
    /// keeps the image fitted to the viewport across window resizes.
    private(set) var userAdjustedTransform = false

    private var machine = EditorStateMachine()
    private var lastDragLocation: CGPoint?

    let store: DatasetStore
    private(set) var entry: ImageEntry

    init(store: DatasetStore, entry: ImageEntry) {
        self.store = store
        self.entry = entry
        if let first = store.labels.ordered.first { drawLabel = first }
    }

    /// Re-point at a new image on navigation without recreating the view:
    /// reset per-image editor state and re-fit. `drawLabel` persists (the
    /// last-used label carries across images).
    func bind(to entry: ImageEntry, viewport: CGSize) {
        self.entry = entry
        selectedBoxID = nil
        rubberBand = nil
        machine = EditorStateMachine()
        lastDragLocation = nil
        fit(in: viewport)
    }

    var imageSize: CGSize { entry.pixelSize ?? .zero }
    var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    func fit(in viewport: CGSize) {
        transform = .fit(imageSize: imageSize, in: viewport)
        userAdjustedTransform = false
    }

    /// Re-fit on viewport changes until the user takes over explicitly.
    func viewportChanged(to viewport: CGSize) {
        guard !userAdjustedTransform, viewport.width > 0, viewport.height > 0 else { return }
        transform = .fit(imageSize: imageSize, in: viewport)
    }

    // MARK: - Pointer events (view space in, image space to the FSM)

    /// Hidden boxes are invisible to interaction, not just to rendering.
    private var visibleBoxes: [BoundingBox] { entry.boxes.filter { !$0.isHidden } }

    func pointerDown(at viewPoint: CGPoint, undoManager: UndoManager?) {
        lastDragLocation = viewPoint
        let imagePoint = transform.toImage(viewPoint)
        let hit = CanvasHitTester.hitTest(
            point: imagePoint,
            boxes: visibleBoxes,
            selectedID: selectedBoxID,
            tolerance: 8 / transform.zoom
        )
        apply(machine.pointerDown(at: imagePoint, hit: hit, spaceHeld: false, boxes: visibleBoxes),
              undoManager: undoManager)
    }

    func pointerDragged(to viewPoint: CGPoint, undoManager: UndoManager?) {
        let delta = CGPoint(
            x: viewPoint.x - (lastDragLocation?.x ?? viewPoint.x),
            y: viewPoint.y - (lastDragLocation?.y ?? viewPoint.y)
        )
        lastDragLocation = viewPoint
        apply(machine.pointerDragged(
            to: transform.toImage(viewPoint), viewDelta: delta, imageBounds: imageBounds),
              undoManager: undoManager)
    }

    func pointerUp(at viewPoint: CGPoint, undoManager: UndoManager?) {
        lastDragLocation = nil
        let effects = machine.pointerUp(
            at: transform.toImage(viewPoint), imageBounds: imageBounds
        ) { id in entry.boxes.first(where: { $0.id == id })?.rect }
        apply(effects, undoManager: undoManager)
    }

    func cursor(at viewPoint: CGPoint) -> NSCursor {
        let hit = CanvasHitTester.hitTest(
            point: transform.toImage(viewPoint),
            boxes: visibleBoxes,
            selectedID: selectedBoxID,
            tolerance: 8 / transform.zoom
        )
        switch hit {
        case .handle(_, let handle):
            switch handle.mask {
            case (0, _): return .resizeUpDown
            case (_, 0): return .resizeLeftRight
            default: return .crosshair
            }
        case .boxBody: return .openHand
        case .empty: return .crosshair
        }
    }

    // MARK: - Scroll / zoom

    func scroll(by delta: CGVector, at location: CGPoint, zooming: Bool) {
        userAdjustedTransform = true
        if zooming {
            transform.zoom(by: 1 + delta.dy / 100, anchor: location)
        } else {
            transform.panBy(CGPoint(x: delta.dx, y: delta.dy))
        }
    }

    func magnify(by factor: CGFloat, at location: CGPoint) {
        userAdjustedTransform = true
        transform.zoom(by: factor, anchor: location)
    }

    // MARK: - Keyboard

    func deleteSelected(undoManager: UndoManager?) {
        guard let selectedBoxID else { return }
        store.removeBox(id: selectedBoxID, from: entry, undoManager: undoManager)
        self.selectedBoxID = nil
    }

    func toggleHiddenSelected() {
        guard let selectedBoxID else { return }
        store.toggleBoxHidden(id: selectedBoxID, in: entry)
    }

    func assignLabel(digit: Int, undoManager: UndoManager?) {
        guard digit >= 1, digit <= store.labels.ordered.count else { return }
        let label = store.labels.ordered[digit - 1]
        drawLabel = label
        if let selectedBoxID {
            store.setBoxLabel(id: selectedBoxID, in: entry, to: label, undoManager: undoManager)
        }
    }

    // MARK: - Effects

    private func apply(_ effects: [EditorStateMachine.Effect], undoManager: UndoManager?) {
        for effect in effects {
            switch effect {
            case .select(let id):
                selectedBoxID = id
            case .updateRect(let id, let rect):
                store.setBoxRect(id: id, in: entry, to: rect)
            case .commitRect(let id, let original, let final):
                store.commitBoxRect(
                    id: id, in: entry, from: original, to: final, undoManager: undoManager)
            case .createBox(let rect):
                let box = BoundingBox(label: drawLabel, rect: rect)
                store.addBox(box, to: entry, undoManager: undoManager)
                selectedBoxID = box.id
            case .rubberBand(let rect):
                rubberBand = rect
            case .panBy(let delta):
                userAdjustedTransform = true
                transform.panBy(delta)
            }
        }
    }
}
