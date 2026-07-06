import LabelKit
import SwiftUI

/// One bounding box drawn in view space. Stroke width and handle size are in
/// points (constant on screen at any zoom); only positions scale.
struct BoxOverlayView: View {
    let box: BoundingBox
    let viewRect: CGRect
    let color: Color
    let isSelected: Bool

    private static let handleSize: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(isSelected ? 0.18 : 0.08))
                .overlay(
                    Rectangle().strokeBorder(color, lineWidth: isSelected ? 2 : 1)
                )
                .frame(width: max(viewRect.width, 1), height: max(viewRect.height, 1))
                .offset(x: viewRect.minX, y: viewRect.minY)

            Text(box.label)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
                .offset(x: viewRect.minX, y: viewRect.minY - 16)

            if isSelected {
                ForEach(Array(ResizeHandle.allCases.enumerated()), id: \.offset) { _, handle in
                    let position = handlePosition(handle)
                    Rectangle()
                        .fill(.white)
                        .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
                        .frame(width: Self.handleSize, height: Self.handleSize)
                        .offset(
                            x: position.x - Self.handleSize / 2,
                            y: position.y - Self.handleSize / 2
                        )
                }
            }
        }
        .allowsHitTesting(false)  // all input flows through InputCatcherView
    }

    private func handlePosition(_ handle: ResizeHandle) -> CGPoint {
        let x: CGFloat = switch handle.mask.dx {
        case -1: viewRect.minX
        case 1: viewRect.maxX
        default: viewRect.midX
        }
        let y: CGFloat = switch handle.mask.dy {
        case -1: viewRect.minY
        case 1: viewRect.maxY
        default: viewRect.midY
        }
        return CGPoint(x: x, y: y)
    }
}
