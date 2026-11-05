import Foundation
import Darwin

private struct Key: Hashable { let device: UInt64; let inode: UInt64 }
private struct DirectoryPart { let bytes: [UInt8]; let key: Key; let firmlink: Bool }
private final class KeyShard: @unchecked Sendable {
    let lock = NSLock()
    var keys = Set<Key>()
    func insert(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys.insert(key).inserted
    }
}
private final class Shards: @unchecked Sendable {
    private let shards = (0..<64).map { _ in KeyShard() }
    func insert(_ key: Key) -> Bool {
        let i = Int((key.inode ^ key.device) & 63)
        return shards[i].insert(key)
    }
}
private struct Entry {
    var name: UnsafeRawBufferPointer
    var type: UInt32 = 0
    var device: UInt64 = 0
    var inode: UInt64 = 0
    var links: UInt32 = 1
    var allocated: Int64 = 0
    var logical: Int64 = 0
    var privateBytes: Int64 = -1
    var mod: Int64 = 0
    var mount: UInt32 = 0
    var commonFlags: UInt32 = 0
    var error: Int32 = 0
    var cloneID: UInt64 = 0
    var cloneRefs: UInt32 = 0
}
private struct Job { let id: Int32; let path: String; let key: Key; let firmlink: Bool; let rawPath: Bool }
public struct LiveNode: Sendable {
    public let id: Int32
    public let parent: Int32
    public let name: String
    public let bytes: Int64
    public let isDirectory: Bool
    public let isSizing: Bool
    public let isUnreadable: Bool
    public let extensionName: String
}
public struct LiveSnapshot: Sendable {
    public let children: [Int32: [LiveNode]]
    public let nodes: [Int32: LiveNode]
    public let extensions: [ExtensionTotal]
    public let countedBytes: Int64
    public let filesSeen: Int64
    public let volumeUsedBytes: Int64
    public let mapTypes: [Int32: [ExtensionTotal]]
}

