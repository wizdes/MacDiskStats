import Foundation
import Darwin
import DiskCore

var failures = 0
var checks = 0
@MainActor func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true).appendingPathComponent("macdiskstats-checks-\(getpid())", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }
func scan(_ name: String) async throws -> FileTree { try await Scanner.scan(root: base.appendingPathComponent(name).path, options: ScanOptions(workers: 2)) }
func file(_ url: URL, bytes: Int = 8192) throws { try Data(repeating: 42, count: bytes).write(to: url) }
func allocated(_ url: URL) -> Int64 { var st = stat(); _ = lstat(url.path, &st); return Int64(st.st_blocks) * 512 }

do {
    let dir = base.appendingPathComponent("links"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
    try file(a); guard link(a.path, b.path) == 0 else { throw NSError(domain: "link", code: Int(errno)) }
    let t = try await scan("links")
    check("hard link counts one allocated copy", t.countedSize[0] == allocated(a))
    check("hard link duplicate flag", t.flags.contains(.hardlinkDup))
    check("hard link with another name frees zero", t.privateSize[0] == 0)
} catch { failures += 1; print("FAIL hard link setup: \(error)") }

do {
    let dir = base.appendingPathComponent("clones"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
    try file(a, bytes: 1_000_000)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/cp"); p.arguments = ["-c", a.path, b.path]
    try p.run(); p.waitUntilExit()
    if p.terminationStatus == 0 {
        var phaseOne: FileTree?
        let phased = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 2), phase1: { snapshot in phaseOne = snapshot })
        check("phase 1 clone counts both copies", phaseOne?.countedSize[0] == allocated(a) + allocated(b))
        check("phase 1 states clone limit", phaseOne?.limitations.contains(where: { $0.contains("clone") }) == true)
        check("phase 2 clone counts once", phased.countedSize[0] >= allocated(a) && phased.countedSize[0] < allocated(a) + allocated(b))
        let t = try await Scanner.scan(root: dir.path, options: ScanOptions(workers: 2, twoPhase: false))
        check("phase 2 equals full scan", phased.countedSize[0] == t.countedSize[0] && phased.privateSize[0] == t.privateSize[0])
        check("cp -c clone counted once", t.countedSize[0] >= allocated(a) && t.countedSize[0] < allocated(a) + allocated(b))
        check("cp -c clone private size", t.privateSize[0] < t.countedSize[0])
        check("cp -c clone shared flag", t.flags.contains(.cloneShared))
    } else { print("SKIP clone: cp -c unavailable on test volume") }
} catch { failures += 1; print("FAIL clone setup: \(error)") }

do {
    let dir = base.appendingPathComponent("symlinks"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: dir.appendingPathComponent("back").path, withDestinationPath: base.path)
    let t = try await scan("symlinks")
    check("symlink not followed", t.dirsSeen == 1 && t.filesSeen == 1)
    check("symlink flag", t.flags.contains(.symlink))
} catch { failures += 1; print("FAIL symlink setup: \(error)") }

do {
    let dir = base.appendingPathComponent("unreadable"); let blocked = dir.appendingPathComponent("blocked")
    try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
    _ = chmod(blocked.path, 0)
    defer { _ = chmod(blocked.path, 0o700) }
    let t = try await scan("unreadable")
    check("chmod 000 folder flagged", t.unreadablePaths.contains(blocked.path))
} catch { failures += 1; print("FAIL unreadable setup: \(error)") }

