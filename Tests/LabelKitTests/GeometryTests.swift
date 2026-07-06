import XCTest
@testable import LabelKit

final class CanvasTransformTests: XCTestCase {
    func testViewImageInverseIdentity() {
        let transform = CanvasTransform(zoom: 2.5, pan: CGPoint(x: 40, y: -12))
        let point = CGPoint(x: 123.4, y: 567.8)
        let roundTrip = transform.toImage(transform.toView(point))
        XCTAssertEqual(roundTrip.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.y, point.y, accuracy: 1e-9)
    }

    func testFitCentersAndContains() {
        // Tall image in a wide frame → height-bound zoom, x-centered.
        let transform = CanvasTransform.fit(
            imageSize: CGSize(width: 800, height: 1600), in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(transform.zoom, 0.5, accuracy: 1e-9)
        XCTAssertEqual(transform.pan.x, 300, accuracy: 1e-9)
        XCTAssertEqual(transform.pan.y, 0, accuracy: 1e-9)

        // Wide image in a tall frame → width-bound zoom, y-centered.
        let wide = CanvasTransform.fit(
            imageSize: CGSize(width: 2000, height: 500), in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(wide.zoom, 0.5, accuracy: 1e-9)
        XCTAssertEqual(wide.pan.y, 275, accuracy: 1e-9)
    }

    func testZoomAboutAnchorPinsThePixelUnderCursor() {
        var transform = CanvasTransform.fit(
            imageSize: CGSize(width: 800, height: 800), in: CGSize(width: 400, height: 400))
        let anchor = CGPoint(x: 120, y: 300)
        let before = transform.toImage(anchor)
        transform.zoom(by: 3, anchor: anchor)
        let after = transform.toImage(anchor)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-6)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-6)
    }

    func testZoomClamps() {
        var transform = CanvasTransform(zoom: 1, pan: .zero)
        transform.zoom(by: 10_000, anchor: .zero)
        XCTAssertEqual(transform.zoom, CanvasTransform.maxZoom)
        transform.zoom(by: 1e-9, anchor: .zero)
        XCTAssertEqual(transform.zoom, CanvasTransform.minZoom)
    }
}

final class ResizeHandleTests: XCTestCase {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testEachHandleMovesItsEdges() {
        let bottomRight = ResizeHandle.bottomRight.resize(rect, to: CGPoint(x: 200, y: 100), in: bounds)
        XCTAssertEqual(bottomRight, CGRect(x: 10, y: 20, width: 190, height: 80))

        let top = ResizeHandle.top.resize(rect, to: CGPoint(x: 999, y: 10), in: bounds)
        XCTAssertEqual(top, CGRect(x: 10, y: 10, width: 100, height: 60))  // x untouched by edge handle

        let left = ResizeHandle.left.resize(rect, to: CGPoint(x: 30, y: 999), in: bounds)
        XCTAssertEqual(left, CGRect(x: 30, y: 20, width: 80, height: 50))
    }

    func testFlipPastOppositeEdgeNormalizes() {
        // Drag left handle 40px past the right edge → valid flipped rect.
        let flipped = ResizeHandle.left.resize(rect, to: CGPoint(x: 150, y: 20), in: bounds)
        XCTAssertEqual(flipped, CGRect(x: 110, y: 20, width: 40, height: 50))
        XCTAssertGreaterThanOrEqual(flipped.width, 0)
    }

    func testClampsToImageBounds() {
        let clamped = ResizeHandle.bottomRight.resize(rect, to: CGPoint(x: 9999, y: -50), in: bounds)
        XCTAssertEqual(clamped.maxX, 800)
        XCTAssertEqual(clamped.minY, 0)   // dragged above the top, flipped + clamped
    }

    func testHandlePositions() {
        XCTAssertEqual(ResizeHandle.topLeft.position(on: rect), CGPoint(x: 10, y: 20))
        XCTAssertEqual(ResizeHandle.bottom.position(on: rect), CGPoint(x: 60, y: 70))
        XCTAssertEqual(ResizeHandle.right.position(on: rect), CGPoint(x: 110, y: 45))
    }
}

final class CanvasHitTesterTests: XCTestCase {
    let big = BoundingBox(label: "card", rect: CGRect(x: 0, y: 0, width: 200, height: 200))
    let small = BoundingBox(label: "card", rect: CGRect(x: 50, y: 50, width: 20, height: 20))

    func testHandleBeatsBodyOnSelectedBox() {
        let hit = CanvasHitTester.hitTest(
            point: CGPoint(x: 50, y: 50), boxes: [big, small], selectedID: small.id, tolerance: 4)
        XCTAssertEqual(hit, .handle(boxID: small.id, handle: .topLeft))
    }

