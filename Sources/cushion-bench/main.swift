import Foundation
import Darwin
import DiskCore

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { print("usage: cushion-bench <path> [--no-private] [--json] [--top N]"); exit(2) }
let top = args.firstIndex(of: "--top").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 0
let workers = args.firstIndex(of: "--workers").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 16
let started = Date()
do {
    let tree = try await Scanner.scan(root: path, options: ScanOptions(workers: workers, includePrivateSize: !args.contains("--no-private")))
    let seconds = Date().timeIntervalSince(started)
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let gap = tree.volumeUsedBytes - tree.countedSize[0]
    if args.contains("--json") {
        let obj: [String: Any] = ["files": tree.filesSeen, "dirs": tree.dirsSeen, "unreadableDirs": tree.unreadablePaths.count, "countedBytes": tree.countedSize[0], "logicalBytes": tree.logicalSize[0], "privateBytes": tree.privateSize[0], "volumeUsedBytes": tree.volumeUsedBytes, "gapBytes": gap, "seconds": seconds, "filesPerSecond": Double(tree.filesSeen) / max(seconds, 0.001), "peakRSSBytes": usage.ru_maxrss, "limitations": tree.limitations]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("files \(tree.filesSeen), dirs \(tree.dirsSeen), unreadable dirs \(tree.unreadablePaths.count)")
        print("counted \(tree.countedSize[0]), logical \(tree.logicalSize[0]), private \(tree.privateSize[0]), volume used \(tree.volumeUsedBytes), gap \(gap)")
        print(String(format: "seconds %.3f, files/s %.0f, peak RSS %lld bytes", seconds, Double(tree.filesSeen) / max(seconds, 0.001), usage.ru_maxrss))
        for limit in tree.limitations { print("limit: \(limit)") }
        for p in tree.unreadablePaths { print("unreadable: \(p)") }
        for id in tree.topFiles(limit: top) { print("top: \(tree.countedSize[Int(id)]) \(tree.path(of: id))") }
    }
} catch { print("scan failed: \(error)"); exit(1) }
