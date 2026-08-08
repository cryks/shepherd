// Neither list this serves can lean on List's onMove. The Display pane's lines
// are template text fields, which an NSTableView-backed list takes clicks away
// from, so they are not in a List at all; the Remotes list is one, but onMove
// drags a row from anywhere in its body instead of from a handle.
//
// Positions are taken in window coordinates because a named coordinate space
// needs a container view to hang the name on, which the Display pane's loose
// lines do not have. Nothing in a drag scrolls, so those positions stay valid
// for as long as the drag lasts.

import SwiftUI

// One instance per run of rows on screen: the Display pane's lines and the copy
// inside its per-agent override sheet must not read each other's rows.
@MainActor
@Observable
final class RowReorder<ID: Hashable> {
    private(set) var draggedID: ID?

    // Not observed: layout writes it on every pass, and redrawing on that would
    // re-render the Display pane's template fields under the reader's cursor.
    @ObservationIgnored private var rowFrames: [ID: CGRect] = [:]

    @ObservationIgnored private var drag: Drag?

    // The target slot is recomputed from the order and positions the drag
    // started from. Comparing against the neighbours' current positions would
    // make a pointer resting on a boundary swap back and forth, because each
    // swap moves the neighbour the comparison just used.
    private struct Drag {
        let order: [ID]
        let frames: [ID: CGRect]
        let origin: Int
        var slot: Int
    }

    func rowDidLayout(_ frame: CGRect, id: ID) {
        rowFrames[id] = frame
    }

    // `order` must index the same array the `move` passed to
    // `dragMoved(to:move:)` applies to.
    func beginDrag(_ id: ID, in order: [ID]) {
        guard let origin = order.firstIndex(of: id) else { return }
        drag = Drag(order: order, frames: rowFrames, origin: origin, slot: origin)
        draggedID = id
    }

    // `y` is in window coordinates. `move` runs only on a slot change, so a
    // drag across one boundary is one move.
    func dragMoved(to y: CGFloat, move: (IndexSet, Int) -> Void) {
        guard var drag = self.drag else { return }
        let slot = targetSlot(at: y, drag)
        guard slot != drag.slot else { return }
        // move(fromOffsets:toOffset:) reads its destination in the order from
        // before the row is lifted out, so a move further down counts the
        // dragged row itself.
        move(IndexSet(integer: drag.slot), slot > drag.slot ? slot + 1 : slot)
        drag.slot = slot
        self.drag = drag
    }

    func endDrag() {
        drag = nil
        draggedID = nil
    }

    // A row no layout has reported counts as sitting below the pointer, which
    // leaves the slot where it is.
    private func targetSlot(at y: CGFloat, _ drag: Drag) -> Int {
        drag.order.enumerated()
            .filter { $0.offset != drag.origin }
            .filter { (drag.frames[$0.element]?.midY ?? .infinity) < y }
            .count
    }
}

// The accessibility actions are the only way to reorder without a pointer.
struct RowGrabber<ID: Hashable>: View {
    let id: ID
    let order: [ID]
    let reorder: RowReorder<ID>
    let move: (IndexSet, Int) -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(reorder.draggedID == id ? .secondary : .tertiary)
            .frame(width: 14)
            .contentShape(.rect)
            .gesture(drag)
            .help(tr("Drag to reorder", ja: "ドラッグして並び替え"))
            .accessibilityLabel(tr("Reorder", ja: "並び替え"))
            .accessibilityAction(named: Text(tr("Move Up", ja: "上へ"))) { step(by: -1) }
            .accessibilityAction(named: Text(tr("Move Down", ja: "下へ"))) { step(by: +1) }
    }

    private var drag: some Gesture {
        // A couple of points of slack so that clicking the handle, or brushing
        // it on the way to a field, does not reorder anything.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if reorder.draggedID != id {
                    reorder.beginDrag(id, in: order)
                }
                reorder.dragMoved(to: value.location.y, move: move)
            }
            .onEnded { _ in reorder.endDrag() }
    }

    private func step(by delta: Int) {
        guard let index = order.firstIndex(of: id),
              order.indices.contains(index + delta) else { return }
        // Moving down passes the destination in the order from before the row
        // is lifted out, the same as a dragged move.
        move(IndexSet(integer: index), delta < 0 ? index + delta : index + delta + 1)
    }
}

extension View {
    // Every row of the run needs this; a drag reads nothing but these frames.
    func reorderableRow<ID: Hashable>(_ reorder: RowReorder<ID>, id: ID) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            reorder.rowDidLayout(frame, id: id)
        }
    }
}
