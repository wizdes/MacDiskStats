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
    private let previewLayer = CALayer()
    private var previewBoxes: [(CGRect, Int32)] = []
    var hasPreview: Bool { !previewBoxes.isEmpty }
    private let frameLayer = CAShapeLayer()
    private var area: NSTrackingArea?
    var dark = false { didSet { layer?.backgroundColor = Tokens.mapBackground(dark).cgColor; updateFrame() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(previewLayer)
        layer?.addSublayer(frameLayer)
        layer?.backgroundColor = Tokens.mapBackground(false).cgColor
        imageLayer.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        previewLayer.frame = bounds
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
        previewLayer.sublayers = nil
        previewBoxes = []
        imageLayer.contentsScale = window?.backingScaleFactor ?? 1
    }
    func clearPreview() { previewLayer.sublayers = nil; previewBoxes = [] }
    func showPreview(rows: [LiveNode], children: [Int32: [LiveNode]], extensions: [ExtensionTotal], mapTypes: [Int32: [ExtensionTotal]], remainder: Int64) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = Array(rows.filter { $0.bytes > 0 || $0.isDirectory }.prefix(Tokens.livePreviewLimit))
        guard !visible.isEmpty || remainder > 0 else { clearPreview(); return }
        func visibleBytes(_ item: LiveNode) -> Int64 { max(item.bytes, mapTypes[item.id]?.reduce(0) { $0 + $1.bytes } ?? 0, 1) }
        let sum = visible.reduce(Double(remainder)) { $0 + Double(visibleBytes($1)) }
        let colors = Dictionary(uniqueKeysWithValues: extensions.enumerated().map { ($0.element.name, $0.offset) })
        var x: CGFloat = 0
        var boxes: [(CGRect, Int32)] = []
        var layers: [CALayer] = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for item in visible {
            let width = bounds.width * CGFloat(Double(visibleBytes(item)) / max(1, sum))
            let rect = CGRect(x: x, y: 0, width: max(0, width), height: bounds.height)
            let folder = cushion(rect: rect, color: item.isDirectory ? Tokens.liveFolder(dark) : Tokens.color(for: colors[item.extensionName] ?? -1, dark: dark), sizing: item.isSizing)
            layers.append(folder)
            if item.isDirectory {
                let contents = children[item.id] ?? []
                let direct = contents.filter { !$0.isDirectory && $0.bytes > 0 }.map { (name: $0.extensionName, bytes: $0.bytes) }
                let items = Array((mapTypes[item.id]?.map { (name: $0.name, bytes: $0.bytes) } ?? direct).prefix(Tokens.liveTypeLimit))
                let known = items.reduce(Double(0)) { $0 + Double($1.bytes) }
                if known > 0 {
                    var y: CGFloat = 0
                    for child in items {
                        let height = rect.height * CGFloat(Double(child.bytes) / known)
                        let childRect = CGRect(x: rect.minX + Tokens.liveBoxGap, y: y + Tokens.liveBoxGap,
                                               width: max(0, rect.width - 2 * Tokens.liveBoxGap), height: max(0, height - 2 * Tokens.liveBoxGap))
                        if childRect.width > Tokens.liveMinimumBoxSide && childRect.height > Tokens.liveMinimumBoxSide {
                            layers.append(cushion(rect: childRect, color: Tokens.color(for: colors[child.name] ?? -1, dark: dark), sizing: false))
                        }
                        y += height
                    }
                }
            }
            boxes.append((rect, item.id))
            x += width
        }
        if remainder > 0 {
            layers.append(cushion(rect: CGRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height), color: Tokens.liveFolder(dark), sizing: false))
        }
        previewLayer.sublayers = layers
        previewBoxes = boxes
        CATransaction.commit()
    }
    private func cushion(rect: CGRect, color: NSColor, sizing: Bool) -> CALayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = Tokens.liveGradientStart
        layer.endPoint = Tokens.liveGradientEnd
        layer.frame = rect.insetBy(dx: Tokens.liveBoxGap / 2, dy: Tokens.liveBoxGap / 2)
        layer.cornerRadius = Tokens.liveBoxRadius
        layer.masksToBounds = true
        let highlight = color.blended(withFraction: Tokens.liveCushionHighlight, of: .white) ?? color
        let shade = color.blended(withFraction: Tokens.liveCushionShade, of: .black) ?? color
        layer.colors = [highlight.cgColor, color.cgColor, shade.cgColor]
        layer.opacity = sizing ? Tokens.liveSizingOpacity : 1
        if sizing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let shimmer = CABasicAnimation(keyPath: "opacity")
            shimmer.fromValue = Tokens.liveShimmerLow
            shimmer.toValue = Tokens.liveSizingOpacity
            shimmer.duration = Tokens.liveShimmerDuration
            shimmer.autoreverses = true
            shimmer.repeatCount = .infinity
            layer.add(shimmer, forKey: "sizing")
        }
        return layer
    }
    func showPreview(_ totals: [(path: String, bytes: Int64)], root: String) {
        let folders = totals.filter { item in
            let relative = root == "/" ? String(item.path.dropFirst()) : String(item.path.dropFirst(root.count + 1))
            return item.bytes > 0 && !relative.contains("/")
        }.sorted { $0.bytes > $1.bytes }.prefix(24)
        let sum = folders.reduce(Int64(0)) { $0 + $1.bytes }
        guard sum > 0, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var x: CGFloat = 0
        previewLayer.sublayers = folders.enumerated().map { index, item in
            let block = CALayer()
            let width = index == folders.count - 1 ? bounds.width - x : bounds.width * CGFloat(item.bytes) / CGFloat(sum)
            block.frame = CGRect(x: x, y: 0, width: max(0, width), height: bounds.height)
            block.backgroundColor = NSColor(calibratedHue: CGFloat((index * 37) % 100) / 100, saturation: dark ? 0.33 : 0.26, brightness: dark ? 0.39 : 0.79, alpha: 1).cgColor
            block.borderColor = Tokens.mapBackground(dark).cgColor
            block.borderWidth = 1
            x += width
            return block
        }
        CATransaction.commit()
    }
    private func hit(_ point: NSPoint) -> Int32? {
        if layoutData == nil { return previewBoxes.first { $0.0.contains(point) }?.1 }
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
        let touchesBoundary = box.x <= 0 || box.y <= 0 || box.x + box.width >= layoutData.width || box.y + box.height >= layoutData.height
        frameLayer.shadowOpacity = touchesBoundary ? 0 : 1
        frameLayer.shadowRadius = Tokens.mapFrameWidth
    }

    func selectionFrameBounds() -> CGRect? { frameLayer.path?.boundingBox }
}
