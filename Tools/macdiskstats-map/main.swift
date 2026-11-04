import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import DiskCore

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fputs("usage: macdiskstats-map <path> <out.png> [--width W --height H]\n", stderr); exit(2) }
func dimension(_ flag: String, default value: Int) -> Int {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { return value }
    return n
}
let width = dimension("--width", default: 2360), height = dimension("--height", default: 1200)
let start = DispatchTime.now().uptimeNanoseconds
do {
    let tree = try await Scanner.scan(root: args[0])
    let afterScan = DispatchTime.now().uptimeNanoseconds
    let map = Treemap.layout(tree: tree, rootNode: 0, widthPx: width, heightPx: height)
    let afterLayout = DispatchTime.now().uptimeNanoseconds
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    Treemap.shade(map, into: &rgba)
    let afterShade = DispatchTime.now().uptimeNanoseconds
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let output = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fputs("PNG setup failed\n", stderr); exit(1) }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fputs("PNG write failed\n", stderr); exit(1) }
    func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000 }
    print(String(format: "scan %.3f ms, layout %.3f ms, shade %.3f ms, boxes %d", ms(start, afterScan), ms(afterScan, afterLayout), ms(afterLayout, afterShade), map.boxCount))
} catch { fputs("map failed: \(error)\n", stderr); exit(1) }
