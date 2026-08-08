// move(fromOffsets:toOffset:) reads its destination in the pre-removal order, so a
// downward move is off by one from the slot the pointer names.
//
// The rows are four 20pt frames from y = 0, so their centers are 10, 30, 50 and 70.

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

        // The same drag continues, so the frames are still the ones from beginDrag.
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
        // 25 is above b's center but below a's, so the pointer is still in b's slot.
        reorder.dragMoved(to: 25) { source, destination in
            moves += 1
            order.value.move(fromOffsets: source, toOffset: destination)
        }
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(order.value, ids)
    }

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
