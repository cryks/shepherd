// Pins what a grabber drag does to the array behind the rows: the row lands in
// the slot the pointer is over, and it takes exactly one move to get there.
//
// The destination arithmetic is the reason this file exists.
// move(fromOffsets:toOffset:) reads its destination in the order from before the
// row is lifted out, so a downward move is off by one from the slot the pointer
// names, and that is invisible until a row is dragged past a neighbour.
//
// Frames here are laid out as four 20pt rows from y = 0, which puts their
// centers at 10, 30, 50 and 70.

import XCTest
@testable import Shepherd

@MainActor
final class RowReorderTests: XCTestCase {
    private let ids = ["a", "b", "c", "d"]

    func testDraggingDownLandsTheRowWhereThePointerIs() {
        let (reorder, order) = laidOutList()

        reorder.beginDrag("a", in: ids)
        reorder.dragMoved(to: 35) { source, destination in
            order.value.move(fromOffsets: source, toOffset: destination)
        }
        XCTAssertEqual(order.value, ["b", "a", "c", "d"])

        // Same drag continuing to the last row, recomputed from where the rows
        // were when it started.
        reorder.dragMoved(to: 75) { source, destination in
            order.value.move(fromOffsets: source, toOffset: destination)
        }
        XCTAssertEqual(order.value, ["b", "c", "d", "a"])
    }

    func testDraggingUpLandsTheRowWhereThePointerIs() {
        let (reorder, order) = laidOutList()

        reorder.beginDrag("d", in: ids)
        reorder.dragMoved(to: 5) { source, destination in
            order.value.move(fromOffsets: source, toOffset: destination)
        }
        XCTAssertEqual(order.value, ["d", "a", "b", "c"])
    }

    func testAPointerStillInsideItsOwnSlotDoesNotMove() {
        let (reorder, order) = laidOutList()
        var moves = 0

        reorder.beginDrag("b", in: ids)
        // Above b's own center but not past a's, so there is no boundary
        // between the pointer and where b already is.
        reorder.dragMoved(to: 25) { source, destination in
            moves += 1
            order.value.move(fromOffsets: source, toOffset: destination)
        }
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(order.value, ids)
    }

    /// A reorder whose rows have all been laid out, and a box holding the order
    /// the moves apply to.
    private func laidOutList() -> (RowReorder<String>, Box) {
        let reorder = RowReorder<String>()
        for (index, id) in ids.enumerated() {
            reorder.rowDidLayout(
                CGRect(x: 0, y: CGFloat(index) * 20, width: 100, height: 20),
                id: id
            )
        }
        return (reorder, Box(value: ids))
    }

    private final class Box {
        var value: [String]

        init(value: [String]) {
            self.value = value
        }
    }
}
