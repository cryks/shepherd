// Grabber-driven reordering for rows laid out in a vertical run. The Display
// pane's line list and the Remotes pane's connection list both reorder through
// this, so the two read the same way: a handle at the row's leading edge is the
// only thing that starts a drag.
//
// Neither list can lean on List's onMove. The Display lines are template text
// fields, which an NSTableView-backed list takes clicks away from, so they are
// not in a List at all; the Remotes list is one, but onMove drags a row from
// anywhere in its body, and a handle is what both lists advertise.
//
// The rows stay owned by their container. A drag only produces
// move(fromOffsets:toOffset:) calls against the array behind them, and the rows
// move as the pointer passes their neighbours' centers. That live move is the
// whole feedback: there is no drag image and no insertion indicator.
//
// Positions come from the rows themselves, in window coordinates: every row
// reports its frame there and the pointer arrives in the same space. A named
// coordinate space would need one container view to hang the name on, which the
// Display pane's lines do not have — they are loose views in the pane's stack.
// Nothing in the drag itself scrolls, so the positions it starts from stay where
// the pointer measures them; a scroll turned mid-drag would move the rows out
// from under that snapshot.

import SwiftUI

/// Reorder state for one run of rows.
///
/// One instance per run on screen. The Display pane's lines and the copy of
/// that list inside its per-agent override sheet are separate runs and hold
/// separate instances, which is what keeps a drag in one from reading the
/// other's rows.
@MainActor
@Observable
final class RowReorder<ID: Hashable> {
    /// Row the pointer is dragging, nil between drags. The grabbers read it to
    /// show which one is held.
    private(set) var draggedID: ID?

    /// Where each row sits in window coordinates, as of its last layout. Not
    /// observed: layout writes it on every pass, and redrawing a list on that
    /// would re-render the Display pane's template fields under the reader's
    /// cursor.
    @ObservationIgnored private var rowFrames: [ID: CGRect] = [:]

    @ObservationIgnored private var drag: Drag?

    /// The order and row positions a drag started from, and the slot the row
    /// has been moved to so far.
    ///
    /// The target slot is recomputed from these on every pointer event.
    /// Comparing against the neighbours' current positions instead would make a
    /// pointer resting on a boundary swap back and forth, because each swap
    /// moves the neighbour that the comparison just used.
    private struct Drag {
        let order: [ID]
        let frames: [ID: CGRect]
        /// Index of the dragged row in `order`.
        let origin: Int
        var slot: Int
    }

    /// Records where a row was laid out. Call it from `reorderableRow(_:id:)`
    /// rather than directly.
    func rowDidLayout(_ frame: CGRect, id: ID) {
        rowFrames[id] = frame
    }

    /// Starts a drag of `id`. `order` must index the same array the `move`
    /// passed to `dragMoved(to:move:)` applies to.
    func beginDrag(_ id: ID, in order: [ID]) {
        guard let origin = order.firstIndex(of: id) else { return }
        drag = Drag(order: order, frames: rowFrames, origin: origin, slot: origin)
        draggedID = id
    }

    /// Moves the dragged row to the slot the pointer has reached, `y` being its
    /// position in window coordinates. `move` runs only when that slot changed,
    /// so a drag across one boundary is one move.
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

    /// Slot the pointer is over: the number of rows other than the dragged one
    /// whose center it has passed. A row no layout has reported counts as
    /// sitting below the pointer, so it leaves the slot where it is.
    private func targetSlot(at y: CGFloat, _ drag: Drag) -> Int {
        drag.order.enumerated()
            .filter { $0.offset != drag.origin }
            .filter { (drag.frames[$0.element]?.midY ?? .infinity) < y }
            .count
    }
}

/// The handle a row is dragged by, for the leading edge of the row.
///
/// Dragging it reorders live; the accessibility actions move the row one slot,
/// which is the only way to reorder without a pointer.
struct RowGrabber<ID: Hashable>: View {
    let id: ID
    /// The rows the drag moves within, in the order `move` indexes.
    let order: [ID]
    let reorder: RowReorder<ID>
    /// Applies one move to the array behind the rows.
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
    /// Reports this row's position to `reorder`, which is how a drag tells
    /// which slot the pointer has reached. Every row of the run needs it, and
    /// each row needs a `RowGrabber` to be draggable.
    func reorderableRow<ID: Hashable>(_ reorder: RowReorder<ID>, id: ID) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            reorder.rowDidLayout(frame, id: id)
        }
    }
}