// Reads copy only the requested rows. State's existing lock protects every field.
public final class LiveScan: @unchecked Sendable {
    private let state: State
    fileprivate init(_ state: State) { self.state = state }
    public var volumeUsedBytes: Int64 { state.volumeUsed }
    public var rootPath: String { state.rootPath }
    public var completedDirectories: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.completedDirectories
    }
    public func completionOrder(of id: Int32) -> Int? {
        state.lock.lock(); defer { state.lock.unlock() }
        guard id >= 0, Int(id) < state.completionOrder.count else { return nil }
        return state.completionOrder[Int(id)]
    }
    public func node(_ id: Int32) -> LiveNode? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.liveNode(id)
    }
    public func children(of id: Int32) -> [LiveNode] {
        state.lock.lock(); defer { state.lock.unlock() }
        guard id >= 0, Int(id) < state.childIDs.count else { return [] }
        return state.childIDs[Int(id)].compactMap { state.liveNode($0) }
    }
    public func extensions() -> [ExtensionTotal] {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.extensionBytes.indices.compactMap { i in
            let bytes = state.liveExtensionBytes[i]
            return bytes > 0 ? ExtensionTotal(name: String(decoding: state.extensionBytes[i], as: UTF8.self), bytes: bytes, files: state.liveExtensionFiles[i]) : nil
        }.sorted { $0.bytes > $1.bytes }
    }
    public func snapshot(childrenOf ids: [Int32]) -> LiveSnapshot {
        state.lock.lock(); defer { state.lock.unlock() }
        var children: [Int32: [LiveNode]] = [:]
        for id in ids where id >= 0 && Int(id) < state.childIDs.count {
            children[id] = state.childIDs[Int(id)].compactMap { state.liveNode($0) }
        }
        let extensions = state.extensionBytes.indices.compactMap { i -> ExtensionTotal? in
            let bytes = state.liveExtensionBytes[i]
            return bytes > 0 ? ExtensionTotal(name: String(decoding: state.extensionBytes[i], as: UTF8.self), bytes: bytes, files: state.liveExtensionFiles[i]) : nil
        }.sorted { $0.bytes > $1.bytes }
        let end = min(state.parent.count, state.mapCursor + 50_000)
        if state.mapCursor < end {
            for i in state.mapCursor..<end where state.extensionIDs[i] >= 0 && state.counted[i] > 0 {
                let folder = state.levelOne[i]
                if folder >= 0 { state.mapBytes[folder, default: [:]][state.extensionIDs[i], default: 0] += state.counted[i] }
            }
            state.mapCursor = end
        }
        var mapTypes: [Int32: [ExtensionTotal]] = [:]
        for id in ids {
            if let values = state.mapBytes[id] {
                mapTypes[id] = values.map { key, bytes in
                    ExtensionTotal(name: String(decoding: state.extensionBytes[Int(key)], as: UTF8.self), bytes: bytes, files: 0)
                }.sorted { $0.bytes > $1.bytes }
            }
        }
        var nodes: [Int32: LiveNode] = [:]
        for rows in children.values { for node in rows { nodes[node.id] = node } }
        return LiveSnapshot(children: children, nodes: nodes, extensions: extensions, countedBytes: state.runningBytes,
                            filesSeen: state.filesSeen, volumeUsedBytes: state.volumeUsed, mapTypes: mapTypes)
    }
    public func prioritize(_ id: Int32) {
        state.lock.lock(); defer { state.lock.unlock() }
        guard id >= 0, Int(id) < state.parent.count else { return }
        state.priorityRoots.insert(id)
        let pending = state.queue[state.queueHead...]
        let first = pending.filter { state.isDescendant($0.id, of: id) }
        let rest = pending.filter { !state.isDescendant($0.id, of: id) }
        state.queue.replaceSubrange(state.queueHead..., with: first + rest)
        state.lock.broadcast()
    }
}
private final class State: @unchecked Sendable {
    let lock = NSCondition()
    var queue: [Job] = []
    var queueHead = 0
    var active = 0
    var done = false
    var cancelled = false
    var storageLimit = false
    var lastProgress = Date.distantPast
    var parent: [Int32] = [-1]
    var device: [UInt64]
    var inode: [UInt64]
    var linkCount: [UInt32] = [1]
    var counted: [Int64] = [0]
    var priv: [Int64] = [0]
    var logical: [Int64] = [0]
    var files: [Int64] = [0]
    var mod: [Int64] = [0]
    var flags: [NodeFlags] = [.isDir]
    var offsets: [Int32] = [0]
    var lengths: [Int32] = [0]
    var names: [UInt8] = []
    var levelOne: [Int32] = [-1]
    var levelTwo: [Int32] = [-1]
    var progressTick = 0
    var extensionIDs: [Int32] = [-1]
    var extensionBytes: [[UInt8]] = []
    var liveExtensionBytes: [Int64] = []
    var liveExtensionFiles: [Int64] = []
    var mapCursor = 1
    var mapBytes: [Int32: [Int32: Int64]] = [:]
    var extensionHashes: [UInt64: [Int32]] = [:]
    var unreadable: [Int32] = []
    var limitations = Set<String>()
    var seenDirs = Set<Key>()
    var openedDirs = Set<Key>()
    var filesSeen: Int64 = 0
    var dirsSeen: Int64 = 1
    var runningBytes: Int64 = 0
    var levelBytes: [Int32: Int64] = [:]
    var childIDs: [[Int32]] = [[]]
    var liveBytes: [Int64] = [0]
    var pendingWork: [Int32] = [1]
    var completedDirectories = 0
    var completionOrder: [Int] = [0]
    var priorityRoots = Set<Int32>()
    var progress: (@Sendable (ScanProgress) -> Void)?
    let links = Shards()
    let clones = Shards()
    let rootPath: String
    let rootFD: Int32
    let rootDevice: UInt64
    let dataDevice: UInt64
    let volumeUsed: Int64
    let options: ScanOptions
    let liveEnabled: Bool
    init(path: String, fd: Int32, device: UInt64, dataDevice: UInt64, inode: UInt64, volumeUsed: Int64, options: ScanOptions, progress: (@Sendable (ScanProgress) -> Void)?, liveEnabled: Bool) {
        self.device = [device]; self.inode = [inode]
        rootPath = path; rootFD = fd; rootDevice = device; self.dataDevice = dataDevice; self.volumeUsed = volumeUsed; self.options = options; self.progress = progress; self.liveEnabled = liveEnabled
        if !options.includePrivateSize { limitations.insert("private and clone attributes disabled; shared clone bytes may be counted twice") }
        let rootKey = Key(device: device, inode: inode)
        seenDirs.insert(rootKey); openedDirs.insert(rootKey); queue = [Job(id: 0, path: ".", key: rootKey, firmlink: false, rawPath: false)]
    }
    deinit { close(rootFD) }
    private func internExtension(_ name: UnsafeRawBufferPointer) -> Int32 {
        var dot = -1
        for i in name.indices where name[i] == 46 { dot = i }
        let start = dot <= 0 ? name.count : dot + 1
        var hash: UInt64 = 14_695_981_039_346_656_037
        for i in start..<name.count {
            let c = name[i], lower = c >= 65 && c <= 90 ? c + 32 : c
            hash = (hash ^ UInt64(lower)) &* 1_099_511_628_211
        }
        for id in extensionHashes[hash] ?? [] {
            let bytes = extensionBytes[Int(id)]
            if bytes.count == name.count - start && bytes.indices.allSatisfy({ j in
                let c = name[start + j]
                return bytes[j] == (c >= 65 && c <= 90 ? c + 32 : c)
            }) { return id }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.count - start)
        for i in start..<name.count { let c = name[i]; bytes.append(c >= 65 && c <= 90 ? c + 32 : c) }
        let id = Int32(extensionBytes.count)
        extensionBytes.append(bytes); liveExtensionBytes.append(0); liveExtensionFiles.append(0); extensionHashes[hash, default: []].append(id)
        return id
    }
    func next() -> Job? {
        lock.lock(); defer { lock.unlock() }
        while queueHead == queue.count && active > 0 && !cancelled { lock.wait() }
        if cancelled || queueHead == queue.count { done = true; lock.broadcast(); return nil }
        let j = queue[queueHead]; queueHead += 1; active += 1
        return j
    }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func scanResult() -> (limited: Bool, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (storageLimit, cancelled)
    }
    func isDescendant(_ id: Int32, of root: Int32) -> Bool {
        var at = id
        while at >= 0 {
            if at == root { return true }
            at = parent[Int(at)]
        }
        return false
    }
    func addLiveAncestors(_ bytes: Int64, below id: Int32) {
        guard liveEnabled && bytes > 0 else { return }
        lock.lock()
        var at = id
        while at >= 0 { liveBytes[Int(at)] += bytes; at = parent[Int(at)] }
        lock.unlock()
    }
    func finished(_ id: Int32) {
        lock.lock(); active -= 1
        if liveEnabled {
            completedDirectories += 1
            completionOrder[Int(id)] = completedDirectories
            var at = id
            pendingWork[Int(at)] -= 1
            while pendingWork[Int(at)] == 0 && at > 0 {
                let p = parent[Int(at)]
                pendingWork[Int(p)] -= 1
                at = p
            }
        }
        if queueHead == queue.count && active == 0 { done = true }
        lock.broadcast(); lock.unlock()
    }
    func liveNode(_ id: Int32) -> LiveNode? {
        guard id >= 0, Int(id) < parent.count else { return nil }
        let i = Int(id), a = Int(offsets[i]), b = a + Int(lengths[i])
        let ext = extensionIDs[i]
        return LiveNode(id: id, parent: parent[i], name: id == 0 ? rootPath : FileTree.displayName(bytes: Array(names[a..<b])),
                        bytes: liveBytes[i], isDirectory: flags[i].contains(.isDir),
                        isSizing: flags[i].contains(.isDir) && pendingWork[i] > 0,
                        isUnreadable: flags[i].contains(.unreadable),
                        extensionName: ext >= 0 ? String(decoding: extensionBytes[Int(ext)], as: UTF8.self) : "")
    }
    func add(_ e: Entry, parent p: Int32, path: String, rawPath: Bool = false, forceUnreadable: Bool = false) -> Int64 {
        let isDir = e.type == UInt32(VDIR.rawValue)
        let isLink = e.type == UInt32(VLNK.rawValue)
        var f: NodeFlags = []
        if isDir { f.insert(.isDir) }
        if forceUnreadable || e.error != 0 { f.insert(.unreadable) }
        if isLink { f.insert(.symlink) }
        let key = Key(device: e.device, inode: e.inode)
        var size = isDir ? 0 : max(0, e.allocated)
        var privateSize = isDir || !options.includePrivateSize ? 0 : max(0, e.privateBytes)
        if !isDir && !isLink && e.links > 1 {
            f.insert(.hardlink)
            if !links.insert(key) { size = 0; f.insert(.hardlinkDup) }
        }
        if !isDir && !isLink && size > 0 && e.cloneRefs > 1 && e.cloneID != 0 {
            let clone = Key(device: e.device, inode: e.cloneID)
            if !clones.insert(clone) { size = privateSize; f.insert(.cloneShared) }
        }
        if f.contains(.hardlink) { privateSize = 0 }
        lock.lock()
        guard Scanner.indexFits(self.parent.count) && Scanner.indexFits(names.count, appending: e.name.count) && Scanner.indexFits(extensionBytes.count) else {
            storageLimit = true; cancelled = true; lock.broadcast(); lock.unlock(); return 0
        }
        let id = Int32(self.parent.count)
        self.parent.append(p); device.append(e.device); inode.append(e.inode); linkCount.append(e.links); counted.append(size); priv.append(privateSize)
        if liveEnabled {
            childIDs.append([]); childIDs[Int(p)].append(id); liveBytes.append(isDir ? 0 : size); pendingWork.append(isDir ? 1 : 0); completionOrder.append(0)
        }
        logical.append(isDir ? 0 : max(0, e.logical)); files.append(isDir ? 0 : 1)
        mod.append(e.mod); flags.append(f)
        offsets.append(Int32(names.count)); lengths.append(Int32(e.name.count)); names.append(contentsOf: e.name)
        let extensionID = isDir ? Int32(-1) : internExtension(e.name)
        extensionIDs.append(extensionID)
        if liveEnabled && extensionID >= 0 { liveExtensionBytes[Int(extensionID)] += size; liveExtensionFiles[Int(extensionID)] += 1 }
        if p == 0 { levelOne.append(isDir ? id : -1); levelTwo.append(-1) }
        else {
            levelOne.append(levelOne[Int(p)])
            levelTwo.append(self.parent[Int(p)] == 0 && isDir ? id : levelTwo[Int(p)])
        }
        runningBytes += size
        if size > 0 {
            let one = levelOne[Int(p)], two = levelTwo[Int(p)]
            if one >= 0 { levelBytes[one, default: 0] += size }
            if two >= 0 { levelBytes[two, default: 0] += size }
        }
        if isDir {
            dirsSeen += 1
            let sameVolume = e.device == rootDevice || (rootPath == "/" && e.device == dataDevice)
            let firmlink = rootPath == "/" && sameVolume && (e.commonFlags & UInt32(SF_FIRMLINK)) != 0
            if firmlink { flags[Int(id)].insert(.firmlink) }
            if forceUnreadable || e.error != 0 { flags[Int(id)].insert(.unreadable); unreadable.append(id) }
            else if path == "System/Volumes/Data" && rootPath == "/" { flags[Int(id)].insert(.mountPointStopped) }
            else if (e.mount != 0 || !sameVolume) && !firmlink { flags[Int(id)].insert(.mountPointStopped) }
            else if !seenDirs.insert(key).inserted { flags[Int(id)].insert(.mountPointStopped) }
            else {
                if liveEnabled { pendingWork[Int(p)] += 1 }
                let job = Job(id: id, path: path, key: key, firmlink: firmlink, rawPath: rawPath)
                if priorityRoots.contains(where: { isDescendant(id, of: $0) }) { queue.insert(job, at: queueHead) }
                else { queue.append(job) }
                lock.broadcast()
            }
            if liveEnabled && (flags[Int(id)].contains(.mountPointStopped) || flags[Int(id)].contains(.unreadable)) { pendingWork[Int(id)] = 0 }
        } else { filesSeen += 1; if f.contains(.unreadable) { unreadable.append(id) } }
        progressTick += 1
        if progressTick & 4095 == 0, Date().timeIntervalSince(lastProgress) >= 0.25 {
            let now = Date()
            lastProgress = now
            let totals = levelBytes.map { (path: relativePath($0.key), bytes: $0.value) }
            let info = ScanProgress(filesSeen: filesSeen, bytesCounted: runningBytes, firstTwoLevels: totals)
            let callback = progress
            lock.unlock(); callback?(info); return size
        }
        lock.unlock()
        return size
    }
    func markUnreadable(_ id: Int32) {
        lock.lock(); if !flags[Int(id)].contains(.unreadable) { flags[Int(id)].insert(.unreadable); unreadable.append(id) }; lock.unlock()
    }
    func markMountStop(_ id: Int32) { lock.lock(); flags[Int(id)].insert(.mountPointStopped); lock.unlock() }
    func directoryComponents(_ id: Int32) -> [DirectoryPart] {
        lock.lock(); defer { lock.unlock() }
        var parts: [DirectoryPart] = [], at = id
        while at > 0 {
            let i = Int(at), a = Int(offsets[i])
            parts.append(DirectoryPart(bytes: Array(names[a..<(a + Int(lengths[i]))]), key: Key(device: device[i], inode: inode[i]), firmlink: flags[i].contains(.firmlink)))
            at = parent[i]
        }
        return parts.reversed()
    }
    func limit(_ text: String) { lock.lock(); limitations.insert(text); lock.unlock() }
    func enterOpened(_ id: Int32, key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if id == 0 { return true }
        if !openedDirs.insert(key).inserted { flags[Int(id)].insert(.mountPointStopped); return false }
        return true
    }
    private func relativePath(_ id: Int32) -> String {
        var parts: [String] = [], at = id
        while at > 0 {
            let i = Int(at), start = Int(offsets[i])
            parts.append(String(decoding: names[start..<(start + Int(lengths[i]))], as: UTF8.self))
            at = parent[i]
        }
        return (rootPath == "/" ? "" : rootPath) + "/" + parts.reversed().joined(separator: "/")
    }
}

