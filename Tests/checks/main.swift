import Foundation
import Darwin
import DiskCore

var failures = 0
var checks = 0
@MainActor func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true).appendingPathComponent("cushion-checks-\(getpid())", isDirectory: true)
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
        let t = try await scan("clones")
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

print("checks \(checks), failed \(failures)")
exit(failures == 0 ? 0 : 1)
