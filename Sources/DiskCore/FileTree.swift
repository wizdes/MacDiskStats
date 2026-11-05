import Foundation

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let isDir = Self(rawValue: 1)
    public static let unreadable = Self(rawValue: 2)
    public static let hardlinkDup = Self(rawValue: 4)
    public static let cloneShared = Self(rawValue: 8)
    public static let mountPointStopped = Self(rawValue: 16)
    public static let symlink = Self(rawValue: 32)
    public static let hardlink = Self(rawValue: 64)
    public static let firmlink = Self(rawValue: 128)
}

public struct ExtensionTotal: Sendable {
    public let name: String
    public let bytes: Int64
    public let files: Int64
}

// Parallel arrays keep node storage compact. IDs and child spans stay stable after scan().
public struct FileTree: Sendable {
    public static func displayName(bytes: [UInt8]) -> String {
        if let valid = String(bytes: bytes, encoding: .utf8) { return valid }
        return bytes.map { String(format: "%%%02X", $0) }.joined()
    }
    public let rootPath: String
    public let parent: [Int32]
    public let device: [UInt64]
    public let inode: [UInt64]
    public let linkCount: [UInt32]
    public let firstChild: [Int32]
    public let childCount: [Int32]
    public let countedSize: [Int64]
    public let privateSize: [Int64]
    public let logicalSize: [Int64]
    public let fileCount: [Int64]
    public let modTime: [Int64]
    public let extensionIndex: [Int32]
    public let largestFileType: [Int32]
    public let flags: [NodeFlags]
    public let nameOffset: [Int32]
    public let nameLength: [Int32]
    public let names: [UInt8]
    public let children: [Int32]
    public let extensions: [ExtensionTotal]
    public let unreadablePaths: [String]
    public let limitations: [String]
    public let volumeUsedBytes: Int64
    public let filesSeen: Int64
    public let dirsSeen: Int64
    public let largestFiles: [Int32]

    public func path(of id: Int32) -> String {
        if id == 0 { return rootPath }
        var parts: [String] = []
        var at = id
        while at > 0 {
            let n = Int(at)
            let a = Int(nameOffset[n]), b = a + Int(nameLength[n])
            parts.append(Self.displayName(bytes: Array(names[a..<b])))
            at = parent[n]
        }
        return (rootPath == "/" ? "" : rootPath) + "/" + parts.reversed().joined(separator: "/")
    }

    public func pathBytes(of id: Int32) -> [UInt8] {
        var result = Array(rootPath.utf8)
        if id == 0 { return result }
        var parts: [[UInt8]] = [], at = id
        while at > 0 {
            let i = Int(at), a = Int(nameOffset[i])
            parts.append(Array(names[a..<(a + Int(nameLength[i]))]))
            at = parent[i]
        }
        for part in parts.reversed() {
            if result.last != 47 { result.append(47) }
            result.append(contentsOf: part)
        }
        return result
    }

    public func url(of id: Int32) -> URL {
        let bytes = pathBytes(of: id).map { CChar(bitPattern: $0) } + [0]
        return bytes.withUnsafeBufferPointer { URL(fileURLWithFileSystemRepresentation: $0.baseAddress!, isDirectory: flags[Int(id)].contains(.isDir), relativeTo: nil) }
    }

    public func topFiles(limit: Int) -> [Int32] {
        guard limit > 0 else { return [] }
        if limit <= largestFiles.count { return Array(largestFiles.prefix(limit)) }
        var heap: [Int32] = []
        func siftDown(_ start: Int) {
            var p = start
            while 2 * p + 1 < heap.count {
                var c = 2 * p + 1
                if c + 1 < heap.count && countedSize[Int(heap[c + 1])] < countedSize[Int(heap[c])] { c += 1 }
                if countedSize[Int(heap[p])] <= countedSize[Int(heap[c])] { break }
                heap.swapAt(p, c); p = c
            }
        }
        for n in parent.indices where !flags[n].contains(.isDir) {
            let id = Int32(n)
            if heap.count < limit {
                heap.append(id)
                var p = heap.count - 1
                while p > 0 && countedSize[Int(heap[p])] < countedSize[Int(heap[(p - 1) / 2])] {
                    heap.swapAt(p, (p - 1) / 2); p = (p - 1) / 2
                }
            } else if countedSize[n] > countedSize[Int(heap[0])] {
                heap[0] = id; siftDown(0)
            }
        }
        return heap.sorted { countedSize[Int($0)] > countedSize[Int($1)] }
    }
}

public struct ScanOptions: Sendable {
    public var workers: Int
    public var includePrivateSize: Bool
    public var twoPhase: Bool
    public var bufferSize: Int
    public init(workers: Int = 16, includePrivateSize: Bool = true, twoPhase: Bool = true, bufferSize: Int = 131_072) {
        self.workers = max(1, min(workers, 32)); self.includePrivateSize = includePrivateSize; self.twoPhase = twoPhase
        self.bufferSize = max(65_536, min(bufferSize, 1_048_576))
    }
}

public struct ScanProgress: Sendable {
    public let filesSeen: Int64
    public let bytesCounted: Int64
    public let firstTwoLevels: [(path: String, bytes: Int64)]
}
