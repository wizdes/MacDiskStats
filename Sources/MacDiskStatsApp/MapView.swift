import AppKit
import DiskCore

@MainActor final class MapView: NSView {
    var onSelect: ((Int32) -> Void)?
    var onHover: ((Int32?) -> Void)?
    var onDoubleClick: ((Int32) -> Void)?
    var onContextMenu: ((Int32) -> NSMenu?)?
    var onResize: (() -> Void)?
    var layoutData: TreemapLayout? { didSet { updateFrame() } }
    var selectedNode: Int32? { didSet { updateFrame() } }
    private let imageLayer = CALayer()
    private let frameLayer = CAShapeLayer()
    private var area: NSTrackingArea?
    var dark = false { didSet { layer?.backgroundColor = Tokens.mapBackground(dark).cgColor; updateFrame() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(frameLayer)
        layer?.backgroundColor = Tokens.mapBackground(false).cgColor
        imageLayer.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        frameLayer.frame = bounds
        updateFrame()
        onResize?()
    }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
        if let area { addTrackingArea(area) }
        super.updateTrackingAreas()
    }
    func show(_ rgba: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { imageLayer.contents = nil; return }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        imageLayer.contents = image
        imageLayer.contentsScale = window?.backingScaleFactor ?? 1
    }
    private func hit(_ point: NSPoint) -> Int32? {
        guard let layoutData, bounds.width > 0, bounds.height > 0 else { return nil }
        let x = Int(point.x / bounds.width * CGFloat(layoutData.width))
        let y = Int(point.y / bounds.height * CGFloat(layoutData.height))
        return layoutData.hitTest(x: x, y: y)
    }
    override func mouseMoved(with event: NSEvent) { onHover?(hit(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        guard let node = hit(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount > 1 { onDoubleClick?(node) } else { onSelect?(node) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node = hit(convert(event.locationInWindow, from: nil)) else { return nil }
        onSelect?(node)
        return onContextMenu?(node)
    }
    private func updateFrame() {
        guard let selectedNode, let layoutData, let box = layoutData.rect(of: selectedNode),
              layoutData.width > 0, layoutData.height > 0 else { frameLayer.path = nil; return }
        let sx = bounds.width / CGFloat(layoutData.width), sy = bounds.height / CGFloat(layoutData.height)
        let rect = NSRect(x: CGFloat(box.x) * sx + Tokens.mapFrameInset,
                          y: bounds.height - CGFloat(box.y + box.height) * sy + Tokens.mapFrameInset,
                          width: max(0, CGFloat(box.width) * sx - 2 * Tokens.mapFrameInset),
                          height: max(0, CGFloat(box.height) * sy - 2 * Tokens.mapFrameInset))
        frameLayer.path = CGPath(rect: rect, transform: nil)
        frameLayer.fillColor = nil
        frameLayer.strokeColor = Tokens.frame(dark).cgColor
        frameLayer.lineWidth = Tokens.mapFrameWidth
        frameLayer.shadowColor = Tokens.frameShadow(dark).cgColor
        frameLayer.shadowOpacity = 1
        frameLayer.shadowRadius = Tokens.mapFrameWidth
    }
}
