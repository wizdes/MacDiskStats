import AppKit
import DiskCore
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
let fm = FileManager.default
let fixture = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent(".mds-icon-\(UUID().uuidString)")
try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture) }
let sizes = [13, 11, 9, 8, 7, 6, 5, 4, 3, 3, 2, 2]
for (index, count) in sizes.enumerated() {
    let bytes = [UInt8](repeating: UInt8(index + 24), count: count * 4096)
    try Data(bytes).write(to: fixture.appendingPathComponent(String(format: "%02d.%@", index, ["mov", "swift", "jpg", "zip", "pdf", "mp3", "png", "app", "heic", "txt", "dmg", "json"][index])))
}
let tree = try await Scanner.scan(root: fixture.path)
var params = TreemapParams()
params.palette = [MapColor(82, 140, 216), MapColor(221, 115, 92), MapColor(92, 169, 110), MapColor(211, 165, 69), MapColor(151, 110, 191), MapColor(61, 161, 170), MapColor(203, 102, 153), MapColor(129, 150, 67), MapColor(104, 122, 191), MapColor(191, 127, 78), MapColor(80, 168, 204), MapColor(176, 101, 106)]
let side = 840
let layout = Treemap.layout(tree: tree, rootNode: 0, widthPx: side, heightPx: side, params: params)
var pixels = [UInt8](repeating: 0, count: side * side * 4)
Treemap.shade(layout, into: &pixels, params: params)
guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let map = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { fatalError("cannot render map") }
let full = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: full)
let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.20, alpha: 1).setFill()
NSBezierPath(roundedRect: bounds.insetBy(dx: 28, dy: 28), xRadius: 218, yRadius: 218).fill()
let inset = NSRect(x: 92, y: 92, width: 840, height: 840)
NSBezierPath(roundedRect: inset, xRadius: 142, yRadius: 142).addClip()
NSGraphicsContext.current!.cgContext.draw(map, in: inset)
NSGraphicsContext.restoreGraphicsState()
try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
let entries: [(String, Int)] = [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)]
for (name, size) in entries {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSImage(cgImage: full.cgImage!, size: bounds.size).draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: bounds, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
print("icon: \(layout.boxCount) boxes, \(entries.count) PNGs")
