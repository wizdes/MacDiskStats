#if DEBUG
import AppKit

@MainActor enum DebugSnapshot {
    static func capture(window: NSWindow, path: String, sheet: NSWindow? = nil, size: NSSize? = nil) {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/dev.yili.MacDiskStats/Data/Library/Application Support", isDirectory: true)
        let allowed = ProcessInfo.processInfo.environment["MACDISKSTATS_SNAPSHOT_DIR"] ?? container.path
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard !allowed.isEmpty, destination.path.hasPrefix(URL(fileURLWithPath: allowed).standardizedFileURL.path + "/") else {
            fputs("snapshot path is outside the allowed directory\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let windowMode = ProcessInfo.processInfo.environment["MACDISKSTATS_SNAPSHOT_WINDOW"] == "1"
        window.setContentSize(size ?? Tokens.snapshotSize)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView else { NSApp.terminate(nil); return }
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in: rect, to: rep)
        if let sheet, let sheetView = sheet.contentView {
            sheetView.layoutSubtreeIfNeeded()
            let sheetRect = sheetView.bounds
            if let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetRect) {
                sheetView.cacheDisplay(in: sheetRect, to: sheetRep)
                if windowMode, let button = sheet.defaultButtonCell?.controlView as? NSButton {
                    activeDefaultButton(button, in: sheetView, rep: sheetRep, appearance: sheet.effectiveAppearance)
                }
                let context = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let x = (rect.width - sheetRect.width) / 2
                if windowMode {
                    // A floating rounded card with a shadow, as macOS 26 shows a sheet.
                    let card = NSRect(x: x, y: rect.height - sheetRect.height - 10, width: sheetRect.width, height: sheetRect.height)
                    let shape = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -6); shadow.set()
                    NSColor.windowBackgroundColor.setFill(); shape.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    NSGraphicsContext.saveGraphicsState(); shape.addClip(); sheetRep.draw(in: card); NSGraphicsContext.restoreGraphicsState()
                    NSColor.separatorColor.setStroke(); shape.lineWidth = 0.5; shape.stroke()
                } else {
                    let y = rect.height - sheetRect.height
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x - 1, y: y - 1, width: sheetRect.width + 2, height: sheetRect.height + 2), xRadius: 9, yRadius: 9).fill()
                    sheetRep.draw(in: NSRect(x: x, y: y, width: sheetRect.width, height: sheetRect.height))
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let output = windowMode ? (wholeWindow(window, content: rep) ?? rep) : rep
        guard let png = output.representation(using: .png, properties: [:]) else { NSApp.terminate(nil); return }
        do {
            if ProcessInfo.processInfo.environment["MACDISKSTATS_SNAPSHOT_DIR"] == nil {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            }
            try png.write(to: destination)
            exit(0)
        }
        catch { fputs("snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }

    /// Offscreen, the sheet is not key, so its default button draws grey. Paint it as a key sheet shows it: accent fill, white title.
    private static func activeDefaultButton(_ button: NSButton, in sheetView: NSView, rep: NSBitmapImageRep, appearance: NSAppearance) {
        let frame = button.convert(button.bounds, to: sheetView)
        // Measure the grey bezel the system actually drew, so the blue one has the same size and place as its neighbors.
        let scale = CGFloat(rep.pixelsWide) / sheetView.bounds.width
        let px = { (v: CGFloat) in Int((v * scale).rounded()) }
        let top = { (y: CGFloat) in Int(((sheetView.bounds.height - y) * scale).rounded()) }
        guard let background = rep.colorAt(x: px(frame.minX) - 3, y: top(frame.midY))?.usingColorSpace(.deviceRGB) else { return }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in top(frame.maxY)..<top(frame.minY) {
            for x in px(frame.minX)..<px(frame.maxX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(c.redComponent - background.redComponent) + abs(c.greenComponent - background.greenComponent) + abs(c.blueComponent - background.blueComponent) > 0.06 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { fputs("snapshot: default button bezel not found; it stays grey\n", stderr); return }
        let bezel = NSRect(x: CGFloat(minX) / scale, y: sheetView.bounds.height - CGFloat(maxY + 1) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bezel, xRadius: min(bezel.height / 2, 7), yRadius: min(bezel.height / 2, 7)).fill()
            let title = NSAttributedString(string: button.title, attributes: [.font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.white])
            let size = title.size()
            title.draw(at: NSPoint(x: bezel.midX - size.width / 2, y: bezel.midY - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The whole window for marketing shots: title bar, rounded corners and a soft shadow on a clear background.
    /// `content` is the already-drawn content view (with any sheet), placed over the frame's content area.
    private static func wholeWindow(_ window: NSWindow, content: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let contentView = window.contentView, let frameView = contentView.superview else {
            fputs("snapshot: no window frame view; writing the content only\n", stderr)
            return nil
        }
        // The sheet is already drawn into `content`. Detach it so the title bar draws in its normal color, not the sheet-parent grey.
        if let attached = window.attachedSheet { window.endSheet(attached) }
        // Offscreen, the window is not in front, so its title draws faded. Draw it in the normal label color.
        func titleFields(_ view: NSView) -> [NSTextField] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? titleFields($0) } }
        let titleField = titleFields(frameView).first { $0.stringValue == window.title && !$0.isDescendant(of: contentView) }
        if titleField == nil { fputs("snapshot: title field not found; the title stays faded\n", stderr) }
        frameView.layoutSubtreeIfNeeded()
        let frameRect = frameView.bounds
        guard let frameRep = frameView.bitmapImageRepForCachingDisplay(in: frameRect) else { return nil }
        frameView.cacheDisplay(in: frameRect, to: frameRep)
        let scale = CGFloat(frameRep.pixelsWide) / frameRect.width
        let margin: CGFloat = 40, radius: CGFloat = 16
        let canvas = NSSize(width: frameRect.width + margin * 2, height: frameRect.height + margin * 2)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = canvas
        let body = NSRect(x: margin, y: margin, width: frameRect.width, height: frameRect.height)
        let contentRect = contentView.convert(contentView.bounds, to: frameView).offsetBy(dx: margin, dy: margin)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            frameRep.draw(in: body)
            content.draw(in: contentRect)
            if let field = titleField, let font = field.font {
                // Cover the faded title with the title bar's own color, then draw it in the front-window label color.
                let r = field.convert(field.bounds, to: frameView)
                // The patch is copied from the empty right end of the same title bar, so it matches exactly.
                let patch = NSRect(x: frameRect.maxX - r.width - 24, y: r.minY, width: r.width, height: r.height)
                frameRep.draw(in: NSRect(x: r.minX + margin, y: r.minY + margin, width: r.width, height: r.height), from: patch, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
                let title = NSAttributedString(string: window.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                let size = title.size()
                title.draw(at: NSPoint(x: r.minX + margin + 2, y: r.midY + margin - size.height / 2))
            }
            // An offscreen window draws its title-bar buttons in the inactive grey; paint them as a front window shows them.
            let colors: [(NSWindow.ButtonType, NSColor)] = [(.closeButton, NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1)), (.miniaturizeButton, NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)), (.zoomButton, NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1))]
            for (type, color) in colors {
                guard let button = window.standardWindowButton(type), button.superview != nil else { continue }
                let r = button.convert(button.bounds, to: frameView).offsetBy(dx: margin, dy: margin)
                let side = min(r.width, r.height)
                let dot = NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
                color.setFill(); NSBezierPath(ovalIn: dot).fill()
                color.blended(withFraction: 0.25, of: .black)?.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            let edge = NSBezierPath(roundedRect: body.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            edge.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        return out
    }
}
#endif
