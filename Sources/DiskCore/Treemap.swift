import Foundation
import Dispatch

public struct PixelRect: Sendable {
    public let x: Int, y: Int, width: Int, height: Int
}

public struct MapColor: Sendable {
    public let r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
}

public struct TreemapParams: Sendable {
    public var ridgeHeight: Float = 0.36
    public var ridgeFactor: Float = 0.75
    public var ambient: Float = 0.55
    public var diffuse: Float = 0.45
    public var light: (Float, Float, Float) = (-0.09759, -0.19518, 0.97590)
    public var palette: [MapColor] = [MapColor(67, 147, 220), MapColor(99, 185, 130), MapColor(230, 169, 73), MapColor(169, 122, 211), MapColor(220, 111, 117), MapColor(85, 187, 185)]
    public var otherColor = MapColor(120, 137, 155)
    public var backgroundColor = MapColor(24, 29, 35)
    public var folderEdgeFactor: Float = 0.72
    public init() {}
}

// Four surface coefficients encode the x and y slopes of a quadratic cushion.
// A constant height term is omitted because lighting uses only the slopes.
public struct TreemapLayout: Sendable {
    public let width: Int, height: Int
    public let nodeIDs: [Int32]
    public let x: [Int32], y: [Int32], widths: [Int32], heights: [Int32]
    public let surfaceX2: [Float], surfaceX: [Float], surfaceY2: [Float], surfaceY: [Float]
    public let colorIndex: [Int32]
    fileprivate let pixelOwner: [Int32]
    fileprivate let folderEdge: [UInt8]
    private let tileOwner: [Int32]
    private let tileWidth: Int
    private let nodeBox: [Int32]

    public var boxCount: Int { nodeIDs.count }
    public func rect(of node: Int32) -> PixelRect? {
        let n = Int(node)
        guard n >= 0, n < nodeBox.count, nodeBox[n] >= 0 else { return nil }
        let i = Int(nodeBox[n])
        return PixelRect(x: Int(x[i]), y: Int(y[i]), width: Int(widths[i]), height: Int(heights[i]))
    }
    public func hitTest(x px: Int, y py: Int) -> Int32? {
        guard px >= 0, py >= 0, px < width, py < height else { return nil }
        let tile = tileOwner[(py / 8) * tileWidth + px / 8]
        let i = Int(tile >= 0 ? tile : pixelOwner[py * width + px])
        return i >= 0 ? nodeIDs[i] : nil
    }

    fileprivate init(width: Int, height: Int, nodeIDs: [Int32], x: [Int32], y: [Int32], widths: [Int32], heights: [Int32], surfaceX2: [Float], surfaceX: [Float], surfaceY2: [Float], surfaceY: [Float], colorIndex: [Int32], pixelOwner: [Int32], folderEdge: [UInt8], nodeBox: [Int32]) {
        self.width = width; self.height = height; self.nodeIDs = nodeIDs
        self.x = x; self.y = y; self.widths = widths; self.heights = heights
        self.surfaceX2 = surfaceX2; self.surfaceX = surfaceX
        self.surfaceY2 = surfaceY2; self.surfaceY = surfaceY
        self.colorIndex = colorIndex; self.pixelOwner = pixelOwner; self.folderEdge = folderEdge; self.nodeBox = nodeBox
        tileWidth = (width + 7) / 8
        var tiles = [Int32](repeating: -1, count: tileWidth * ((height + 7) / 8))
        if width > 0 && height > 0 {
            for ty in 0..<((height + 7) / 8) {
                for tx in 0..<tileWidth {
                    let first = pixelOwner[(ty * 8) * width + tx * 8]
                    var same = true
                    for py in (ty * 8)..<min(height, ty * 8 + 8) {
                        for px in (tx * 8)..<min(width, tx * 8 + 8) where pixelOwner[py * width + px] != first { same = false }
                    }
                    if same { tiles[ty * tileWidth + tx] = first }
                }
            }
        }
        tileOwner = tiles
    }
}

private struct Surface { var x2: Float = 0, x: Float = 0, y2: Float = 0, y: Float = 0 }
private struct Region { var x: Int, y: Int, w: Int, h: Int }
private final class PixelWriter: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>
    init(_ pointer: UnsafeMutablePointer<UInt8>) { self.pointer = pointer }
}
private final class RenderCancellation: @unchecked Sendable {
    let task: UnsafeCurrentTask?
    init() { task = withUnsafeCurrentTask { $0 } }
    var isCancelled: Bool { task?.isCancelled == true }
}

