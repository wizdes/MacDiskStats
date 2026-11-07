#if DEBUG
import AppKit

@MainActor enum DebugSnapshot {
    static func capture(window: NSWindow, path: String, sheet: NSWindow? = nil) {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/dev.yili.MacDiskStats/Data/Library/Application Support", isDirectory: true)
        let allowed = ProcessInfo.processInfo.environment["MACDISKSTATS_SNAPSHOT_DIR"] ?? container.path
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard !allowed.isEmpty, destination.path.hasPrefix(URL(fileURLWithPath: allowed).standardizedFileURL.path + "/") else {
            fputs("snapshot path is outside the allowed directory\n", stderr)
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(Tokens.snapshotSize)
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
                let context = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let x = (rect.width - sheetRect.width) / 2
                let y = rect.height - sheetRect.height
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 1, y: y - 1, width: sheetRect.width + 2, height: sheetRect.height + 2), xRadius: 9, yRadius: 9).fill()
                sheetRep.draw(in: NSRect(x: x, y: y, width: sheetRect.width, height: sheetRect.height))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { NSApp.terminate(nil); return }
        do {
            if ProcessInfo.processInfo.environment["MACDISKSTATS_SNAPSHOT_DIR"] == nil {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            }
            try png.write(to: destination)
            exit(0)
        }
        catch { fputs("snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }
}
#endif
