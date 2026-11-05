import Foundation
import Darwin
import DiskCore

func capabilities(_ path: String) -> (UInt32, UInt32, Int32) {
    var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attrs.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES)
    var b = [UInt8](repeating: 0, count: 80)
    let rc = b.withUnsafeMutableBytes { getattrlist(path, &attrs, $0.baseAddress, $0.count, 0) }
    if rc != 0 { return (0, 0, errno) }
    return b.withUnsafeBytes { raw in
        (raw.loadUnaligned(fromByteOffset: 4 + 4, as: UInt32.self), raw.loadUnaligned(fromByteOffset: 4 + 4 + 16, as: UInt32.self), 0)
    }
}
func cpu() -> (Double, Double) {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return (Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6,
            Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6)
}
func search(_ path: String, _ kind: String, _ repeatIndex: Int) {
    let caps = capabilities(path)
    print("searchfs capability \(path): interfaces=\(String(caps.0, radix:16)) valid=\(String(caps.1, radix:16)) error=\(caps.2) supported=\((caps.0 & caps.1 & UInt32(VOL_CAP_INT_SEARCHFS)) != 0)")
    var ret = attrlist(); ret.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    ret.commonattr = UInt32(ATTR_CMN_NAME | ATTR_CMN_FILEID | ATTR_CMN_PARENTID | ATTR_CMN_OBJTYPE)
    ret.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)
    if kind == "private" { ret.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT) }
    var query = attrlist(); query.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); query.commonattr = UInt32(ATTR_CMN_NAME)
    var name = attrreference_t(attr_dataoffset: 8, attr_length: 1)
    var params = [UInt8](repeating: 0, count: 16)
    var paramLength: UInt32 = 16
    withUnsafeBytes(of: &paramLength) { params.replaceSubrange(0..<4, with: $0) }
    withUnsafeBytes(of: &name) { params.replaceSubrange(4..<12, with: $0) }
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    var state = searchstate()
    var matched: UInt = 0
    let before = cpu(), start = CFAbsoluteTimeGetCurrent()
    var total: UInt64 = 0, bytes: UInt64 = 0, calls = 0, result: Int32 = 0, error: Int32 = 0
    var options = UInt32(SRCHFS_START | SRCHFS_MATCHPARTIALNAMES | SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS)
    repeat {
        result = withUnsafeMutablePointer(to: &ret) { retPtr in params.withUnsafeMutableBytes { p in buffer.withUnsafeMutableBytes { b in
            var block = fssearchblock(returnattrs: retPtr, returnbuffer: b.baseAddress, returnbuffersize: b.count, maxmatches: 100_000, timelimit: timeval(tv_sec: 1, tv_usec: 0), searchparams1: p.baseAddress, sizeofsearchparams1: p.count, searchparams2: p.baseAddress, sizeofsearchparams2: p.count, searchattrs: query)
            return searchfs(path, &block, &matched, 0x08000103, options, &state)
        }}}
        error = errno; calls += 1; total += UInt64(matched)
        if calls % 50 == 0 { fputs("searchfs progress \(path) calls=\(calls) entries=\(total) error=\(error)\n", stderr) }
        if kind == "probe" && calls == 1 {
            buffer.withUnsafeBytes { raw in
                var pos = 0
                for _ in 0..<min(3, Int(matched)) {
                    let length = Int(raw.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
                    print("probe length=\(length) data=\(raw[pos..<min(pos+length,pos+96)].map { String(format:"%02x",$0) }.joined(separator:" "))")
                    pos += length
                }
            }
        }
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var pos = 0
            for _ in 0..<matched {
                if pos + 4 > raw.count { break }
                let length = Int(base.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
                if length < 4 || pos + length > raw.count { break }
                // Search results omit RETURNED_ATTRS and use the requested fixed order.
                let allocAt = pos + 4 + MemoryLayout<attrreference_t>.size + 4 + 8 + 8
                let nameData = pos + 4 + Int(base.loadUnaligned(fromByteOffset: pos + 4, as: attrreference_t.self).attr_dataoffset)
                if nameData >= allocAt + 8 && allocAt + 8 <= pos + length { bytes &+= base.loadUnaligned(fromByteOffset: allocAt, as: UInt64.self) }
                pos += length
            }
        }
        options &= ~UInt32(SRCHFS_START)
    } while result < 0 && error == EAGAIN && calls < 10_000 && kind != "probe"
    let after = cpu()
    print("searchfs root=\(path) kind=\(kind) repeat=\(repeatIndex) rc=\(result) errno=\(error) entries=\(total) bytes=\(bytes) calls=\(calls) wall=\(String(format:"%.3f",CFAbsoluteTimeGetCurrent()-start)) user=\(String(format:"%.3f",after.0-before.0)) sys=\(String(format:"%.3f",after.1-before.1))")
}