public enum Treemap {
    public static func layout(tree: FileTree, rootNode: Int32, widthPx: Int, heightPx: Int, params: TreemapParams = TreemapParams()) -> TreemapLayout {
        let w = max(0, widthPx), h = max(0, heightPx)
        if Task<Never, Never>.isCancelled {
            return TreemapLayout(width: 0, height: 0, nodeIDs: [], x: [], y: [], widths: [], heights: [],
                                 surfaceX2: [], surfaceX: [], surfaceY2: [], surfaceY: [], colorIndex: [],
                                 pixelOwner: [], folderEdge: [], nodeBox: [])
        }
        var ids: [Int32] = [], xx: [Int32] = [], yy: [Int32] = [], ww: [Int32] = [], hh: [Int32] = []
        var ax: [Float] = [], bx: [Float] = [], ay: [Float] = [], by: [Float] = [], colors: [Int32] = []
        var owner = [Int32](repeating: -1, count: w * h)
        var edges = [UInt8](repeating: 0, count: w * h)
        var nodeBox = [Int32](repeating: -1, count: tree.parent.count)
        guard rootNode >= 0, Int(rootNode) < tree.parent.count, tree.countedSize[Int(rootNode)] > 0, w > 0, h > 0 else {
            return TreemapLayout(width: w, height: h, nodeIDs: ids, x: xx, y: yy, widths: ww, heights: hh, surfaceX2: ax, surfaceX: bx, surfaceY2: ay, surfaceY: by, colorIndex: colors, pixelOwner: owner, folderEdge: edges, nodeBox: nodeBox)
        }
        func add(_ node: Int32, _ r: Region, _ s: Surface, _ terminal: Bool) {
            guard r.w > 0, r.h > 0 else { return }
            let i = Int32(ids.count)
            ids.append(node); xx.append(Int32(r.x)); yy.append(Int32(r.y)); ww.append(Int32(r.w)); hh.append(Int32(r.h))
            ax.append(s.x2); bx.append(s.x); ay.append(s.y2); by.append(s.y)
            colors.append(tree.largestFileType[Int(node)]); nodeBox[Int(node)] = i
            if terminal {
                for py in r.y..<(r.y + r.h) {
                    let row = py * w
                    for px in r.x..<(r.x + r.w) { owner[row + px] = i }
                }
            }
        }
        func ridge(_ s: Surface, _ r: Region, _ height: Float) -> Surface {
            var z = s
            if r.w > 0 { let k = 4 * height / Float(r.w); z.x2 -= k; z.x += k * Float(2 * r.x + r.w) }
            if r.h > 0 { let k = 4 * height / Float(r.h); z.y2 -= k; z.y += k * Float(2 * r.y + r.h) }
            return z
        }
        func worst(_ sum: Double, _ lo: Double, _ hi: Double, _ short: Double) -> Double {
            guard lo > 0, short > 0 else { return .infinity }
            let sq = sum * sum
            return max(short * short * hi / sq, sq / (short * short * lo))
        }
        func visit(_ node: Int32, _ r: Region, _ surface: Surface, _ level: Int) {
            if Task<Never, Never>.isCancelled { return }
            let dir = tree.flags[Int(node)].contains(.isDir)
            let terminal = !dir || r.w <= 2 || r.h <= 2 || tree.childCount[Int(node)] == 0
            add(node, r, surface, terminal)
            if terminal { return }
            let begin = Int(tree.firstChild[Int(node)]), count = Int(tree.childCount[Int(node)])
            var positiveCount = 0
            var total: Int64 = 0
            for j in begin..<(begin + count) {
                let size = tree.countedSize[Int(tree.children[j])]
                if size > 0 { positiveCount += 1; total += size }
            }
            guard positiveCount > 0 else { return }
            var remaining = r, used: Int64 = 0, start = 0
            let nextHeight = params.ridgeHeight * pow(params.ridgeFactor, Float(level))
            while start < positiveCount && remaining.w > 0 && remaining.h > 0 {
                if Task<Never, Never>.isCancelled { return }
                let horizontal = remaining.w < remaining.h
                let short = Double(min(remaining.w, remaining.h))
                let scale = Double(remaining.w) * Double(remaining.h) / Double(max(1, total - Int64(used)))
                var end = start + 1
                let firstSize = tree.countedSize[Int(tree.children[begin + start])]
                var rowSum = firstSize
                var scaledSum = Double(firstSize) * scale
                var smallest = scaledSum
                let largest = scaledSum
                var aspect = worst(scaledSum, smallest, largest, short)
                while end < positiveCount {
                    let nextSize = tree.countedSize[Int(tree.children[begin + end])]
                    let nextScaled = Double(nextSize) * scale
                    let nextAspect = worst(scaledSum + nextScaled, min(smallest, nextScaled), largest, short)
                    if nextAspect > aspect { break }
                    rowSum += nextSize; scaledSum += nextScaled; smallest = min(smallest, nextScaled); aspect = nextAspect; end += 1
                }
                let lastRow = end == positiveCount
                let thickness = lastRow ? (horizontal ? remaining.h : remaining.w) : max(0, min(horizontal ? remaining.h : remaining.w, Int((Double(rowSum) * scale / Double(horizontal ? remaining.w : remaining.h)).rounded())))
                let span = horizontal ? remaining.w : remaining.h
                var cursor = 0, rowUsed: Int64 = 0
                for j in start..<end {
                    let child = tree.children[begin + j]
                    rowUsed += tree.countedSize[Int(child)]
                    let edge = j == end - 1 ? span : Int((Double(rowUsed) / Double(rowSum) * Double(span)).rounded())
                    let length = max(0, edge - cursor)
                    let box = horizontal ? Region(x: remaining.x + cursor, y: remaining.y, w: length, h: thickness) : Region(x: remaining.x, y: remaining.y + cursor, w: thickness, h: length)
                    if box.w > 0 && box.h > 0 { visit(child, box, ridge(surface, box, nextHeight), level + 1) }
                    cursor = edge
                }
                if horizontal { remaining.y += thickness; remaining.h -= thickness }
                else { remaining.x += thickness; remaining.w -= thickness }
                used += rowSum; start = end
            }
        }
        visit(rootNode, Region(x: 0, y: 0, w: w, h: h), Surface(), 0)
        if Task<Never, Never>.isCancelled {
            return TreemapLayout(width: 0, height: 0, nodeIDs: [], x: [], y: [], widths: [], heights: [],
                                 surfaceX2: [], surfaceX: [], surfaceY2: [], surfaceY: [], colorIndex: [],
                                 pixelOwner: [], folderEdge: [], nodeBox: [])
        }
        for i in ids.indices where ids[i] != rootNode && tree.flags[Int(ids[i])].contains(.isDir) {
            if Task<Never, Never>.isCancelled { break }
            let left = Int(xx[i]), top = Int(yy[i]), right = left + Int(ww[i]) - 1, bottom = top + Int(hh[i]) - 1
            if right <= left || bottom <= top { continue }
            for px in left...right { edges[top * w + px] = 1; edges[bottom * w + px] = 1 }
            for py in top...bottom { edges[py * w + left] = 1; edges[py * w + right] = 1 }
        }
        return TreemapLayout(width: w, height: h, nodeIDs: ids, x: xx, y: yy, widths: ww, heights: hh, surfaceX2: ax, surfaceX: bx, surfaceY2: ay, surfaceY: by, colorIndex: colors, pixelOwner: owner, folderEdge: edges, nodeBox: nodeBox)
    }