public enum Scanner {
    public enum ScanError: Error { case cannotOpen(String, Int32), cancelled, storageLimit }
    public static func indexFits(_ count: Int, appending: Int = 0) -> Bool {
        count >= 0 && appending >= 0 && count <= Int(Int32.max) - appending
    }
    public static func scan(root path: String, options: ScanOptions = ScanOptions(), progress: (@Sendable (ScanProgress) -> Void)? = nil, phase1: (@MainActor @Sendable (FileTree) -> Void)? = nil, live: (@MainActor @Sendable (LiveScan) -> Void)? = nil, phase2Progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> FileTree {
        guard options.includePrivateSize && options.twoPhase else { return try await scanSingle(root: path, options: options, progress: progress, live: live) }
        var quick = options
        quick.includePrivateSize = false
        let first = try await scanSingle(root: path, options: quick, progress: progress, live: live)
        try Task.checkCancellation()
        await phase1?(first)
        try Task.checkCancellation()
        if first.limitations.contains(where: { $0.contains("getattrlistbulk unsupported") }) { return first }
        return try await enrich(first, options: options, progress: phase2Progress)
    }
    private static func scanSingle(root path: String, options: ScanOptions, progress: (@Sendable (ScanProgress) -> Void)?, live: (@MainActor @Sendable (LiveScan) -> Void)?) async throws -> FileTree {
        let normalized = path == "/" ? "/" : String(path.drop(while: { $0 == "/" })).isEmpty ? path : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        let fd = open(normalized, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.cannotOpen(normalized, errno) }
        var st = stat(); var fs = statfs()
        guard fstat(fd, &st) == 0 else { let e = errno; close(fd); throw ScanError.cannotOpen(normalized, e) }
        _ = fstatfs(fd, &fs)
        var dataDevice = UInt64(st.st_dev)
        if normalized == "/" {
            var dataStat = stat()
            if stat("/System/Volumes/Data", &dataStat) == 0 { dataDevice = UInt64(dataStat.st_dev) }
        }
        let used = volumeUsedBytes(root: normalized)
        guard used > 0 else { close(fd); throw ScanError.cannotOpen(normalized, EIO) }
        let state = State(path: normalized, fd: fd, device: UInt64(st.st_dev), dataDevice: dataDevice, inode: st.st_ino, volumeUsed: used, options: options, progress: progress, liveEnabled: live != nil)
        await live?(LiveScan(state))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let group = DispatchGroup()
                for _ in 0..<options.workers {
                    group.enter()
                    Thread.detachNewThread {
                        var buffer = [UInt8](repeating: 0, count: options.bufferSize)
                        while let job = state.next() {
                            scanDirectory(job, state, &buffer)
                            state.finished(job.id)
                        }
                        group.leave()
                    }
                }
                DispatchQueue.global().async {
                    group.wait()
                    let result = state.scanResult()
                    if result.limited { continuation.resume(throwing: ScanError.storageLimit) }
                    else if result.cancelled { continuation.resume(throwing: ScanError.cancelled) }
                    else { continuation.resume(returning: finish(state)) }
                }
            }
        } onCancel: {
            state.lock.lock(); state.cancelled = true; state.lock.broadcast(); state.lock.unlock()
        }
    }
    public static func volumeUsedBytes(root: String) -> Int64 {
        func usedOnVolume(_ path: String) -> Int64? {
            var attrs = attrlist()
            attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attrs.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED)
            var record = [UInt8](repeating: 0, count: 12)
            let status = record.withUnsafeMutableBytes { raw in getattrlist(path, &attrs, raw.baseAddress, raw.count, 0) }
            guard status == 0 else { return nil }
            return record.withUnsafeBytes { Int64(bitPattern: $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self)) }
        }
        var used = usedOnVolume(root) ?? 0
        if root == "/" { used += usedOnVolume("/System/Volumes/Data") ?? 0 }
        return used
    }
}

