import Foundation
import Darwin
import DiskCore

private final class LiveScanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LiveScan?
    func set(_ scan: LiveScan) { lock.withLock { value = scan } }
    func get() -> LiveScan? { lock.withLock { value } }
}
private final class ScanCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Bool, Never>?
    private var progressSeen = false
    func set(_ value: Task<Bool, Never>) { lock.withLock { task = value } }
    func cancelOnProgress(_ done: Int) {
        lock.withLock {
            if done > 0 { progressSeen = true; task?.cancel() }
        }
    }
    func didSeeProgress() -> Bool { lock.withLock { progressSeen } }
}
private final class SnapshotCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var finished = false
    func record() { lock.withLock { count += 1 } }
    func stop() { lock.withLock { finished = true } }
    func state() -> (Int, Bool) { lock.withLock { (count, finished) } }
}

@MainActor func runExtendedChecks(base: URL) async -> (tests: Int, failures: Int) {
    let fm = FileManager.default
    var tests = 0, failures = 0
    func verify(_ name: String, _ good: Bool) {
        tests += 1
        print("\(good ? "PASS" : "FAIL") bug: \(name)")
        if !good { failures += 1 }
    }
    func folder(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func scan(_ url: URL, twoPhase: Bool = true) async throws -> FileTree {
        try await DiskCore.Scanner.scan(root: url.path, options: ScanOptions(workers: 2, twoPhase: twoPhase))
    }
    func put(_ url: URL, _ count: Int = 4096) throws {
        try Data(repeating: 1, count: count).write(to: url)
    }
    func child(_ tree: FileTree, _ name: String) -> Int32? {
        tree.children.first { tree.path(of: $0).split(separator: "/").last == Substring(name) }
    }
    do {
        let dir = try folder("extra-live")
        let target = dir.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try put(target.appendingPathComponent("one.txt"))
        let seen = LiveScanBox()
        let result = try await DiskCore.Scanner.scan(root: dir.path, options: ScanOptions(workers: 1), live: { model in
            seen.set(model)
        })
        let model = seen.get()
        let liveFrame = model?.snapshot(childrenOf: [0])
        verify("live frame totals disagree across tree types and status", liveFrame.map { frame in
            frame.countedBytes == frame.extensions.reduce(0) { $0 + $1.bytes } &&
            frame.children[0]?.first(where: { $0.name == "target" })?.bytes == frame.countedBytes
        } == true)
        let rootRows = model?.children(of: 0) ?? []
        let targetRow = rootRows.first { $0.name == "target" }
        verify("live root rows missing before final tree", targetRow != nil)
        verify("live folder never becomes complete", targetRow.flatMap { model?.node($0.id) }?.isSizing == false)
        verify("live IDs differ from final tree", targetRow.map { result.path(of: $0.id).hasSuffix("/target") } == true)
    } catch { verify("live scan setup: \(error)", false) }
    do {
        let root = try folder("bug-live-ancestor-growth")
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        for i in 0..<12_000 { try put(inner.appendingPathComponent("f\(i)"), 4096) }
        let box = LiveScanBox()
        let task = Task { try await Scanner.scan(root: root.path, options: ScanOptions(workers: 1, twoPhase: false), live: { box.set($0) }) }
        var sawMidScan = false
        for _ in 0..<2000 {
            if let model = box.get(), let outer = model.children(of: 0).first(where: { $0.name == "outer" }),
               let inner = model.children(of: outer.id).first(where: { $0.name == "inner" }) {
                let frame = model.snapshot(childrenOf: [0, outer.id])
                if inner.bytes > 0 && inner.isSizing {
                    sawMidScan = true
                    verify("live ancestor bytes stay zero during descendant scan", frame.children[0]?.first?.bytes == inner.bytes && frame.countedBytes >= inner.bytes)
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await task.value
        verify("live ancestor sampled during active scan", sawMidScan)
    } catch { verify("live ancestor setup: \(error)", false) }
    do {
        let dir = try folder("bug-live-unreadable")
        let blocked = dir.appendingPathComponent("blocked")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        guard chmod(blocked.path, 0) == 0 else { throw Scanner.ScanError.cannotOpen(blocked.path, errno) }
        defer { _ = chmod(blocked.path, 0o700) }
        let box = LiveScanBox()
        _ = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false), live: { box.set($0) })
        let unreadable = box.get()?.children(of: 0).first(where: { $0.name == "blocked" })
        verify("live unreadable directory appears empty and successful", unreadable?.isUnreadable == true && unreadable?.isSizing == false)
    } catch { verify("live unreadable setup: \(error)", false) }
    do {
        let dir = try folder("bug-cancelled-render")
        try put(dir.appendingPathComponent("box.bin"), 1_000_000)
        let tree = try await scan(dir, twoPhase: false)
        let work = Task.detached { () -> Int in
            let layout = Treemap.layout(tree: tree, rootNode: 0, widthPx: 1600, heightPx: 1200)
            var pixels: [UInt8] = []
            Treemap.shade(layout, into: &pixels)
            return pixels.count
        }
        work.cancel()
        let count = await work.value
        verify("cancelled render still shades full image", count == 0)
    } catch { verify("cancelled render setup: \(error)", false) }
    do {
        let dir = try folder("extra-priority")
        for i in 0..<500 {
            let sub = dir.appendingPathComponent(String(format: "%04d", i), isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        let box = LiveScanBox()
        let scanTask = Task { try await DiskCore.Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false), live: { box.set($0) }) }
        var target: Int32?, completedAtRequest = 0
        for _ in 0..<500 {
            if let model = box.get(), let row = model.children(of: 0).first(where: { $0.name == "0499" }) {
                target = row.id; completedAtRequest = model.completedDirectories; model.prioritize(row.id); break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await scanTask.value
        let row = target.flatMap { box.get()?.node($0) }
        verify("priority target is known and finished", row != nil && row?.isSizing == false)
        // One worker finishes the root before any child. Priority should finish the last child second.
        let order = target.flatMap { box.get()?.completionOrder(of: $0) } ?? 0
        print("priority target finished at directory \(order) of 501; \(completedAtRequest) were done when requested (without priority: about 501)")
        verify("priority request leaves target at queue tail", order > 0 && order <= completedAtRequest + 2)
    } catch { verify("priority scan setup: \(error)", false) }
    do {
        let dir = try folder("bug-priority-subtree")
        for i in 0..<150 {
            let sub = dir.appendingPathComponent(String(format: "%03d", i))
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<200 {
                let fd = open(sub.appendingPathComponent("f\(f)").path, O_CREAT | O_WRONLY, 0o600)
                guard fd >= 0 else { throw Scanner.ScanError.cannotOpen(sub.path, errno) }
                close(fd)
            }
        }
        let target = dir.appendingPathComponent("149")
        for i in 0..<40 {
            let sub = target.appendingPathComponent(String(format: "child%03d", i))
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<200 {
                let fd = open(sub.appendingPathComponent("f\(f)").path, O_CREAT | O_WRONLY, 0o600)
                guard fd >= 0 else { throw Scanner.ScanError.cannotOpen(sub.path, errno) }
                close(fd)
            }
        }
        let box = LiveScanBox()
        let started = Date()
        let task = Task { try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false), live: { box.set($0) }) }
        var targetID: Int32?
        var requestedAt = started
        for _ in 0..<500 {
            if let model = box.get(), let row = model.children(of: 0).first(where: { $0.name == "149" }) { targetID = row.id; requestedAt = Date(); model.prioritize(row.id); break }
            try await Task.sleep(for: .milliseconds(1))
        }
        var priorityDone: Date?
        for _ in 0..<5000 {
            if let targetID, let model = box.get() {
                let children = model.children(of: targetID).filter(\.isDirectory)
                if children.count == 40 && children.allSatisfy({ (model.completionOrder(of: $0.id) ?? 0) > 0 }) { priorityDone = Date(); break }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await task.value
        let model = box.get()
        let orders = targetID.flatMap { id in model?.children(of: id).filter(\.isDirectory).compactMap { model?.completionOrder(of: $0.id) } } ?? []
        let targetOrder = targetID.flatMap { model?.completionOrder(of: $0) } ?? -1
        print("subtree priority: \(orders.count) descendants, last order \(orders.max() ?? -1), target order \(targetOrder)")
        verify("expanded subtree descendants stay behind unrelated folders", orders.count == 40 && (orders.max() ?? 1000) <= targetOrder + 40)
        let controlBox = LiveScanBox()
        let control = Task { try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false), live: { controlBox.set($0) }) }
        var controlID: Int32?, controlRequested = Date()
        for _ in 0..<500 {
            if let model = controlBox.get(), let row = model.children(of: 0).first(where: { $0.name == "149" }) { controlID = row.id; controlRequested = Date(); break }
            try await Task.sleep(for: .milliseconds(1))
        }
        var controlDone: Date?
        for _ in 0..<5000 {
            if let controlID, let model = controlBox.get() {
                let children = model.children(of: controlID).filter(\.isDirectory)
                if children.count == 40 && children.allSatisfy({ (model.completionOrder(of: $0.id) ?? 0) > 0 }) { controlDone = Date(); break }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await control.value
        if let priorityDone, let controlDone {
            print(String(format: "subtree priority measured on 38,000 files: expanded %.3f s, ordinary queue %.3f s", priorityDone.timeIntervalSince(requestedAt), controlDone.timeIntervalSince(controlRequested)))
        }
        verify("subtree priority timing reaches completed descendants", priorityDone != nil && controlDone != nil)
        let cancelBox = LiveScanBox()
        let activeTask = Task { () -> Bool in
            do {
                _ = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false, bufferSize: 4096), live: { cancelBox.set($0) })
                return false
            } catch DiskCore.Scanner.ScanError.cancelled { return true }
            catch { return false }
        }
        var cancelledActiveWorker = false
        for _ in 0..<1000 {
            if let model = cancelBox.get(), model.completedDirectories > 2 && model.completedDirectories < 190 {
                cancelledActiveWorker = true; activeTask.cancel(); break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didCancel = await activeTask.value
        verify("active worker ignores cancellation", cancelledActiveWorker && didCancel)
    } catch { verify("subtree priority setup: \(error)", false) }
    do {
        let dir = try folder("bug-vanished-live-pending")
        for i in 0..<300 { try fm.createDirectory(at: dir.appendingPathComponent(String(format: "d%03d", i)), withIntermediateDirectories: true) }
        let vanished = dir.appendingPathComponent("zz-vanished")
        try fm.createDirectory(at: vanished, withIntermediateDirectories: true)
        let box = LiveScanBox()
        let task = Task { try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false, bufferSize: 4096), live: { box.set($0) }) }
        var removed = false
        for _ in 0..<500 {
            if let model = box.get(), let row = model.children(of: 0).first(where: { $0.name == "zz-vanished" }), model.completionOrder(of: row.id) == 0 {
                try fm.removeItem(at: vanished); removed = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await task.value
        let row = box.get()?.children(of: 0).first(where: { $0.name == "zz-vanished" })
        verify("vanished live folder stays sizing or looks successful", removed && row?.isUnreadable == true && row?.isSizing == false && box.get()?.node(0)?.isSizing == false)
    } catch { verify("vanished live folder setup: \(error)", false) }
    verify("Int32 name and node limits", Scanner.indexFits(Int(Int32.max)) && !Scanner.indexFits(Int(Int32.max), appending: 1) && !Scanner.indexFits(Int(Int32.max) + 1))
    do {
        let empty = try folder("extra-empty")
        let tree = try await scan(empty)
        verify("empty folder invents children", tree.parent.count == 1 && tree.filesSeen == 0 && tree.countedSize[0] == 0)
        let file = base.appendingPathComponent("extra-root-file")
        try put(file)
        for (label, path) in [("file root accepted", file.path), ("missing root lacks clear error", base.appendingPathComponent("missing-root").path)] {
            do { _ = try await DiskCore.Scanner.scan(root: path); verify(label, false) }
            catch let error as DiskCore.Scanner.ScanError {
                if case .cannotOpen(let failedPath, let code) = error { verify(label, failedPath == path && code != 0) }
                else { verify(label, false) }
            }
            catch { verify(label, false) }
        }
    } catch { verify("empty and bad roots setup: \(error)", false) }
    do {
        let dir = try folder("extra-names")
        for name in ["white space.txt", "emoji-😀.PNG", ".bashrc", "a.", "a.tar.gz", "NOEXT", ".hidden"] { try put(dir.appendingPathComponent(name)) }
        let tree = try await scan(dir)
        verify("spaces emoji and leading dots lost", tree.filesSeen == 7)
        let expected = [".bashrc": "", "a.": "", "a.tar.gz": "gz", "NOEXT": ""]
        verify("extension suffix parsing is wrong", expected.allSatisfy { name, ext in
            guard let id = child(tree, name), tree.extensionIndex[Int(id)] >= 0 else { return false }
            return tree.extensions[Int(tree.extensionIndex[Int(id)])].name == ext
        })
        verify("uppercase extension does not fold to lowercase", tree.extensions.contains { $0.name == "png" })
        verify("invalid UTF8 byte identity", FileTree.displayName(bytes: [0xff]) != FileTree.displayName(bytes: [0xfe]))
        let rawPath = Array("/tmp/invalid-".utf8) + [0xff]
        let recovered = FileTree.pathBytes(root: "/tmp", components: [Array("invalid-".utf8) + [0xff]])
        verify("invalid UTF8 path keeps file bytes", recovered == rawPath)
    } catch { verify("names setup: \(error)", false) }
    do {
        let dir = try folder("extra-many")
        for i in 0..<20_000 {
            let fd = open(dir.appendingPathComponent(String(i)).path, O_CREAT | O_WRONLY, 0o600)
            if fd < 0 { throw DiskCore.Scanner.ScanError.cannotOpen(dir.path, errno) }
            close(fd)
        }
        let tree = try await scan(dir)
        verify("bulk scan drops files after a buffer boundary", tree.filesSeen == 20_000 && tree.parent.count == 20_001)
        let second = try await scan(dir)
        verify("two scans reuse stale node state", second.filesSeen == tree.filesSeen && second.parent.count == tree.parent.count)
    } catch { verify("20k setup: \(error)", false) }
    do {
        let root = try folder("extra-deep")
        var at = root, made = 0
        for _ in 0..<300 {
            at.appendPathComponent("d", isDirectory: true)
            try fm.createDirectory(at: at, withIntermediateDirectories: false)
            made += 1
        }
        try put(at.appendingPathComponent("end"))
        let tree = try await scan(root, twoPhase: false)
        verify("deep scan runs out of file descriptors or stack", made == 300 && tree.dirsSeen == 301 && tree.filesSeen == 1)
    } catch { verify("deep folder setup or scan: \(error)", false) }
    do {
        let root = try folder("extra-long-path")
        var fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(root.path, errno) }
        for _ in 0..<530 {
            guard mkdirat(fd, "d", 0o700) == 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(root.path, errno) }
            let next = openat(fd, "d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(fd); fd = next
            guard fd >= 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(root.path, errno) }
        }
        let leaf = openat(fd, "end", O_CREAT | O_WRONLY, 0o600)
        guard leaf >= 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(root.path, errno) }
        close(leaf); close(fd)
        let tree = try await scan(root)
        verify("long directory path opens by component", tree.dirsSeen == 531 && tree.filesSeen == 1 && tree.unreadablePaths.isEmpty)
    } catch { verify("long directory path setup or scan: \(error)", false) }
    do {
        let dir = try folder("extra-links")
        let one = dir.appendingPathComponent("one"), two = dir.appendingPathComponent("two")
        try fm.createDirectory(at: one, withIntermediateDirectories: true)
        try fm.createDirectory(at: two, withIntermediateDirectories: true)
        let original = one.appendingPathComponent("same.bin")
        try put(original, 16_384)
        guard link(original.path, two.appendingPathComponent("same2.bin").path) == 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(dir.path, errno) }
        try fm.createSymbolicLink(atPath: two.appendingPathComponent("loop").path, withDestinationPath: "../one")
        let sparse = one.appendingPathComponent("sparse")
        let fd = open(sparse.path, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(sparse.path, errno) }
        _ = ftruncate(fd, 64 * 1024 * 1024); close(fd)
        let tree = try await scan(dir)
        var st = stat(); _ = lstat(original.path, &st)
        verify("hard links across folders counted twice", tree.countedSize[0] < Int64(st.st_blocks) * 1024)
        verify("symlink loop followed", tree.dirsSeen == 3 && tree.flags.contains(.symlink))
        verify("sparse logical size treated as allocated", tree.logicalSize[0] > tree.countedSize[0] + 60_000_000)
    } catch { verify("links and sparse setup: \(error)", false) }
    do {
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if fm.fileExists(atPath: "/Volumes/Recovery") {
            let tree = try await scan(volumes, twoPhase: false)
            let stopped = child(tree, "Recovery")
            verify("mounted volume path is stopped", stopped.map { tree.flags[Int($0)].contains(.mountPointStopped) && tree.childCount[Int($0)] == 0 } == true)
        } else {
            verify("mounted volume path is stopped", false)
        }
    } catch { verify("mounted volume path setup: \(error)", false) }
    do {
        let dir = try folder("extra-clone-chain")
        let first = dir.appendingPathComponent("first.bin")
        try put(first, 1_000_000)
        var previous = first
        for i in 1...3 {
            let next = dir.appendingPathComponent("clone\(i).bin")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/cp")
            p.arguments = ["-c", previous.path, next.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(next.path, p.terminationStatus) }
            previous = next
        }
        let tree = try await scan(dir)
        var st = stat(); _ = lstat(first.path, &st)
        verify("clone chain charges every shared copy", tree.filesSeen == 4 && tree.countedSize[0] < Int64(st.st_blocks) * 512 * 4)
        verify("phase two preserves leaf file type", tree.parent.indices.dropFirst().allSatisfy { tree.flags[$0].contains(.isDir) || tree.largestFileType[$0] == tree.extensionIndex[$0] })
    } catch { verify("clone chain setup: \(error)", false) }
    do {
        let dir = try folder("extra-clone-links")
        let first = dir.appendingPathComponent("first.bin")
        let clone = dir.appendingPathComponent("clone.bin")
        let linked = dir.appendingPathComponent("linked.bin")
        try put(first, 1_000_000)
        let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/bin/cp"); cp.arguments = ["-c", first.path, clone.path]
        try cp.run(); cp.waitUntilExit()
        guard cp.terminationStatus == 0, link(clone.path, linked.path) == 0 else { throw DiskCore.Scanner.ScanError.cannotOpen(dir.path, errno) }
        let tree = try await scan(dir)
        var st = stat(); _ = lstat(first.path, &st)
        verify("hard linked clone counted once", tree.filesSeen == 3 && tree.countedSize[0] < Int64(st.st_blocks) * 512 * 2)
    } catch { verify("hard linked clone setup: \(error)", false) }
    do {
        let dir = try folder("bug-modified-clone-hardlink")
        let original = dir.appendingPathComponent("a-original.bin")
        let clone = dir.appendingPathComponent("z-clone.bin")
        try put(original, 1_000_000)
        let cp = Process(); cp.executableURL = URL(fileURLWithPath: "/bin/cp"); cp.arguments = ["-c", original.path, clone.path]
        try cp.run(); cp.waitUntilExit()
        guard cp.terminationStatus == 0 else { throw Scanner.ScanError.cannotOpen(clone.path, cp.terminationStatus) }
        let fd = open(clone.path, O_WRONLY)
        guard fd >= 0 else { throw Scanner.ScanError.cannotOpen(clone.path, errno) }
        let changed = [UInt8](repeating: 9, count: 16_384)
        let wrote = changed.withUnsafeBytes { pwrite(fd, $0.baseAddress!, $0.count, 0) }
        close(fd)
        guard wrote == changed.count, link(clone.path, dir.appendingPathComponent("zz-link.bin").path) == 0 else { throw Scanner.ScanError.cannotOpen(clone.path, errno) }
        let single = try await scan(dir, twoPhase: false)
        let phased = try await scan(dir)
        var originalStat = stat(); _ = lstat(original.path, &originalStat)
        let originalAllocated = Int64(originalStat.st_blocks) * 512
        print("modified clone: original allocated \(originalAllocated) single \(single.countedSize[0]) phased \(phased.countedSize[0])")
        verify("modified clone hard link loses private bytes in single pass", single.countedSize[0] == phased.countedSize[0] && single.privateSize[0] == phased.privateSize[0] && single.countedSize[0] > originalAllocated)
    } catch { verify("modified clone hard link setup: \(error)", false) }
    do {
        let dir = try folder("extra-link-change")
        let first = dir.appendingPathComponent("first.bin")
        let linked = dir.appendingPathComponent("linked.bin")
        try put(first, 8192)
        let tree = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1), phase1: { _ in
            _ = link(first.path, linked.path)
        })
        guard let firstID = child(tree, "first.bin") else { verify("new hard link keeps Frees at zero", false); throw DiskCore.Scanner.ScanError.storageLimit }
        verify("new hard link keeps Frees at zero", tree.privateSize[Int(firstID)] == 0)
    } catch { verify("new hard link setup: \(error)", false) }
    do {
        let dir = try folder("extra-replaced-file")
        let first = dir.appendingPathComponent("first.bin")
        try put(first, 8192)
        let tree = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1), phase1: { _ in
            try? fm.removeItem(at: first)
            try? put(first, 16384)
        })
        verify("replaced file identity is not reused", tree.limitations.contains { $0.contains("changed") } || child(tree, "first.bin").map { tree.flags[Int($0)].contains(.unreadable) } == true)
    } catch { verify("replaced file setup: \(error)", false) }
    do {
        let dir = try folder("extra-map")
        let nested = dir.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        for i in 0..<6 { try put(dir.appendingPathComponent("f\(i).dat"), (i + 1) * 4096) }
        try put(nested.appendingPathComponent("inside.png"), 8192)
        let zero = dir.appendingPathComponent("zero")
        fm.createFile(atPath: zero.path, contents: Data())
        let tree = try await scan(dir)
        for (w, h) in [(1, 1), (2, 1000), (2360, 1200)] {
            let map = Treemap.layout(tree: tree, rootNode: 0, widthPx: w, heightPx: h)
            let inside = map.nodeIDs.indices.allSatisfy { i in
                let x = Int(map.x[i]), y = Int(map.y[i]), bw = Int(map.widths[i]), bh = Int(map.heights[i])
                return x >= 0 && y >= 0 && bw > 0 && bh > 0 && x + bw <= w && y + bh <= h
            }
            var covered = 0, overlap = false
            for y in 0..<h { for x in 0..<w {
                if map.hitTest(x: x, y: y) != nil { covered += 1 }
                let owner = map.nodeIDs.indices.filter { i in
                    let id = map.nodeIDs[i]
                    guard tree.parent[Int(id)] == 0 else { return false }
                    return x >= Int(map.x[i]) && x < Int(map.x[i] + map.widths[i]) && y >= Int(map.y[i]) && y < Int(map.y[i] + map.heights[i])
                }
                if owner.count > 1 { overlap = true }
            } }
            verify("map \(w)x\(h) boxes overflow or overlap", inside && !overlap)
            verify("map \(w)x\(h) loses total area", covered == w * h)
        }
        verify("zero byte file receives positive area", child(tree, "zero").flatMap { Treemap.layout(tree: tree, rootNode: 0, widthPx: 100, heightPx: 100).rect(of: $0) } == nil)
    } catch { verify("map setup: \(error)", false) }
    do {
        let dir = try folder("extra-readonly")
        let file = dir.appendingPathComponent("dated.dat")
        try put(file)
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        func state() -> (Int64, Int64, Int64, Int64) {
            var st = stat(); _ = lstat(file.path, &st)
            return (st.st_size, Int64(st.st_mtimespec.tv_sec), Int64(st.st_atimespec.tv_sec), Int64(st.st_atimespec.tv_nsec))
        }
        let before = state()
        var first: FileTree?
        let result = try await DiskCore.Scanner.scan(root: dir.path, options: ScanOptions(workers: 2), phase1: { first = $0 })
        let after = state()
        verify("two phase scan changes file size or access and modification dates", before == after && first != nil && result.filesSeen == 1)
    } catch { verify("read only phase setup: \(error)", false) }
    do {
        let dir = try folder("extra-removed")
        let gone = dir.appendingPathComponent("gone")
        try fm.createDirectory(at: gone, withIntermediateDirectories: true)
        try put(gone.appendingPathComponent("item"))
        var removed = false
        do {
            _ = try await DiskCore.Scanner.scan(root: dir.path, options: ScanOptions(workers: 1), phase1: { _ in
                do { try fm.removeItem(at: gone); removed = true }
                catch { print("remove fixture during scan failed: \(error)") }
            })
            verify("folder removed between scan phases handled", removed)
        } catch {
            verify("folder removed between scan phases handled", removed && (error is DiskCore.Scanner.ScanError))
        }
    } catch { verify("removed folder setup: \(error)", false) }
    do {
        let dir = try folder("extra-cancel")
        for i in 0..<100 { try put(dir.appendingPathComponent("\(i).dat")) }
        let firstTask = Task { () -> Bool in
            do { _ = try await DiskCore.Scanner.scan(root: dir.path, options: ScanOptions(workers: 1, twoPhase: false)); return false }
            catch DiskCore.Scanner.ScanError.cancelled { return true }
            catch { return false }
        }
        firstTask.cancel()
        verify("phase one ignores cancellation", await firstTask.value)
        var secondTask: Task<Bool, Never>?
        secondTask = Task { () -> Bool in
            do {
                _ = try await DiskCore.Scanner.scan(root: dir.path, options: ScanOptions(workers: 1), phase1: { _ in secondTask?.cancel() })
                return false
            } catch DiskCore.Scanner.ScanError.cancelled { return true }
            catch is CancellationError { return true }
            catch { return false }
        }
        verify("phase two ignores cancellation", await secondTask!.value)
    } catch { verify("cancel setup: \(error)", false) }
    do {
        let dir = try folder("bug-concurrent-finalization")
        for i in 0..<320 {
            let sub = dir.appendingPathComponent("d\(i)")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try put(sub.appendingPathComponent("f.dat"))
        }
        let liveBox = LiveScanBox(), count = SnapshotCount()
        let reader = Task.detached {
            while !count.state().1 {
                if let model = liveBox.get() {
                    _ = model.snapshot(childrenOf: [0])
                    count.record()
                }
                await Task.yield()
            }
        }
        var reachedPhase1 = false
        _ = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 2), phase1: { _ in
            reachedPhase1 = true
            count.stop()
        }, live: { liveBox.set($0) })
        count.stop()
        await reader.value
        verify("phase one finalization overlaps live snapshots", reachedPhase1 && count.state().0 > 0)
        let cancelBox = ScanCancelBox()
        let phase2Task = Task { () -> Bool in
            do {
                _ = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 1), phase2Progress: { done, _ in cancelBox.cancelOnProgress(done) })
                return false
            } catch DiskCore.Scanner.ScanError.cancelled { return true }
            catch is CancellationError { return true }
            catch { return false }
        }
        cancelBox.set(phase2Task)
        let phase2Cancelled = await phase2Task.value
        verify("cancellation during active phase two", cancelBox.didSeeProgress() && phase2Cancelled)
    } catch { verify("finalization and phase two setup: \(error)", false) }
    return (tests, failures)
}