    func testSmallestBoxWinsAmongOverlaps() {
        let hit = CanvasHitTester.hitTest(
            point: CGPoint(x: 60, y: 60), boxes: [big, small], selectedID: nil, tolerance: 4)
        XCTAssertEqual(hit, .boxBody(boxID: small.id))
    }

    func testSelectedBoxWinsOverSmaller() {
        let hit = CanvasHitTester.hitTest(
            point: CGPoint(x: 60, y: 60), boxes: [big, small], selectedID: big.id, tolerance: 1)
        XCTAssertEqual(hit, .boxBody(boxID: big.id))
    }

    func testEmptyOutsideEverything() {
        let hit = CanvasHitTester.hitTest(
            point: CGPoint(x: 500, y: 500), boxes: [big, small], selectedID: nil, tolerance: 4)
        XCTAssertEqual(hit, .empty)
    }
}

final class EditorStateMachineTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    let box = BoundingBox(label: "card", rect: CGRect(x: 100, y: 100, width: 50, height: 50))

    func testDrawCommitAboveMinimumSize() {
        var machine = EditorStateMachine()
        _ = machine.pointerDown(at: CGPoint(x: 10, y: 10), hit: .empty, spaceHeld: false, boxes: [])
        _ = machine.pointerDragged(to: CGPoint(x: 60, y: 40), viewDelta: .zero, imageBounds: bounds)
        let effects = machine.pointerUp(at: CGPoint(x: 60, y: 40), imageBounds: bounds) { _ in nil }
        XCTAssertTrue(effects.contains(.createBox(rect: CGRect(x: 10, y: 10, width: 50, height: 30))))
        XCTAssertEqual(machine.state, .idle)
    }

    func testTinyDrawIsAClickThatDeselects() {
        var machine = EditorStateMachine()
        let down = machine.pointerDown(at: CGPoint(x: 10, y: 10), hit: .empty, spaceHeld: false, boxes: [])
        XCTAssertTrue(down.contains(.select(nil)))
        let effects = machine.pointerUp(at: CGPoint(x: 11, y: 12), imageBounds: bounds) { _ in nil }
        XCTAssertFalse(effects.contains { if case .createBox = $0 { return true }; return false })
    }

    func testMoveEmitsLiveUpdatesAndSingleCommit() {
        var machine = EditorStateMachine()
        _ = machine.pointerDown(
            at: CGPoint(x: 110, y: 110), hit: .boxBody(boxID: box.id), spaceHeld: false, boxes: [box])
        let drag = machine.pointerDragged(to: CGPoint(x: 210, y: 110), viewDelta: .zero, imageBounds: bounds)
        XCTAssertEqual(drag, [.updateRect(id: box.id, rect: CGRect(x: 200, y: 100, width: 50, height: 50))])

        let moved = CGRect(x: 200, y: 100, width: 50, height: 50)
        let up = machine.pointerUp(at: CGPoint(x: 210, y: 110), imageBounds: bounds) { _ in moved }
        XCTAssertEqual(up, [.commitRect(id: box.id, original: box.rect, final: moved)])
    }

    func testMoveClampsToBounds() {
        var machine = EditorStateMachine()
        _ = machine.pointerDown(
            at: CGPoint(x: 110, y: 110), hit: .boxBody(boxID: box.id), spaceHeld: false, boxes: [box])
        let drag = machine.pointerDragged(to: CGPoint(x: -500, y: -500), viewDelta: .zero, imageBounds: bounds)
        guard case .updateRect(_, let rect)? = drag.first else { return XCTFail("no update") }
        XCTAssertEqual(rect.origin, .zero)
    }

    func testResizeRouteUsesHandleMath() {
        var machine = EditorStateMachine()
        _ = machine.pointerDown(
            at: CGPoint(x: 150, y: 150), hit: .handle(boxID: box.id, handle: .bottomRight),
            spaceHeld: false, boxes: [box])
        let drag = machine.pointerDragged(to: CGPoint(x: 300, y: 200), viewDelta: .zero, imageBounds: bounds)
        XCTAssertEqual(drag, [.updateRect(id: box.id, rect: CGRect(x: 100, y: 100, width: 200, height: 100))])
    }

    func testPanDoesNotMutateBoxes() {
        var machine = EditorStateMachine()
        _ = machine.pointerDown(at: CGPoint(x: 10, y: 10), hit: .empty, spaceHeld: true, boxes: [box])
        let drag = machine.pointerDragged(
            to: CGPoint(x: 60, y: 40), viewDelta: CGPoint(x: 5, y: 3), imageBounds: bounds)
        XCTAssertEqual(drag, [.panBy(CGPoint(x: 5, y: 3))])
        let up = machine.pointerUp(at: CGPoint(x: 60, y: 40), imageBounds: bounds) { _ in nil }
        XCTAssertTrue(up.isEmpty)
    }
}