private func openDirectory(rootFD: Int32, components: [DirectoryPart], allowedDevices: Set<UInt64>) -> Int32 {
    var current = dup(rootFD)
    guard current >= 0 else { return -1 }
    for component in components {
        let name = component.bytes.map { CChar(bitPattern: $0) } + [0]
        let next = name.withUnsafeBufferPointer { openat(current, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        let openError = errno
        close(current)
        guard next >= 0 else { errno = openError; return -1 }
        var st = stat()
        guard fstat(next, &st) == 0 else { let code = errno; close(next); errno = code; return -1 }
        guard allowedDevices.contains(UInt64(st.st_dev)) else { close(next); errno = EXDEV; return -1 }
        guard component.firmlink || UInt64(st.st_dev) == component.key.device && st.st_ino == component.key.inode else { close(next); errno = ESTALE; return -1 }
        current = next
    }
    return current
}

private func scanDirectory(_ job: Job, _ s: State, _ buffer: inout [UInt8]) {
    var fd = job.rawPath ? -1 : openat(s.rootFD, job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if job.rawPath || fd < 0 && errno == ENAMETOOLONG {
        fd = openDirectory(rootFD: s.rootFD, components: s.directoryComponents(job.id), allowedDevices: [s.rootDevice, s.dataDevice])
    }
    if fd < 0 { if errno == EXDEV { s.markMountStop(job.id) } else { s.markUnreadable(job.id) }; return }
    defer { close(fd) }
    var st = stat(); if fstat(fd, &st) != 0 { s.markUnreadable(job.id); return }
    // The opened directory, rather than its parent's entry, determines volume identity.
    if UInt64(st.st_dev) != s.rootDevice && UInt64(st.st_dev) != s.dataDevice && job.id != 0 { s.markMountStop(job.id); return }
    if job.id != 0 && !job.firmlink && (job.key.device != UInt64(st.st_dev) || job.key.inode != st.st_ino) { s.markUnreadable(job.id); return }
    if !s.enterOpened(job.id, key: Key(device: UInt64(st.st_dev), inode: st.st_ino)) { return }
    var attrs = attrlist()
    attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attrs.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_ERROR)
    attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
    attrs.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
    if s.options.includePrivateSize { attrs.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT) }
    let opts = s.options.includePrivateSize ? UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED) : UInt64(FSOPT_PACK_INVAL_ATTRS)
    let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
        getattrlistbulk(fd, &attrs, raw.baseAddress, raw.count, opts)
    }
    if result < 0 {
        let code = errno
        if code == ENOTSUP || code == EINVAL || code == ENOTTY { s.limit("getattrlistbulk unsupported; readdir/lstat used; private and clone data unavailable"); fallback(fd, job, s) }
        else { s.markUnreadable(job.id) }
        return
    }
    parseRecords(buffer, count: Int(result), parent: job, state: s)
    while true {
        if s.isCancelled() { return }
        let n = buffer.withUnsafeMutableBytes { raw in getattrlistbulk(fd, &attrs, raw.baseAddress, raw.count, opts) }
        if n == 0 { break }
        if n < 0 { s.markUnreadable(job.id); break }
        parseRecords(buffer, count: Int(n), parent: job, state: s)
    }
}