do {
    let dir = base.appendingPathComponent("readonly"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("old.txt"); try file(f)
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
    func snapshot() throws -> [(String, Int64, Int64)] {
        try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map {
            var st = stat(); _ = lstat($0.path, &st)
            return ($0.lastPathComponent, st.st_size, Int64(st.st_mtimespec.tv_sec))
        }.sorted { $0.0 < $1.0 }
    }
    let before = try snapshot(); _ = try await scan("readonly"); let after = try snapshot()
    let same = before.count == after.count && zip(before, after).allSatisfy { left, right in
        left.0 == right.0 && left.1 == right.1 && left.2 == right.2
    }
    check("scan leaves names sizes dates unchanged", same)
} catch { failures += 1; print("FAIL read-only setup: \(error)") }

do {
    let dir = base.appendingPathComponent("map"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, size) in [("a.txt", 500_000), ("b.png", 300_000), ("c.pdf", 200_000)] { try file(dir.appendingPathComponent(name), bytes: size) }
    let mapTree = try await scan("map")
    let map = Treemap.layout(tree: mapTree, rootNode: 0, widthPx: 100, heightPx: 100)
    let ids = Array(mapTree.children.prefix(3))
    let leafAreas = ids.compactMap { map.rect(of: $0) }.map { $0.width * $0.height }
    let inside = ids.allSatisfy { id -> Bool in
        guard let r = map.rect(of: id) else { return false }
        return r.x >= 0 && r.y >= 0 && r.x + r.width <= 100 && r.y + r.height <= 100
    }
    check("bug: layout overflow; leaf areas cover map and stay inside", abs(leafAreas.reduce(0, +) - 10_000) <= 100 && inside)
    let proportional = zip(leafAreas, ids).allSatisfy { area, id in abs(Double(area) / 10_000 - Double(mapTree.countedSize[Int(id)]) / Double(mapTree.countedSize[0])) <= 0.1 }
    check("bug: wrong squarify scale; large areas track size", proportional)
    let centersHit = ids.allSatisfy { id -> Bool in
        guard let r = map.rect(of: id) else { return false }
        return map.hitTest(x: r.x + r.width / 2, y: r.y + r.height / 2) == id
    }
    check("bug: grid lookup off by one; center hits its box", centersHit)
    let ridgeScale = ids.allSatisfy { id -> Bool in
        guard let box = map.rect(of: id), let i = map.nodeIDs.firstIndex(of: id), box.width > 0, box.height > 0 else { return false }
        let expectedX = -4 * TreemapParams().ridgeHeight / Float(box.width)
        let expectedY = -4 * TreemapParams().ridgeHeight / Float(box.height)
        return abs(map.surfaceX2[i] - expectedX) < 0.001 && abs(map.surfaceY2[i] - expectedY) < 0.001
    }
    check("bug: cushion ridge follows van Wijk height equation", ridgeScale)
    if let png = mapTree.extensions.firstIndex(where: { $0.name == "png" }),
       let node = ids.first(where: { mapTree.extensionIndex[Int($0)] == Int32(png) }),
       let box = map.rect(of: node) {
        var params = TreemapParams()
        params.palette = [MapColor(255, 0, 0)]
        params.otherColor = MapColor(0, 0, 255)
        params.ambient = 1
        params.diffuse = 0
        var pixels: [UInt8] = []
        Treemap.shade(map, into: &pixels, params: params)
        let at = ((box.y + box.height / 2) * map.width + box.x + box.width / 2) * 4
        check("types beyond palette use gray instead of repeating a color", pixels[at] == 0 && pixels[at + 2] == 255)
    } else { check("types beyond palette use gray instead of repeating a color", false) }
} catch { failures += 1; print("FAIL map setup: \(error)") }

do {
    let dir = base.appendingPathComponent("cushion")
    let nested = dir.appendingPathComponent("one/two")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    try file(nested.appendingPathComponent("large.dat"), bytes: 100_000)
    let tree = try await scan("cushion")
    let map = Treemap.layout(tree: tree, rootNode: 0, widthPx: 256, heightPx: 256)
    var params = TreemapParams()
    params.palette = Array(repeating: MapColor(255, 255, 255), count: params.palette.count)
    params.otherColor = MapColor(255, 255, 255)
    var pixels: [UInt8] = []
    Treemap.shade(map, into: &pixels, params: params)
    let values = (8..<248).flatMap { y in (8..<248).map { x in Int(pixels[(y * 256 + x) * 4]) } }
    let floor = Int((params.ambient * 255).rounded()) + 1
    let floorFraction = Double(values.filter { $0 <= floor }.count) / Double(values.count)
    let center = Int(pixels[(128 * 256 + 128) * 4])
    let smooth = (8..<248).allSatisfy { y in (8..<247).allSatisfy { x in
        abs(Int(pixels[(y * 256 + x) * 4]) - Int(pixels[(y * 256 + x + 1) * 4])) <= 4
    } }
    check("bug: cushion ambient-floor wedge at depth three", floorFraction < 0.02 && center >= 217 && values.max()! - values.min()! >= 20 && smooth)
} catch { failures += 1; print("FAIL cushion setup: \(error)") }

do {
    let dir = base.appendingPathComponent("map-type"), many = dir.appendingPathComponent("many")
    try fm.createDirectory(at: many, withIntermediateDirectories: true)
    for i in 0..<6 { try file(many.appendingPathComponent("\(i).png"), bytes: 10_000) }
    try file(dir.appendingPathComponent("largest.txt"), bytes: 50_000)
    let tree = try await scan("map-type")
    let map = Treemap.layout(tree: tree, rootNode: 0, widthPx: 1, heightPx: 1)
    let type = tree.extensions.firstIndex(where: { $0.name == "txt" })
    check("bug: collapsed folder uses largest file type", type != nil && map.colorIndex.first == Int32(type!))
} catch { failures += 1; print("FAIL map type setup: \(error)") }

func dfUsed(_ path: String) throws -> Int64 {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/df"); p.arguments = ["-k", path]; p.standardOutput = pipe
    try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let rows = String(decoding: data, as: UTF8.self).split(separator: "\n")
    guard p.terminationStatus == 0, rows.count >= 2 else { throw NSError(domain: "df", code: 1) }
    let columns = rows[1].split(whereSeparator: \.isWhitespace)
    guard columns.count >= 3, let used = Int64(columns[2]) else { throw NSError(domain: "df", code: 2) }
    return used * 1024
}
do {
    let expected = try dfUsed("/") + dfUsed("/System/Volumes/Data")
    check("bug: APFS container use exceeds root and Data volumes", abs(Scanner.volumeUsedBytes(root: "/") - expected) < 16_000_000)
} catch { failures += 1; print("FAIL df setup: \(error)") }

print("checks \(checks), failed \(failures)")
exit(failures == 0 ? 0 : 1)
