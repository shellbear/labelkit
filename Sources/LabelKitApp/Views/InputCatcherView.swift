import AppKit
import SwiftUI

/// Keys the canvas cares about, delivered through the same AppKit funnel as
/// pointer events (SwiftUI focus on macOS is too unreliable for an editor —
/// clicking an NSView-backed canvas never focuses a SwiftUI `.focusable()`).
enum CanvasKey {
    case delete
    case left, right, up, down
    case digit(Int)
    case toggleHide
}

/// The single input funnel for the canvas. An AppKit view because SwiftUI on
/// macOS exposes neither scroll-wheel deltas, pinch magnification, mouse-moved
/// (cursor) events, nor dependable key focus at the fidelity a box editor
/// needs. Top-left origin (isFlipped) so its coordinates match the SwiftUI
/// overlays 1:1.
struct InputCatcherView: NSViewRepresentable {
    var onDown: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onUp: (CGPoint) -> Void
    var onScroll: (CGVector, CGPoint, Bool) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onKey: (CanvasKey) -> Bool
    var cursorProvider: (CGPoint) -> NSCursor

    func makeNSView(context: Context) -> CatcherNSView {
        let view = CatcherNSView()
        view.configure(with: self)
        return view
    }

    func updateNSView(_ nsView: CatcherNSView, context: Context) {
        nsView.configure(with: self)
    }

    final class CatcherNSView: NSView {
        private var callbacks: InputCatcherView?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        func configure(with callbacks: InputCatcherView) {
            self.callbacks = callbacks
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The canvas is the natural key target when a dataset is open.
            window?.makeFirstResponder(self)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        private func location(of event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            callbacks?.onDown(location(of: event))
        }

        override func mouseDragged(with event: NSEvent) {
            callbacks?.onDrag(location(of: event))
        }

        override func mouseUp(with event: NSEvent) {
            callbacks?.onUp(location(of: event))
        }

        override func mouseMoved(with event: NSEvent) {
            callbacks?.cursorProvider(location(of: event)).set()
        }

        override func scrollWheel(with event: NSEvent) {
            // ⌥+scroll zooms; plain scroll pans. Trackpad pinch arrives via
            // magnify(with:) separately.
            let zooming = event.modifierFlags.contains(.option)
            callbacks?.onScroll(
                CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY),
                location(of: event),
                zooming
            )
        }

        override func magnify(with event: NSEvent) {
            callbacks?.onMagnify(1 + event.magnification, location(of: event))
        }

        override func keyDown(with event: NSEvent) {
            if let key = Self.canvasKey(for: event), callbacks?.onKey(key) == true {
                return
            }
            super.keyDown(with: event)
        }

        private static func canvasKey(for event: NSEvent) -> CanvasKey? {
            switch event.keyCode {
            case 51, 117: return .delete       // backspace, forward delete
            case 4: return .toggleHide          // H
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            default:
                if let character = event.charactersIgnoringModifiers?.first,
                   let digit = character.wholeNumberValue, (1...9).contains(digit) {
                    return .digit(digit)
                }
                return nil
            }
        }
    }
}
