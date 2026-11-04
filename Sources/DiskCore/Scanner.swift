import Foundation
import Darwin

private struct Key: Hashable { let device: UInt64; let inode: UInt64 }
private final class Shards: @unchecked Sendable {
    private let locks = (0..<64).map { _ in NSLock() }
    private var sets = (0..<64).map { _ in Set<Key>() }
    func insert(_ key: Key) -> Bool {
        let i = Int((key.inode ^ key.device) & 63)
        locks[i].lock(); defer { locks[i].unlock() }
        return sets[i].insert(key).inserted
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
private struct Job { let id: Int32; let path: String }
private final class State: @unchecked Sendable {
    let lock = NSCondition()
    var queue: [Job] = []
    var queueHead = 0
    var active = 0
    var done = false
    var cancelled = false
    var lastProgress = Date.distantPast
    var parent: [Int32] = [-1]
    var counted: [Int64] = [0]
    var priv: [Int64] = [0]
    var logical: [Int64] = [0]
    var files: [Int64] = [0]
    var mod: [Int64] = [0]
    var flags: [NodeFlags] = [.isDir]
    var offsets: [Int32] = [0]
    var lengths: [Int32] = [0]
    var names: [UInt8] = []
    var unreadable: [Int32] = []
    var limitations = Set<String>()
    var seenDirs = Set<Key>()
    var openedDirs = Set<Key>()
    var filesSeen: Int64 = 0
    var dirsSeen: Int64 = 1
    var runningBytes: Int64 = 0
    var levelBytes: [Int32: Int64] = [:]
    var progress: (@Sendable (ScanProgress) -> Void)?
    let links = Shards()
    let clones = Shards()
    let rootPath: String
    let rootDevice: UInt64
    let dataDevice: UInt64
    let volumeUsed: Int64
    let options: ScanOptions
    init(path: String, device: UInt64, dataDevice: UInt64, inode: UInt64, volumeUsed: Int64, options: ScanOptions, progress: (@Sendable (ScanProgress) -> Void)?) {
        rootPath = path; rootDevice = device; self.dataDevice = dataDevice; self.volumeUsed = volumeUsed; self.options = options; self.progress = progress
        if !options.includePrivateSize { limitations.insert("private and clone attributes disabled; shared clone bytes may be counted twice") }
        seenDirs.insert(Key(device: device, inode: inode)); openedDirs.insert(Key(device: device, inode: inode)); queue = [Job(id: 0, path: path)]
    }
    func next() -> Job? {
        lock.lock(); defer { lock.unlock() }
        while queueHead == queue.count && active > 0 && !cancelled { lock.wait() }
        if cancelled || queueHead == queue.count { done = true; lock.broadcast(); return nil }
        let j = queue[queueHead]; queueHead += 1; active += 1
        return j
    }
    func finished() {
        lock.lock(); active -= 1
        if queueHead == queue.count && active == 0 { done = true }
        lock.broadcast(); lock.unlock()
    }
    func add(_ e: Entry, parent p: Int32, path: String, forceUnreadable: Bool = false) {
        let isDir = e.type == UInt32(VDIR.rawValue)
        let isLink = e.type == UInt32(VLNK.rawValue)
        var f: NodeFlags = []
        if isDir { f.insert(.isDir) }
        if isLink { f.insert(.symlink) }
        let key = Key(device: e.device, inode: e.inode)
        var size = isDir ? 0 : max(0, e.allocated)
        var privateSize = isDir || !options.includePrivateSize ? 0 : max(0, e.privateBytes)
        if !isDir && !isLink && e.links > 1 {
            privateSize = 0
            if !links.insert(key) { size = 0; f.insert(.hardlinkDup) }
        } else if !isDir && !isLink && e.cloneRefs > 1 && e.cloneID != 0 {
            let clone = Key(device: e.device, inode: e.cloneID)
            if !clones.insert(clone) { size = privateSize; f.insert(.cloneShared) }
        }
        lock.lock()
        let id = Int32(self.parent.count)
        self.parent.append(p); counted.append(size); priv.append(privateSize)
        logical.append(isDir ? 0 : max(0, e.logical)); files.append(isDir ? 0 : 1)
        mod.append(e.mod); flags.append(f)
        offsets.append(Int32(names.count)); lengths.append(Int32(e.name.count)); names.append(contentsOf: e.name)
        runningBytes += size
        if size > 0 {
            var ancestor = p
            while ancestor > 0 {
                let upper = self.parent[Int(ancestor)]
                if upper == 0 || (upper > 0 && self.parent[Int(upper)] == 0) { levelBytes[ancestor, default: 0] += size }
                ancestor = upper
            }
        }
        if isDir {
            dirsSeen += 1
            let sameVolume = e.device == rootDevice || (rootPath == "/" && e.device == dataDevice)
            let firmlink = rootPath == "/" && sameVolume && ((e.commonFlags & UInt32(SF_FIRMLINK)) != 0 || (p == 0 && ["Users", "Applications", "Library", "private", "Volumes"].contains(path)))
            if forceUnreadable || e.error != 0 { flags[Int(id)].insert(.unreadable); unreadable.append(id) }
            else if path == "System/Volumes/Data" && rootPath == "/" { flags[Int(id)].insert(.mountPointStopped) }
            else if (e.mount != 0 || !sameVolume) && !firmlink { flags[Int(id)].insert(.mountPointStopped) }
            else if !seenDirs.insert(key).inserted { flags[Int(id)].insert(.mountPointStopped) }
            else { queue.append(Job(id: id, path: (rootPath == "/" ? "" : rootPath) + "/" + path)); lock.broadcast() }
        } else { filesSeen += 1 }
        let now = Date()
        if now.timeIntervalSince(lastProgress) >= 0.25 {
            lastProgress = now
            let totals = levelBytes.map { (path: relativePath($0.key), bytes: $0.value) }
            let info = ScanProgress(filesSeen: filesSeen, bytesCounted: runningBytes, firstTwoLevels: totals)
            let callback = progress
            lock.unlock(); callback?(info); return
        }
        lock.unlock()
    }
    func markUnreadable(_ id: Int32) {
        lock.lock(); if !flags[Int(id)].contains(.unreadable) { flags[Int(id)].insert(.unreadable); unreadable.append(id) }; lock.unlock()
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
    public enum ScanError: Error { case cannotOpen(String, Int32), cancelled }
    public static func scan(root path: String, options: ScanOptions = ScanOptions(), progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> FileTree {
        let normalized = path == "/" ? "/" : String(path.drop(while: { $0 == "/" })).isEmpty ? path : (path.hasSuffix("/") ? String(path.dropLast()) : path)
        let fd = open(normalized, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ScanError.cannotOpen(normalized, errno) }
        var st = stat(); var fs = statfs()
        guard fstat(fd, &st) == 0 else { let e = errno; close(fd); throw ScanError.cannotOpen(normalized, e) }
        _ = fstatfs(fd, &fs); close(fd)
        // `/` exposes Data through firmlinks; use Data's used-space figure for its gap.
        var dataDevice = UInt64(st.st_dev)
        if normalized == "/" {
            var dataStat = stat()
            if stat("/System/Volumes/Data", &dataStat) == 0 { dataDevice = UInt64(dataStat.st_dev) }
            _ = statfs("/System/Volumes/Data", &fs)
        }
        let used = Int64(fs.f_blocks - fs.f_bfree) * Int64(fs.f_bsize)
        let state = State(path: normalized, device: UInt64(st.st_dev), dataDevice: dataDevice, inode: st.st_ino, volumeUsed: used, options: options, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let group = DispatchGroup()
                for _ in 0..<options.workers {
                    group.enter()
                    Thread.detachNewThread {
                        var buffer = [UInt8](repeating: 0, count: 131_072)
                        while let job = state.next() {
                            scanDirectory(job, state, &buffer)
                            state.finished()
                        }
                        group.leave()
                    }
                }
                DispatchQueue.global().async {
                    group.wait()
                    if state.cancelled { continuation.resume(throwing: ScanError.cancelled) }
                    else { continuation.resume(returning: finish(state)) }
                }
            }
        } onCancel: {
            state.lock.lock(); state.cancelled = true; state.lock.broadcast(); state.lock.unlock()
        }
    }
}

private func scanDirectory(_ job: Job, _ s: State, _ buffer: inout [UInt8]) {
    let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { s.markUnreadable(job.id); return }
    defer { close(fd) }
    var st = stat(); if fstat(fd, &st) != 0 { s.markUnreadable(job.id); return }
    // The opened directory, rather than its parent's entry, determines volume identity.
    if UInt64(st.st_dev) != s.rootDevice && UInt64(st.st_dev) != s.dataDevice && job.id != 0 { return }
    if !s.enterOpened(job.id, key: Key(device: UInt64(st.st_dev), inode: st.st_ino)) { return }
    var attrs = attrlist()
    attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attrs.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_ERROR)
    attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
    attrs.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
    if s.options.includePrivateSize { attrs.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT) }
    let opts = UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED)
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
        for _ in 0..<count {
            if pos + 4 > raw.count { return }
            let length = Int(base.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
            if length < 24 || pos + length > raw.count { return }
            var cursor = pos + 4
            let returned = base.loadUnaligned(fromByteOffset: cursor, as: attribute_set_t.self)
            cursor += MemoryLayout<attribute_set_t>.size
            let common = returned.commonattr, dirs = returned.dirattr, files = returned.fileattr, ext = returned.forkattr
            var e = Entry(name: UnsafeRawBufferPointer(start: nil, count: 0))
            // ATTR_CMN_ERROR precedes the normal common attributes in bulk records.
            if common & UInt32(ATTR_CMN_ERROR) != 0 { e.error = base.loadUnaligned(fromByteOffset: cursor, as: Int32.self); cursor += 4 }
            // Other attributes follow ascending bit order within each group.
            if common & UInt32(ATTR_CMN_NAME) != 0 {
                let refAt = cursor
                let ref = base.loadUnaligned(fromByteOffset: cursor, as: attrreference_t.self)
                cursor += MemoryLayout<attrreference_t>.size
                let start = refAt + Int(ref.attr_dataoffset)
                let end = start + Int(ref.attr_length)
                if start >= pos && end <= pos + length && end > start { e.name = UnsafeRawBufferPointer(rebasing: raw[start..<(end - (raw[end - 1] == 0 ? 1 : 0))]) }
            }
            if common & UInt32(ATTR_CMN_DEVID) != 0 { e.device = UInt64(base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)); cursor += 4 }
            if common & UInt32(ATTR_CMN_OBJTYPE) != 0 { e.type = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
            if common & UInt32(ATTR_CMN_MODTIME) != 0 { e.mod = Int64(base.loadUnaligned(fromByteOffset: cursor, as: timespec.self).tv_sec); cursor += MemoryLayout<timespec>.size }
            if common & UInt32(ATTR_CMN_FLAGS) != 0 { e.commonFlags = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
            if common & UInt32(ATTR_CMN_FILEID) != 0 { e.inode = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self); cursor += 8 }
            if dirs & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 { e.mount = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
            if files & UInt32(ATTR_FILE_LINKCOUNT) != 0 { e.links = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
            if files & UInt32(ATTR_FILE_TOTALSIZE) != 0 { e.logical = Int64(bitPattern: base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)); cursor += 8 }
            if files & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { e.allocated = Int64(bitPattern: base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)); cursor += 8 }
            if ext & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { e.privateBytes = Int64(bitPattern: base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)); cursor += 8 }
            if ext & UInt32(ATTR_CMNEXT_CLONEID) != 0 { e.cloneID = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self); cursor += 8 }
            if ext & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 { e.cloneRefs = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
            if !e.name.isEmpty && !(e.name.count == 1 && e.name[0] == 46) && !(e.name.count == 2 && e.name[0] == 46 && e.name[1] == 46) {
                let relative: String
                if e.type == UInt32(VDIR.rawValue) {
                    let name = String(decoding: e.name, as: UTF8.self)
                    relative = parent.id == 0 ? name : String(parent.path.dropFirst(s.rootPath == "/" ? 1 : s.rootPath.count + 1)) + "/" + name
                } else { relative = "" }
                s.add(e, parent: parent.id, path: relative)
            }
            pos += length
        }
    }
}

