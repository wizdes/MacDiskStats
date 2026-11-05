import AppKit

@MainActor final class ActionOutlineView: NSOutlineView {
    var onMenu: ((Int32) -> NSMenu?)?
    private(set) var pointerInside = false
    private(set) var acting = false
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        if let hoverArea { addTrackingArea(hoverArea) }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; super.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { pointerInside = false; super.mouseExited(with: event) }
    override func mouseDown(with event: NSEvent) { acting = true; super.mouseDown(with: event); acting = false }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0, let id = item(atRow: index) as? NSNumber else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return onMenu?(id.int32Value)
    }
}