private func parseRecords(_ bytes: [UInt8], count: Int, parent: Job, state s: State) {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var pos = 0
        var batchBytes: Int64 = 0
        defer { s.addLiveAncestors(batchBytes, below: parent.id) }
        for recordIndex in 0..<count {
            if recordIndex & 255 == 0 && s.isCancelled() { return }
            if pos > raw.count - 4 { s.limit("malformed bulk attribute record"); s.markUnreadable(parent.id); return }
            let length = Int(base.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
            if length < 24 || length > raw.count - pos { s.limit("malformed bulk attribute record"); s.markUnreadable(parent.id); return }
            var cursor = pos + 4
            func take<T>(_ type: T.Type) -> T? {
                guard cursor <= pos + length - MemoryLayout<T>.size else { return nil }
                defer { cursor += MemoryLayout<T>.size }
                return base.loadUnaligned(fromByteOffset: cursor, as: T.self)
            }
            guard let returned = take(attribute_set_t.self) else { s.markUnreadable(parent.id); return }
            let common = returned.commonattr, dirs = returned.dirattr, files = returned.fileattr, ext = returned.forkattr
            var e = Entry(name: UnsafeRawBufferPointer(start: nil, count: 0))
            // ATTR_CMN_ERROR precedes the normal common attributes in bulk records.
            if common & UInt32(ATTR_CMN_ERROR) != 0 { guard let value = take(Int32.self) else { s.markUnreadable(parent.id); return }; e.error = value }
            // Other attributes follow ascending bit order within each group.
            if common & UInt32(ATTR_CMN_NAME) != 0 {
                let refAt = cursor
                guard let ref = take(attrreference_t.self) else { s.markUnreadable(parent.id); return }
                let (start, overflow1) = refAt.addingReportingOverflow(Int(ref.attr_dataoffset))
                let (end, overflow2) = start.addingReportingOverflow(Int(ref.attr_length))
                guard !overflow1 && !overflow2 else { s.markUnreadable(parent.id); return }
                if start >= pos && end <= pos + length && end > start { e.name = UnsafeRawBufferPointer(rebasing: raw[start..<(end - (raw[end - 1] == 0 ? 1 : 0))]) }
            }
            if common & UInt32(ATTR_CMN_DEVID) != 0 { guard let value = take(UInt32.self) else { s.markUnreadable(parent.id); return }; e.device = UInt64(value) }
            if common & UInt32(ATTR_CMN_OBJTYPE) != 0 { guard let value = take(UInt32.self) else { s.markUnreadable(parent.id); return }; e.type = value }
            if common & UInt32(ATTR_CMN_MODTIME) != 0 { guard let value = take(timespec.self) else { s.markUnreadable(parent.id); return }; e.mod = Int64(value.tv_sec) }
            if common & UInt32(ATTR_CMN_FLAGS) != 0 { guard let value = take(UInt32.self) else { s.markUnreadable(parent.id); return }; e.commonFlags = value }
            if common & UInt32(ATTR_CMN_FILEID) != 0 { guard let value = take(UInt64.self) else { s.markUnreadable(parent.id); return }; e.inode = value }
            if dirs & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 { guard let value = take(UInt32.self) else { s.markUnreadable(parent.id); return }; e.mount = value }
            if files & UInt32(ATTR_FILE_LINKCOUNT) != 0 { guard let value = take(UInt32.self) else { s.markUnreadable(parent.id); return }; e.links = value }
            if files & UInt32(ATTR_FILE_TOTALSIZE) != 0 { guard let value = take(UInt64.self) else { s.markUnreadable(parent.id); return }; e.logical = Int64(bitPattern: value) }
            if files & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { guard let value = take(UInt64.self) else { s.markUnreadable(parent.id); return }; e.allocated = Int64(bitPattern: value) }
            if ext & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { guard let value = take(UInt64.self) else { s.markUnreadable(parent.id); return }; e.privateBytes = Int64(bitPattern: value) }
            if ext & UInt32(ATTR_CMNEXT_CLONEID) != 0 { guard let value = take(UInt64.self) else { s.markUnreadable(parent.id); return }; e.cloneID = value }
            if ext & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 { guard let value = take(UInt32.self) else { s.markUnreadable(parent.id); return }; e.cloneRefs = value }
            if !e.name.isEmpty && !(e.name.count == 1 && e.name[0] == 46) && !(e.name.count == 2 && e.name[0] == 46 && e.name[1] == 46) {
                let relative: String
                var rawPath = parent.rawPath
                if e.type == UInt32(VDIR.rawValue) {
                    let decoded = String(bytes: e.name, encoding: .utf8)
                    let name = decoded ?? String(decoding: e.name, as: UTF8.self)
                    rawPath = rawPath || decoded == nil
                    relative = parent.id == 0 ? name : parent.path + "/" + name
                } else { relative = "" }
                batchBytes += s.add(e, parent: parent.id, path: relative, rawPath: rawPath)
            }
            pos += length
        }
    }
}

private func fallback(_ fd: Int32, _ job: Job, _ s: State) {
    let dupFD = dup(fd); guard dupFD >= 0, let dir = fdopendir(dupFD) else { if dupFD >= 0 { close(dupFD) }; s.markUnreadable(job.id); return }
    defer { closedir(dir) }
    var batchBytes: Int64 = 0
    var batchCount = 0
    defer { s.addLiveAncestors(batchBytes, below: job.id) }
    while let d = readdir(dir) {
        if s.isCancelled() { return }
        batchCount += 1
        withUnsafePointer(to: d.pointee.d_name) { tuple in tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { pointer in
            let length = Int(strlen(pointer))
            if length == 1 && pointer[0] == 46 || length == 2 && pointer[0] == 46 && pointer[1] == 46 { return }
            var st = stat()
            if fstatat(fd, pointer, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                s.limit("some entries changed or could not be read during readdir fallback")
                return
            }
            let name = FileTree.displayName(bytes: (0..<length).map { UInt8(bitPattern: pointer[$0]) })
            var e = Entry(name: UnsafeRawBufferPointer(start: pointer, count: length))
            e.device = UInt64(st.st_dev); e.inode = st.st_ino; e.links = UInt32(st.st_nlink)
            e.type = (st.st_mode & S_IFMT) == S_IFDIR ? UInt32(VDIR.rawValue) : ((st.st_mode & S_IFMT) == S_IFLNK ? UInt32(VLNK.rawValue) : UInt32(VREG.rawValue))
            e.allocated = Int64(st.st_blocks) * 512; e.logical = st.st_size; e.mod = Int64(st.st_mtimespec.tv_sec)
            let relative = e.type == UInt32(VDIR.rawValue) ? (job.id == 0 ? name : job.path + "/" + name) : ""
            batchBytes += s.add(e, parent: job.id, path: relative,
                                rawPath: job.rawPath || (e.type == UInt32(VDIR.rawValue) && String(bytes: (0..<length).map { UInt8(bitPattern: pointer[$0]) }, encoding: .utf8) == nil))
        } }
        if batchCount == 256 {
            s.addLiveAncestors(batchBytes, below: job.id)
            batchBytes = 0
            batchCount = 0
        }
    }
}

