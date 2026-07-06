import CoreGraphics

/// The 8 resize handles as (dx, dy) edge masks: -1 = leading/top edge moves,
/// +1 = trailing/bottom edge moves, 0 = axis untouched. One generic resize
/// function serves all handles.
public enum ResizeHandle: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight

    public var mask: (dx: Int, dy: Int) {
        switch self {
        case .topLeft: return (-1, -1)
        case .top: return (0, -1)
        case .topRight: return (1, -1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        case .bottomLeft: return (-1, 1)
        case .bottom: return (0, 1)
        case .bottomRight: return (1, 1)
        }
    }

    /// Handle position on a rect (image space).
    public func position(on rect: CGRect) -> CGPoint {
        let x: CGFloat = switch mask.dx {
        case -1: rect.minX
        case 1: rect.maxX
        default: rect.midX
        }
        let y: CGFloat = switch mask.dy {
        case -1: rect.minY
        case 1: rect.maxY
        default: rect.midY
        }
        return CGPoint(x: x, y: y)
    }

    /// Moves this handle's edges of `rect` to track `point`, normalizing when
    /// dragged past the opposite edge (a left handle dragged past the right
    /// edge yields a valid flipped rect), then clamps to `bounds`.
    public func resize(_ rect: CGRect, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        var x0 = rect.minX, x1 = rect.maxX
        var y0 = rect.minY, y1 = rect.maxY
        switch mask.dx {
        case -1: x0 = clamped.x
        case 1: x1 = clamped.x
        default: break
        }
        switch mask.dy {
        case -1: y0 = clamped.y
        case 1: y1 = clamped.y
        default: break
        }
        return CGRect(
            x: min(x0, x1), y: min(y0, y1),
            width: abs(x1 - x0), height: abs(y1 - y0)
        )
    }
}