    public static func shade(_ layout: TreemapLayout, into rgba: inout [UInt8], params: TreemapParams = TreemapParams(), highlightExtension: Int32? = nil) {
        let width = layout.width, height = layout.height
        if Task<Never, Never>.isCancelled { rgba = []; return }
        guard width > 0 && height > 0 else { rgba = []; return }
        if rgba.count != width * height * 4 { rgba = [UInt8](repeating: 0, count: width * height * 4) }
        let cancellation = RenderCancellation()
        rgba.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let writer = PixelWriter(base)
            let bands = min(max(1, ProcessInfo.processInfo.activeProcessorCount), height)
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                if cancellation.isCancelled { return }
                let y0 = band * height / bands, y1 = (band + 1) * height / bands
                for py in y0..<y1 {
                    if cancellation.isCancelled { return }
                    for px in 0..<width {
                        let at = py * width + px, out = at * 4
                        let i = Int(layout.pixelOwner[at])
                        if i < 0 { writer.pointer[out] = params.backgroundColor.r; writer.pointer[out+1] = params.backgroundColor.g; writer.pointer[out+2] = params.backgroundColor.b; writer.pointer[out+3] = 255; continue }
                        let type = layout.colorIndex[i]
                        let color = type >= 0 && Int(type) < params.palette.count ? params.palette[Int(type)] : params.otherColor
                        let nx = -(2 * layout.surfaceX2[i] * (Float(px) + 0.5) + layout.surfaceX[i])
                        let ny = -(2 * layout.surfaceY2[i] * (Float(py) + 0.5) + layout.surfaceY[i])
                        let light = max(0, (nx * params.light.0 + ny * params.light.1 + params.light.2) / sqrt(nx * nx + ny * ny + 1))
                        let dim: Float = highlightExtension == nil || highlightExtension == type ? 1 : 0.22
                        let edge = layout.folderEdge[at] == 0 ? Float(1) : params.folderEdgeFactor
                        let value = min(1.3, max(0, params.ambient + params.diffuse * light)) * dim * edge
                        writer.pointer[out] = UInt8(min(255, Float(color.r) * value))
                        writer.pointer[out+1] = UInt8(min(255, Float(color.g) * value))
                        writer.pointer[out+2] = UInt8(min(255, Float(color.b) * value))
                        writer.pointer[out+3] = 255
                    }
                }
            }
        }
        if Task<Never, Never>.isCancelled { rgba = [] }
    }
}