private func finish(_ s: State) -> FileTree {
    let n = s.parent.count
    var counted = s.counted
    var childLists = Array(repeating: [Int32](), count: n)
    for i in 1..<n { childLists[Int(s.parent[i])].append(Int32(i)) }
    var order: [Int32] = [0], idx = 0
    while idx < order.count { order.append(contentsOf: childLists[Int(order[idx])]); idx += 1 }
    var largestNode = [Int32](repeating: -1, count: n)
    for id in order.reversed() where id != 0 {
        let p = Int(s.parent[Int(id)])
        if !s.flags[Int(id)].contains(.isDir) { largestNode[Int(id)] = id }
        let candidate = s.flags[Int(id)].contains(.isDir) ? largestNode[Int(id)] : id
        if candidate >= 0 {
            let old = largestNode[p]
            if old < 0 || counted[Int(candidate)] > counted[Int(old)] { largestNode[p] = candidate }
        }
        counted[p] += counted[Int(id)]; s.priv[p] += s.priv[Int(id)]
        s.logical[p] += s.logical[Int(id)]; s.files[p] += s.files[Int(id)]
    }
    var children: [Int32] = [], first = Array(repeating: Int32(0), count: n), counts = Array(repeating: Int32(0), count: n)
    for i in 0..<n {
        childLists[i].sort { counted[Int($0)] > counted[Int($1)] }
        first[i] = Int32(children.count); counts[i] = Int32(childLists[i].count)
        children.append(contentsOf: childLists[i])
    }
    var extBytes = [Int64](repeating: 0, count: s.extensionBytes.count)
    var extFiles = [Int64](repeating: 0, count: s.extensionBytes.count)
    for i in 1..<n where s.extensionIDs[i] >= 0 {
        let e = Int(s.extensionIDs[i]); extBytes[e] += counted[i]; extFiles[e] += 1
    }
    let sorted = s.extensionBytes.indices.sorted { extBytes[$0] > extBytes[$1] }
    var rank = [Int32](repeating: -1, count: sorted.count)
    for (position, id) in sorted.enumerated() { rank[id] = Int32(position) }
    let extIndex = s.extensionIDs.map { $0 < 0 ? -1 : rank[Int($0)] }
    let largestFileType = largestNode.map { $0 < 0 ? Int32(-1) : extIndex[Int($0)] }
    let extensions = sorted.map { id in ExtensionTotal(name: String(decoding: s.extensionBytes[id], as: UTF8.self), bytes: extBytes[id], files: extFiles[id]) }
    var tree = FileTree(rootPath: s.rootPath, parent: s.parent, device: s.device, inode: s.inode, linkCount: s.linkCount, firstChild: first, childCount: counts, countedSize: counted, privateSize: s.priv, logicalSize: s.logical, fileCount: s.files, modTime: s.mod, extensionIndex: extIndex, largestFileType: largestFileType, flags: s.flags, nameOffset: s.offsets, nameLength: s.lengths, names: s.names, children: children, extensions: extensions, unreadablePaths: [], limitations: s.limitations.sorted(), volumeUsedBytes: s.volumeUsed, filesSeen: s.filesSeen, dirsSeen: s.dirsSeen, largestFiles: [])
    let paths = s.unreadable.map { tree.path(of: $0) }
    let largest = tree.topFiles(limit: 100)
    tree = FileTree(rootPath: s.rootPath, parent: s.parent, device: s.device, inode: s.inode, linkCount: s.linkCount, firstChild: first, childCount: counts, countedSize: counted, privateSize: s.priv, logicalSize: s.logical, fileCount: s.files, modTime: s.mod, extensionIndex: extIndex, largestFileType: largestFileType, flags: s.flags, nameOffset: s.offsets, nameLength: s.lengths, names: s.names, children: children, extensions: extensions, unreadablePaths: paths, limitations: s.limitations.sorted(), volumeUsedBytes: s.volumeUsed, filesSeen: s.filesSeen, dirsSeen: s.dirsSeen, largestFiles: largest)
    return tree
}

private final class Enrichment: @unchecked Sendable {
    struct Update { let id: Int32; let size: Int64; let privateBytes: Int64; let flags: NodeFlags }
    let tree: FileTree
    let fd: Int32
    let options: ScanOptions
    let allowedDevices: Set<UInt64>
    let directories: [Int32]
    let clones = Shards()
    let links = Shards()
    let lock = NSLock()
    var nextDirectory = 0
    var completedDirectories = 0
    var lastProgress = Date.distantPast
    let progress: (@Sendable (Int, Int) -> Void)?
    var cancelled = false
    var failed = false
    var skipped = false
    var skippedIDs: [Int32] = []
    var counted: [Int64]
    var priv: [Int64]
    var flags: [NodeFlags]
    init(tree: FileTree, fd: Int32, options: ScanOptions, progress: (@Sendable (Int, Int) -> Void)?) {
        self.tree = tree; self.fd = fd; self.options = options
        self.progress = progress
        var allowed: Set<UInt64> = [tree.device[0]]
        if tree.rootPath == "/" { var data = stat(); if stat("/System/Volumes/Data", &data) == 0 { allowed.insert(UInt64(data.st_dev)) } }
        allowedDevices = allowed
        var hasDirectFile = [Bool](repeating: false, count: tree.parent.count)
        for i in tree.parent.indices where i > 0 && !tree.flags[i].contains(.isDir) {
            hasDirectFile[Int(tree.parent[i])] = true
        }
        directories = tree.parent.indices.compactMap { i in
            let f = tree.flags[i]
            return hasDirectFile[i] && f.contains(.isDir) && !f.contains(.unreadable) && !f.contains(.mountPointStopped) ? Int32(i) : nil
        }
        counted = tree.countedSize; priv = tree.privateSize; flags = tree.flags
    }
    deinit { close(fd) }
    func next() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled && nextDirectory < directories.count else { return nil }
        let id = directories[nextDirectory]; nextDirectory += 1; return id
    }
    func finishedDirectory() {
        lock.lock()
        completedDirectories += 1
        let shouldReport = progress != nil && completedDirectories & 255 == 0 && Date().timeIntervalSince(lastProgress) >= 0.25
        let done = completedDirectories, total = directories.count
        if shouldReport { lastProgress = Date() }
        lock.unlock()
        if shouldReport { progress?(done, total) }
    }
    func prepareUpdate(_ id: Int32, device: UInt64, inode: UInt64, linkCount: UInt32, allocated: Int64, privateBytes: Int64, cloneID: UInt64, refs: UInt32) -> Update? {
        let i = Int(id)
        let oldFlags = tree.flags[i]
        guard !oldFlags.contains(.isDir) else { return nil }
        guard device == tree.device[i], inode == tree.inode[i] else { skip(id); return nil }
        var size = max(0, allocated)
        var privateSize = max(0, privateBytes)
        var shared = false
        let hardlink = linkCount > 1 && !oldFlags.contains(.symlink)
        let duplicateLink = hardlink && !links.insert(Key(device: device, inode: inode))
        if !oldFlags.contains(.symlink) && refs > 1 && cloneID != 0 && !duplicateLink {
            if !clones.insert(Key(device: device, inode: cloneID)) { size = privateSize; shared = true }
        }
        if hardlink { privateSize = 0 }
        if duplicateLink { size = 0 }
        let sharedMask = NodeFlags.hardlink.rawValue | NodeFlags.hardlinkDup.rawValue | NodeFlags.cloneShared.rawValue
        var newFlags = oldFlags.rawValue & ~sharedMask
        if hardlink { newFlags |= duplicateLink ? NodeFlags.hardlinkDup.rawValue : NodeFlags.hardlink.rawValue }
        if shared { newFlags |= NodeFlags.cloneShared.rawValue }
        return Update(id: id, size: size, privateBytes: privateSize, flags: NodeFlags(rawValue: newFlags))
    }
    func apply(_ updates: [Update]) {
        lock.lock()
        for update in updates {
            let i = Int(update.id)
            counted[i] = update.size; priv[i] = update.privateBytes; flags[i] = update.flags
        }
        lock.unlock()
    }
    func skip(_ id: Int32) {
        lock.lock(); defer { lock.unlock() }
        skipped = true; counted[Int(id)] = 0; priv[Int(id)] = 0
        skippedIDs.append(id)
        flags[Int(id)].insert(.unreadable)
    }
    func noteSkip() { lock.lock(); skipped = true; lock.unlock() }
    func fail() { lock.lock(); failed = true; cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func result() -> (failed: Bool, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (failed, cancelled)
    }
}