final class Walk: @unchecked Sendable {
    let lock = NSCondition()
    var paths = [String]()
    var next = 0, active = 0
    var entries: Int64 = 0, bytes: Int64 = 0, dirs: Int64 = 0, errors: Int64 = 0
    let root: String, device: dev_t, attrsKind: String, bufferSize: Int
    init(_ root: String, _ kind: String, _ size: Int) {
        self.root = root; attrsKind = kind; bufferSize = size; paths = [root]
        var s = stat(); _ = stat(root, &s); device = s.st_dev
    }
    func pop() -> String? {
        lock.lock(); defer { lock.unlock() }
        while next == paths.count && active > 0 { lock.wait() }
        if next == paths.count { return nil }
        let p = paths[next]; next += 1; active += 1; return p
    }
    func done(_ names: [String], _ n: Int64, _ b: Int64, _ e: Int64) {
        lock.lock(); paths.append(contentsOf: names); dirs += Int64(names.count); entries += n; bytes += b; errors += e; active -= 1; lock.broadcast(); lock.unlock()
    }
}
func walk(_ root: String, _ kind: String, _ workers: Int, _ size: Int, _ repeatIndex: Int) {
    let w = Walk(root, kind, size), before = cpu(), start = CFAbsoluteTimeGetCurrent()
    let group = DispatchGroup()
    for _ in 0..<workers {
        group.enter()
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: size)
            while let path = w.pop() {
                var child = [String](), n: Int64 = 0, bytes: Int64 = 0, errors: Int64 = 0
                let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 { w.done([],0,0,1); continue }
                var attrs = attrlist(); attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
                attrs.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_DEVID)
                attrs.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)
                let isolated = ["fileid", "modtime", "flags", "mount", "linkcount", "totalsize", "error"].contains(kind)
                if !isolated && kind != "count" { attrs.commonattr |= UInt32(ATTR_CMN_FILEID | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS); attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS); attrs.fileattr |= UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE) }
                if kind == "fileid" { attrs.commonattr |= UInt32(ATTR_CMN_FILEID) }
                if kind == "modtime" { attrs.commonattr |= UInt32(ATTR_CMN_MODTIME) }
                if kind == "flags" { attrs.commonattr |= UInt32(ATTR_CMN_FLAGS) }
                if kind == "mount" { attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS) }
                if kind == "linkcount" { attrs.fileattr |= UInt32(ATTR_FILE_LINKCOUNT) }
                if kind == "totalsize" { attrs.fileattr |= UInt32(ATTR_FILE_TOTALSIZE) }
                if kind == "error" { attrs.commonattr |= UInt32(ATTR_CMN_ERROR) }
                if kind == "private" { attrs.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE) }
                if kind == "clone" { attrs.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT) }
                if kind == "cloneid" { attrs.forkattr = UInt32(ATTR_CMNEXT_CLONEID) }
                if kind == "clonerefs" { attrs.forkattr = UInt32(ATTR_CMNEXT_CLONE_REFCNT) }
                if kind == "cloneidrefs" { attrs.forkattr = UInt32(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT) }
                let opts: UInt64 = attrs.forkattr != 0 ? UInt64(FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED) : UInt64(FSOPT_PACK_INVAL_ATTRS)
                while true {
                    let count = buffer.withUnsafeMutableBytes { getattrlistbulk(fd, &attrs, $0.baseAddress, $0.count, opts) }
                    if count <= 0 { if count < 0 { errors += 1 }; break }
                    buffer.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        var pos = 0
                        for _ in 0..<count {
                            let length = Int(base.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
                            if length < 24 || pos + length > raw.count { errors += 1; break }
                            var cursor = pos + 4
                            let returned = base.loadUnaligned(fromByteOffset: cursor, as: attribute_set_t.self)
                            cursor += MemoryLayout<attribute_set_t>.size
                            let common = returned.commonattr
                            if common & UInt32(ATTR_CMN_ERROR) != 0 { cursor += 4 }
                            let refAt = cursor
                            let ref = base.loadUnaligned(fromByteOffset: cursor, as: attrreference_t.self)
                            cursor += MemoryLayout<attrreference_t>.size
                            let nameStart = refAt + Int(ref.attr_dataoffset), nameEnd = nameStart + Int(ref.attr_length)
                            if nameStart < pos || nameEnd > pos + length || nameEnd <= nameStart { errors += 1; pos += length; continue }
                            let end = nameEnd - (raw[nameEnd-1] == 0 ? 1 : 0)
                            let name = String(decoding: raw[nameStart..<end], as: UTF8.self)
                            var dev: UInt32 = 0, type: UInt32 = 0
                            if common & UInt32(ATTR_CMN_DEVID) != 0 { dev = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
                            if common & UInt32(ATTR_CMN_OBJTYPE) != 0 { type = base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self); cursor += 4 }
                            if common & UInt32(ATTR_CMN_MODTIME) != 0 { cursor += MemoryLayout<timespec>.size }
                            if common & UInt32(ATTR_CMN_FLAGS) != 0 { cursor += 4 }
                            if common & UInt32(ATTR_CMN_FILEID) != 0 { cursor += 8 }
                            if returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 { cursor += 4 }
                            if returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 { cursor += 4 }
                            if returned.fileattr & UInt32(ATTR_FILE_TOTALSIZE) != 0 { cursor += 8 }
                            if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { bytes += Int64(bitPattern: base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)); cursor += 8 }
                            if type == UInt32(VDIR.rawValue) && dev == UInt32(w.device) && name != "." && name != ".." && !(root == "/" && path == "/System/Volumes/Data") { child.append(path == "/" ? "/" + name : path + "/" + name) }
                            n += 1; pos += length
                        }
                    }
                }
                close(fd); w.done(child,n,bytes,errors)
            }
            group.leave()
        }
    }
    group.wait(); let after = cpu()
    print("bulk root=\(root) kind=\(kind) workers=\(workers) buffer=\(size) repeat=\(repeatIndex) entries=\(w.entries) dirs=\(w.dirs) bytes=\(w.bytes) errors=\(w.errors) wall=\(String(format:"%.3f",CFAbsoluteTimeGetCurrent()-start)) user=\(String(format:"%.3f",after.0-before.0)) sys=\(String(format:"%.3f",after.1-before.1))")
}
let args = CommandLine.arguments
if args.count < 2 { print("usage: scan-lab search|bulk root [kind workers buffer repeats]"); exit(2) }
if args[1] == "search" { for root in ["/", "/System/Volumes/Data"] { for i in 1...(args.count > 3 ? Int(args[3]) ?? 2 : 2) { search(root, args.count > 2 ? args[2] : "basic", i) } }; exit(0) }
if args[1] == "bulk" {
    let root = args.count > 2 ? args[2] : "/", kind = args.count > 3 ? args[3] : "count"
    let workers = args.count > 4 ? Int(args[4]) ?? 8 : 8, size = args.count > 5 ? Int(args[5]) ?? 131072 : 131072
    let repeats = args.count > 6 ? Int(args[6]) ?? 2 : 2
    for i in 1...repeats { walk(root,kind,workers,size,i) }
}
if args[1] == "tree" {
    let root = args.count > 2 ? args[2] : "/"
    let workers = args.count > 3 ? Int(args[3]) ?? 16 : 16
    let privateSize = args.count > 4 ? args[4] != "no-private" : true
    let repeats = args.count > 5 ? Int(args[5]) ?? 2 : 2
    let bufferSize = args.count > 6 ? Int(args[6]) ?? 131_072 : 131_072
    for i in 1...repeats {
        let before = cpu(), start = CFAbsoluteTimeGetCurrent()
        do {
            let tree = try await Scanner.scan(root: root, options: ScanOptions(workers: workers, includePrivateSize: privateSize, bufferSize: bufferSize))
            let after = cpu()
            print("tree root=\(root) workers=\(workers) buffer=\(bufferSize) private=\(privateSize) repeat=\(i) entries=\(tree.filesSeen + tree.dirsSeen - 1) files=\(tree.filesSeen) dirs=\(tree.dirsSeen) bytes=\(tree.countedSize[0]) unreadable=\(tree.unreadablePaths.count) wall=\(String(format:"%.3f",CFAbsoluteTimeGetCurrent()-start)) user=\(String(format:"%.3f",after.0-before.0)) sys=\(String(format:"%.3f",after.1-before.1))")
        } catch { print("tree failed: \(error)"); exit(1) }
    }
}
