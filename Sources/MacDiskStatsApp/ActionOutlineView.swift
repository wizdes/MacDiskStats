import AppKit

@MainActor final class ActionOutlineView: NSOutlineView {
    var onMenu: ((Int32) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0, let id = item(atRow: index) as? NSNumber else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return onMenu?(id.int32Value)
    }
}
