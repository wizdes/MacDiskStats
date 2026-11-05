import Foundation
import Darwin
import DiskCore

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
        let raw = dir.path.withCString { path -> Int32 in
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            defer { if fd >= 0 { close(fd) } }
            guard fd >= 0 else { return -1 }
            let bytes: [CChar] = [105, 110, 118, 97, 108, 105, 100, -1, 0]
            return bytes.withUnsafeBufferPointer { openat(fd, $0.baseAddress!, O_CREAT | O_WRONLY, 0o600) }
        }
        let rawError = errno
        if raw >= 0 { close(raw) }
        let tree = try await scan(dir)
        verify("spaces emoji and leading dots lost", tree.filesSeen == (raw >= 0 ? 8 : 7))
        verify("invalid UTF8 bytes lost or fixture denied by OS errno \(rawError)", raw >= 0 && tree.names.contains(0xff))
        let expected = [".bashrc": "bashrc", "a.": "", "a.tar.gz": "gz", "NOEXT": ""]
        verify("extension suffix parsing is wrong", expected.allSatisfy { name, ext in
            guard let id = child(tree, name), tree.extensionIndex[Int(id)] >= 0 else { return false }
            return tree.extensions[Int(tree.extensionIndex[Int(id)])].name == ext
        })
        verify("uppercase extension does not fold to lowercase", tree.extensions.contains { $0.name == "png" })
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
    } catch { verify("clone chain setup: \(error)", false) }
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
    return (tests, failures)
}
