import CoreGraphics
import Foundation

public enum HitResult: Equatable, Sendable {
    case handle(boxID: UUID, handle: ResizeHandle)
    case boxBody(boxID: UUID)
    case empty
}

/// Pure hit-testing over boxes in IMAGE space. `tolerance` is supplied in
/// image pixels (callers pass screenTolerance / zoom so grab feel is constant
/// at any magnification). Priority: selected box's handles → any box body
/// (selected first, then smallest area = "topmost" feel) → empty.
public enum CanvasHitTester {
    public static func hitTest(
        point: CGPoint,
        boxes: [BoundingBox],
        selectedID: UUID?,
        tolerance: CGFloat
    ) -> HitResult {
        // Handles only exist on the selected box.
        if let selectedID, let selected = boxes.first(where: { $0.id == selectedID }) {
            for handle in ResizeHandle.allCases {
                let position = handle.position(on: selected.rect)
                if abs(point.x - position.x) <= tolerance, abs(point.y - position.y) <= tolerance {
                    return .handle(boxID: selectedID, handle: handle)
                }
            }
        }

        let hits = boxes.filter { $0.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        if let selectedID, hits.contains(where: { $0.id == selectedID }) {
            return .boxBody(boxID: selectedID)
        }
        if let smallest = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
            return .boxBody(boxID: smallest.id)
        }
        return .empty
    }
}
