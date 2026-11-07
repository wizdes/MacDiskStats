import AppKit

// Writes the app icon set from the drawn master picture (Resources/AppIcon-1024.png).
// Usage: make-icon [OUTPUT.iconset] [MASTER.png]
let args = Array(CommandLine.arguments.dropFirst())
let output = args.first ?? "build/AppIcon.iconset"
let masterPath = args.count > 1 ? args[1] : "Resources/AppIcon-1024.png"
guard let master = NSImage(contentsOfFile: masterPath),
      let source = master.representations.first, source.pixelsWide == 1024, source.pixelsHigh == 1024 else {
    FileHandle.standardError.write(Data("make-icon: \(masterPath) is missing or not 1024 x 1024 pixels\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let entries: [(String, Int)] = [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)]
for (name, size) in entries {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
print("icon: \(entries.count) PNGs from \(masterPath)")
