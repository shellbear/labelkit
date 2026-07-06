import CoreGraphics
import Foundation

/// Pure interaction state machine for the box editor. Views feed it pointer
/// events (already converted to image space); it returns effects for the view
/// layer to apply. No AppKit/SwiftUI, fully unit-testable.
public struct EditorStateMachine: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case drawing(start: CGPoint)
        case movingBox(id: UUID, original: CGRect, grabOffset: CGPoint)
        case resizing(id: UUID, handle: ResizeHandle, original: CGRect)
        case panning
    }

    public enum Effect: Equatable, Sendable {
        case select(UUID?)
        /// Live-update a box rect (no undo — per-frame).
        case updateRect(id: UUID, rect: CGRect)
        /// Gesture ended: register one undo step from `original` to `final`.
        case commitRect(id: UUID, original: CGRect, final: CGRect)
        /// Draw finished: create this box (undoable).
        case createBox(rect: CGRect)
        /// Rubber-band rectangle to render while drawing (nil = hide).
        case rubberBand(CGRect?)
        case panBy(CGPoint)
    }

    /// Draws smaller than this (image px) are treated as clicks.
    public static let minimumDrawSize: CGFloat = 4

    public private(set) var state: State = .idle

    public init() {}

    public mutating func pointerDown(
        at point: CGPoint,
        hit: HitResult,
        spaceHeld: Bool,
        boxes: [BoundingBox]
    ) -> [Effect] {
        if spaceHeld {
            state = .panning
            return []
        }
        switch hit {
        case .handle(let id, let handle):
            guard let box = boxes.first(where: { $0.id == id }) else { return [] }
            state = .resizing(id: id, handle: handle, original: box.rect)
            return []
        case .boxBody(let id):
            guard let box = boxes.first(where: { $0.id == id }) else { return [] }
            state = .movingBox(
                id: id, original: box.rect,
                grabOffset: CGPoint(x: point.x - box.rect.minX, y: point.y - box.rect.minY)
            )
            return [.select(id)]
        case .empty:
            state = .drawing(start: point)
            return [.select(nil)]
        }
    }

    public mutating func pointerDragged(
        to point: CGPoint,
        viewDelta: CGPoint,
        imageBounds: CGRect
    ) -> [Effect] {
        switch state {
        case .idle:
            return []
        case .panning:
            return [.panBy(viewDelta)]
        case .drawing(let start):
            return [.rubberBand(normalizedRect(from: start, to: point, in: imageBounds))]
        case .movingBox(let id, let original, let grabOffset):
            var rect = original
            rect.origin = CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y)
            rect.origin.x = min(max(rect.origin.x, imageBounds.minX), imageBounds.maxX - rect.width)
            rect.origin.y = min(max(rect.origin.y, imageBounds.minY), imageBounds.maxY - rect.height)
            return [.updateRect(id: id, rect: rect)]
        case .resizing(let id, let handle, let original):
            return [.updateRect(id: id, rect: handle.resize(original, to: point, in: imageBounds))]
        }
    }

    public mutating func pointerUp(at point: CGPoint, imageBounds: CGRect,
                                   currentRect: (UUID) -> CGRect?) -> [Effect] {
        defer { state = .idle }
        switch state {
        case .idle, .panning:
            return []
        case .drawing(let start):
            let rect = normalizedRect(from: start, to: point, in: imageBounds)
            let effects: [Effect] = rect.width >= Self.minimumDrawSize && rect.height >= Self.minimumDrawSize
                ? [.rubberBand(nil), .createBox(rect: rect)]
                : [.rubberBand(nil)]
            return effects
        case .movingBox(let id, let original, _), .resizing(let id, _, let original):
            guard let final = currentRect(id), final != original else { return [] }
            return [.commitRect(id: id, original: original, final: final)]
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        let clampedEnd = CGPoint(
            x: min(max(end.x, bounds.minX), bounds.maxX),
            y: min(max(end.y, bounds.minY), bounds.maxY)
        )
        return CGRect(
            x: min(start.x, clampedEnd.x),
            y: min(start.y, clampedEnd.y),
            width: abs(clampedEnd.x - start.x),
            height: abs(clampedEnd.y - start.y)
        )
    }
}