private func fallback(_ fd: Int32, _ job: Job, _ s: State) {
    let dupFD = dup(fd); guard dupFD >= 0, let dir = fdopendir(dupFD) else { if dupFD >= 0 { close(dupFD) }; s.markUnreadable(job.id); return }
    defer { closedir(dir) }
    while let d = readdir(dir) {
        let name = withUnsafePointer(to: d.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
        if name == "." || name == ".." { continue }
        var st = stat()
        if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { continue }
        name.withCString { pointer in
            var e = Entry(name: UnsafeRawBufferPointer(start: pointer, count: name.utf8.count))
            e.device = UInt64(st.st_dev); e.inode = st.st_ino; e.links = UInt32(st.st_nlink)
            e.type = (st.st_mode & S_IFMT) == S_IFDIR ? UInt32(VDIR.rawValue) : ((st.st_mode & S_IFMT) == S_IFLNK ? UInt32(VLNK.rawValue) : UInt32(VREG.rawValue))
            e.allocated = Int64(st.st_blocks) * 512; e.logical = st.st_size; e.mod = Int64(st.st_mtimespec.tv_sec)
            let relative = e.type == UInt32(VDIR.rawValue) ? (job.id == 0 ? name : String(job.path.dropFirst(s.rootPath == "/" ? 1 : s.rootPath.count + 1)) + "/" + name) : ""
            s.add(e, parent: job.id, path: relative)
        }
    }
}

private func finish(_ s: State) -> FileTree {
    let n = s.parent.count
    var childLists = Array(repeating: [Int32](), count: n)
    for i in 1..<n { childLists[Int(s.parent[i])].append(Int32(i)) }
    var order: [Int32] = [0], idx = 0
    while idx < order.count { order.append(contentsOf: childLists[Int(order[idx])]); idx += 1 }
    for id in order.reversed() where id != 0 {
        let p = Int(s.parent[Int(id)])
        s.counted[p] += s.counted[Int(id)]; s.priv[p] += s.priv[Int(id)]
        s.logical[p] += s.logical[Int(id)]; s.files[p] += s.files[Int(id)]
    }
    var children: [Int32] = [], first = Array(repeating: Int32(0), count: n), counts = Array(repeating: Int32(0), count: n)
    for i in 0..<n {
        childLists[i].sort { s.counted[Int($0)] > s.counted[Int($1)] }
        first[i] = Int32(children.count); counts[i] = Int32(childLists[i].count)
        children.append(contentsOf: childLists[i])
    }
    var extMap: [String: (Int64, Int64)] = [:]
    var keys = Array(repeating: "", count: n)
    for i in 1..<n where !s.flags[i].contains(.isDir) {
        let name = String(decoding: s.names[Int(s.offsets[i])..<(Int(s.offsets[i]) + Int(s.lengths[i]))], as: UTF8.self)
        let ext = name.lastIndex(of: ".").map { String(name[name.index(after: $0)...]).lowercased() } ?? ""
        keys[i] = ext
        let old = extMap[ext] ?? (0,0); extMap[ext] = (old.0 + s.counted[i], old.1 + 1)
    }
    let sorted = extMap.keys.sorted { extMap[$0]!.0 > extMap[$1]!.0 }
    let indices = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element, Int32($0.offset)) })
    let extIndex = keys.enumerated().map { s.flags[$0.offset].contains(.isDir) ? Int32(-1) : (indices[$0.element] ?? -1) }
    let extensions = sorted.map { ExtensionTotal(name: $0, bytes: extMap[$0]!.0, files: extMap[$0]!.1) }
    var tree = FileTree(rootPath: s.rootPath, parent: s.parent, firstChild: first, childCount: counts, countedSize: s.counted, privateSize: s.priv, logicalSize: s.logical, fileCount: s.files, modTime: s.mod, extensionIndex: extIndex, flags: s.flags, nameOffset: s.offsets, nameLength: s.lengths, names: s.names, children: children, extensions: extensions, unreadablePaths: [], limitations: s.limitations.sorted(), volumeUsedBytes: s.volumeUsed, filesSeen: s.filesSeen, dirsSeen: s.dirsSeen, largestFiles: [])
    let paths = s.unreadable.map { tree.path(of: $0) }
    let largest = tree.topFiles(limit: 100)
    tree = FileTree(rootPath: s.rootPath, parent: s.parent, firstChild: first, childCount: counts, countedSize: s.counted, privateSize: s.priv, logicalSize: s.logical, fileCount: s.files, modTime: s.mod, extensionIndex: extIndex, flags: s.flags, nameOffset: s.offsets, nameLength: s.lengths, names: s.names, children: children, extensions: extensions, unreadablePaths: paths, limitations: s.limitations.sorted(), volumeUsedBytes: s.volumeUsed, filesSeen: s.filesSeen, dirsSeen: s.dirsSeen, largestFiles: largest)
    return tree
}