private func enrich(_ tree: FileTree, options: ScanOptions, progress: (@Sendable (Int, Int) -> Void)?) async throws -> FileTree {
    let fd = open(tree.rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Scanner.ScanError.cannotOpen(tree.rootPath, errno) }
    let state = Enrichment(tree: tree, fd: fd, options: options, progress: progress)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            for _ in 0..<options.workers {
                group.enter()
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: options.bufferSize)
                    while let id = state.next() { enrichDirectory(id, state, &buffer); state.finishedDirectory() }
                    group.leave()
                }
            }
            DispatchQueue.global().async {
                group.wait()
                let result = state.result()
                if result.failed { continuation.resume(throwing: Scanner.ScanError.cannotOpen(tree.rootPath, EIO)) }
                else if result.cancelled { continuation.resume(throwing: Scanner.ScanError.cancelled) }
                else { continuation.resume(returning: correctedTree(state)) }
            }
        }
    } onCancel: { state.lock.lock(); state.cancelled = true; state.lock.unlock() }
}

@inline(__always) private func nameHash<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return hash
}

private func enrichDirectory(_ id: Int32, _ s: Enrichment, _ buffer: inout [UInt8]) {
    let t = s.tree
    let fullPath = t.pathBytes(of: id)
    let rootLength = t.rootPath.utf8.count
    let relative = id == 0 ? [UInt8]([46]) : Array(fullPath.dropFirst(rootLength + (t.rootPath == "/" ? 0 : 1)))
    let path = relative.map { CChar(bitPattern: $0) } + [0]
    var fd = path.withUnsafeBufferPointer { openat(s.fd, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    if fd < 0 && errno == ENAMETOOLONG {
        var components: [DirectoryPart] = []
        var at = id
        while at > 0 {
            let i = Int(at), a = Int(t.nameOffset[i])
            components.append(DirectoryPart(bytes: Array(t.names[a..<(a + Int(t.nameLength[i]))]), key: Key(device: t.device[i], inode: t.inode[i]), firmlink: t.flags[i].contains(.firmlink)))
            at = t.parent[i]
        }
        fd = openDirectory(rootFD: s.fd, components: Array(components.reversed()), allowedDevices: s.allowedDevices)
    }
    guard fd >= 0 else { s.fail(); return }
    defer { close(fd) }
    var directoryStat = stat()
    guard fstat(fd, &directoryStat) == 0, s.allowedDevices.contains(UInt64(directoryStat.st_dev)),
          (t.flags[Int(id)].contains(.firmlink) || UInt64(directoryStat.st_dev) == t.device[Int(id)] && directoryStat.st_ino == t.inode[Int(id)]) else { s.fail(); return }
    let start = Int(t.firstChild[Int(id)]), end = start + Int(t.childCount[Int(id)])
    var byHash: [UInt64: Int32] = [:]
    var collisions: [UInt64: [Int32]] = [:]
    byHash.reserveCapacity(end - start)
    for index in start..<end {
        let child = t.children[index], i = Int(child)
        if t.flags[i].contains(.isDir) { continue }
        let a = Int(t.nameOffset[i]), b = a + Int(t.nameLength[i])
        let hash = nameHash(t.names[a..<b])
        if collisions[hash] != nil { collisions[hash]!.append(child) }
        else if let previous = byHash.removeValue(forKey: hash) { collisions[hash] = [previous, child] }
        else { byHash[hash] = child }
    }
    func sameName(_ child: Int32, _ bytes: UnsafeRawBufferPointer.SubSequence) -> Bool {
        let i = Int(child), a = Int(t.nameOffset[i]), length = Int(t.nameLength[i])
        guard length == bytes.count else { return false }
        for offset in 0..<length where t.names[a + offset] != bytes[bytes.startIndex + offset] { return false }
        return true
    }
    var attrs = attrlist()
    attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attrs.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_FILEID | ATTR_CMN_ERROR)
    attrs.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
    attrs.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
    let opts = UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)
    var pending: [Enrichment.Update] = []
    pending.reserveCapacity(256)
    while true {
        if s.isCancelled() { return }
        let n = buffer.withUnsafeMutableBytes { raw in getattrlistbulk(fd, &attrs, raw.baseAddress, raw.count, opts) }
        if n == 0 { break }
        if n < 0 { s.fail(); return }
        let valid = buffer.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var pos = 0
            for recordIndex in 0..<n {
                if recordIndex & 255 == 0 && s.isCancelled() { return false }
                guard pos <= raw.count - 4 else { return false }
                let length = Int(base.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
                guard length >= 24 && length <= raw.count - pos else { return false }
                var cursor = pos + 4
                func take<T>(_ type: T.Type) -> T? {
                    guard cursor <= pos + length - MemoryLayout<T>.size else { return nil }
                    defer { cursor += MemoryLayout<T>.size }
                    return base.loadUnaligned(fromByteOffset: cursor, as: T.self)
                }
                guard let returned = take(attribute_set_t.self) else { return false }
                var entryError: Int32 = 0
                if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 {
                    guard let value = take(Int32.self) else { return false }
                    entryError = value
                }
                guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { s.noteSkip(); pos += length; continue }
                let refAt = cursor
                guard let ref = take(attrreference_t.self) else { return false }
                let (nameStart, overflow1) = refAt.addingReportingOverflow(Int(ref.attr_dataoffset))
                let (nameEnd, overflow2) = nameStart.addingReportingOverflow(Int(ref.attr_length))
                guard !overflow1 && !overflow2 && nameStart >= pos && nameEnd <= pos + length && nameEnd > nameStart else { return false }
                let last = nameEnd - (raw[nameEnd - 1] == 0 ? 1 : 0)
                let name = raw[nameStart..<last]
                let hash = nameHash(name)
                var child: Int32?
                if var bucket = collisions[hash] {
                    if let index = bucket.firstIndex(where: { sameName($0, name) }) {
                        child = bucket.remove(at: index)
                        if bucket.isEmpty { collisions.removeValue(forKey: hash) }
                        else { collisions[hash] = bucket }
                    }
                } else if let candidate = byHash[hash], sameName(candidate, name) {
                    child = byHash.removeValue(forKey: hash)
                }
                var device: UInt32 = 0, inode: UInt64 = 0, links: UInt32 = 1, allocated: UInt64 = 0
                if returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 { guard let value = take(UInt32.self) else { return false }; device = value }
                if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 { guard let value = take(UInt64.self) else { return false }; inode = value }
                if returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 { guard let value = take(UInt32.self) else { return false }; links = value }
                if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { guard let value = take(UInt64.self) else { return false }; allocated = value }
                var privateBytes: UInt64 = 0, cloneID: UInt64 = 0, refs: UInt32 = 0
                if returned.forkattr & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { guard let value = take(UInt64.self) else { return false }; privateBytes = value }
                if returned.forkattr & UInt32(ATTR_CMNEXT_CLONEID) != 0 { guard let value = take(UInt64.self) else { return false }; cloneID = value }
                if returned.forkattr & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 { guard let value = take(UInt32.self) else { return false }; refs = value }
                if let child {
                    if entryError != 0 || device == 0 || inode == 0 || returned.forkattr & UInt32(ATTR_CMNEXT_PRIVATESIZE) == 0 {
                        s.skip(child)
                    } else {
                        if let update = s.prepareUpdate(child, device: UInt64(device), inode: inode, linkCount: links, allocated: Int64(bitPattern: allocated), privateBytes: Int64(bitPattern: privateBytes), cloneID: cloneID, refs: refs) { pending.append(update) }
                    }
                } else if entryError != 0 { s.noteSkip() }
                pos += length
            }
            return true
        }
        if !valid { if !s.isCancelled() { s.fail() }; return }
        s.apply(pending)
        pending.removeAll(keepingCapacity: true)
    }
    for child in byHash.values { s.skip(child) }
    for bucket in collisions.values { for child in bucket { s.skip(child) } }
}

