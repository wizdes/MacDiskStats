import AppKit

@MainActor final class StatusProgressView: NSProgressIndicator {
    var fillWidth: CGFloat { bounds.width * CGFloat(min(1, max(0, doubleValue / max(1, maxValue)))) }
    override var doubleValue: Double { didSet { needsDisplay = true } }
    override var isIndeterminate: Bool { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if isIndeterminate { super.draw(dirtyRect); return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Tokens.progressTrack(dark).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        Tokens.progressFill(dark).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}
