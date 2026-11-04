#if DEBUG
import AppKit

@MainActor enum DebugSnapshot {
    static func capture(window: NSWindow, path: String) {
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
        guard let png = rep.representation(using: .png, properties: [:]) else { NSApp.terminate(nil); return }
        do {
            if ProcessInfo.processInfo.environment["MACDISKSTATS_SNAPSHOT_DIR"] == nil {
                try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            }
            try png.write(to: destination)
            NSApp.terminate(nil)
        }
        catch { fputs("snapshot failed: \(error)\n", stderr); NSApp.terminate(nil) }
    }
}
#endif
