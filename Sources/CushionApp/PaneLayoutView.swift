import AppKit

@MainActor final class PaneLayoutView: NSView {
    let treeScroll: NSScrollView
    let typeScroll: NSScrollView
    let map: MapView
    private let horizontal = DragHandle()
    private let vertical = DragHandle()
    private var topRatio: CGFloat = Tokens.topFraction
    private var treeRatio: CGFloat = Tokens.treeFraction
    var onResize: (() -> Void)?

    init(frame: NSRect, tree: NSScrollView, types: NSScrollView, map: MapView) {
        treeScroll = tree; typeScroll = types; self.map = map
        super.init(frame: frame)
        addSubview(tree); addSubview(types); addSubview(map)
        addSubview(horizontal); addSubview(vertical)
        horizontal.vertical = false
        vertical.vertical = true
        horizontal.onDrag = { [weak self] point in
            guard let self else { return }
            let height = min(max(self.bounds.height - point.y, Tokens.minTopHeight), self.bounds.height - Tokens.minMapHeight)
            self.topRatio = height / max(1, self.bounds.height)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        vertical.onDrag = { [weak self] point in
            guard let self else { return }
            let width = min(max(point.x, Tokens.minTreeWidth), self.bounds.width - Tokens.minTypesWidth)
            self.treeRatio = width / max(1, self.bounds.width)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        let topHeight = min(max(bounds.height * topRatio, Tokens.minTopHeight), max(Tokens.minTopHeight, bounds.height - Tokens.minMapHeight))
        let treeWidth = min(max(bounds.width * treeRatio, Tokens.minTreeWidth), max(Tokens.minTreeWidth, bounds.width - Tokens.minTypesWidth))
        let separator = Tokens.splitThickness
        let mapHeight = max(0, bounds.height - topHeight - separator)
        map.frame = NSRect(x: 0, y: 0, width: bounds.width, height: mapHeight)
        treeScroll.frame = NSRect(x: 0, y: mapHeight + separator, width: treeWidth, height: topHeight)
        typeScroll.frame = NSRect(x: treeWidth + separator, y: mapHeight + separator,
                                  width: max(0, bounds.width - treeWidth - separator), height: topHeight)
        horizontal.frame = NSRect(x: 0, y: mapHeight - (Tokens.splitHitSize - separator) / 2,
                                  width: bounds.width, height: Tokens.splitHitSize)
        vertical.frame = NSRect(x: treeWidth - (Tokens.splitHitSize - separator) / 2,
                                y: mapHeight + separator, width: Tokens.splitHitSize, height: topHeight)
        onResize?()
    }
}

@MainActor private final class DragHandle: NSView {
    var vertical = false
    var onDrag: ((NSPoint) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil))
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Tokens.separator(dark).setFill()
        if vertical {
            NSRect(x: (bounds.width - Tokens.splitThickness) / 2, y: 0,
                   width: Tokens.splitThickness, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: (bounds.height - Tokens.splitThickness) / 2,
                   width: bounds.width, height: Tokens.splitThickness).fill()
        }
    }
}
