import AppKit
import SwiftUI

/// The single input funnel for the canvas. An AppKit view because SwiftUI on
/// macOS exposes neither scroll-wheel deltas, pinch magnification, nor
/// mouse-moved (cursor) events at the fidelity a box editor needs. Top-left
/// origin (isFlipped) so its coordinates match the SwiftUI overlays 1:1.
struct InputCatcherView: NSViewRepresentable {
    var onDown: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onUp: (CGPoint) -> Void
    var onScroll: (CGVector, CGPoint, Bool) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
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
        override var acceptsFirstResponder: Bool { false }

        func configure(with callbacks: InputCatcherView) {
            self.callbacks = callbacks
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
    }
}