private func correctedTree(_ s: Enrichment) -> FileTree {
    let t = s.tree, n = t.parent.count
    var size = s.counted, priv = s.priv
    for i in 0..<n where t.flags[i].contains(.isDir) { size[i] = 0; priv[i] = 0 }
    for i in stride(from: n - 1, through: 1, by: -1) {
        let p = Int(t.parent[i]); size[p] += size[i]; priv[p] += priv[i]
    }
    var children = t.children, first = t.firstChild
    for i in 0..<n {
        let a = Int(first[i]), b = a + Int(t.childCount[i])
        if b > a { children[a..<b].sort { size[Int($0)] > size[Int($1)] } }
    }
    var ext = t.extensions.map { ExtensionTotal(name: $0.name, bytes: 0, files: $0.files) }
    var bytes = [Int64](repeating: 0, count: ext.count)
    for i in 1..<n where t.extensionIndex[i] >= 0 { bytes[Int(t.extensionIndex[i])] += size[i] }
    let sorted = ext.indices.sorted { bytes[$0] > bytes[$1] }
    var ranks = [Int32](repeating: -1, count: ext.count)
    for (rank, old) in sorted.enumerated() { ranks[old] = Int32(rank) }
    ext = sorted.map { ExtensionTotal(name: ext[$0].name, bytes: bytes[$0], files: ext[$0].files) }
    let extIndex = t.extensionIndex.map { $0 < 0 ? -1 : ranks[Int($0)] }
    var largest = [Int32](repeating: -1, count: n)
    for i in stride(from: n - 1, through: 1, by: -1) {
        let candidate = t.flags[i].contains(.isDir) ? largest[i] : Int32(i)
        if !t.flags[i].contains(.isDir) { largest[i] = Int32(i) }
        let p = Int(t.parent[i])
        if candidate >= 0 && (largest[p] < 0 || size[Int(candidate)] > size[Int(largest[p])]) { largest[p] = candidate }
    }
    let largestType = largest.map { $0 < 0 ? Int32(-1) : extIndex[Int($0)] }
    var limits = s.skipped ? t.limitations : t.limitations.filter { !$0.contains("private and clone attributes disabled") }
    if s.skipped { limits.append("some entries changed or could not be read during shared file check") }
    let unreadablePaths = t.unreadablePaths + s.skippedIDs.map { t.path(of: $0) }
    var result = FileTree(rootPath: t.rootPath, parent: t.parent, device: t.device, inode: t.inode, linkCount: t.linkCount, firstChild: first, childCount: t.childCount, countedSize: size, privateSize: priv, logicalSize: t.logicalSize, fileCount: t.fileCount, modTime: t.modTime, extensionIndex: extIndex, largestFileType: largestType, flags: s.flags, nameOffset: t.nameOffset, nameLength: t.nameLength, names: t.names, children: children, extensions: ext, unreadablePaths: unreadablePaths, limitations: limits, volumeUsedBytes: t.volumeUsedBytes, filesSeen: t.filesSeen, dirsSeen: t.dirsSeen, largestFiles: [])
    result = FileTree(rootPath: t.rootPath, parent: t.parent, device: t.device, inode: t.inode, linkCount: t.linkCount, firstChild: first, childCount: t.childCount, countedSize: size, privateSize: priv, logicalSize: t.logicalSize, fileCount: t.fileCount, modTime: t.modTime, extensionIndex: extIndex, largestFileType: largestType, flags: s.flags, nameOffset: t.nameOffset, nameLength: t.nameLength, names: t.names, children: children, extensions: ext, unreadablePaths: unreadablePaths, limitations: limits, volumeUsedBytes: t.volumeUsedBytes, filesSeen: t.filesSeen, dirsSeen: t.dirsSeen, largestFiles: result.topFiles(limit: 100))
    return result
}
