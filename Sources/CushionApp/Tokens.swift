import AppKit
import DiskCore

@MainActor enum Tokens {
    static let rowHeight: CGFloat = 22
    static let headerHeight: CGFloat = 26
    static let statusHeight: CGFloat = 27
    static let bannerHeight: CGFloat = 27
    static let topFraction: CGFloat = 0.38
    static let treeFraction: CGFloat = 0.58
    static let splitThickness: CGFloat = 1
    static let splitHitSize: CGFloat = 8
    static let inset: CGFloat = 10
    static let cellInset: CGFloat = 7
    static let swatchSize: CGFloat = 11
    static let mapFrameWidth: CGFloat = 2
    static let mapFrameInset: CGFloat = 1
    static let startSpacing: CGFloat = 14
    static let startRowHeight: CGFloat = 42
    static let startWidth: CGFloat = 620
    static let bannerTextFraction: CGFloat = 0.65
    static let bannerActionWidth: CGFloat = 126
    static let bannerCloseWidth: CGFloat = 42
    static let treeColumns: [(String, CGFloat)] = [("Name", 330), ("Size", 100), ("Frees", 100), ("%", 65)]
    static let typeColumns: [(String, CGFloat)] = [("Type", 190), ("Size", 100), ("%", 65)]
    static let largestColumns: [(String, CGFloat)] = [("Path", 480), ("Size", 120)]
    static let startTopInset: CGFloat = 50
    static let paneMinRows: Int = 5
    static let statusSeparator = " · "
    static let resizeDelay: TimeInterval = 0.14
    static let scanTick: TimeInterval = 0.25
    static let windowSize = NSSize(width: 1200, height: 800)
    static let snapshotSize = NSSize(width: 1600, height: 1000)
    static let minTopHeight: CGFloat = 150
    static let minMapHeight: CGFloat = 190
    static let minTreeWidth: CGFloat = 260
    static let minTypesWidth: CGFloat = 200

    static let bodyFont = NSFont.systemFont(ofSize: 12.5)
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    static let headerFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let statusFont = NSFont.systemFont(ofSize: 11.5)
    static let startTitleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let startDetailFont = NSFont.systemFont(ofSize: 13)
    static let unreadableFont = NSFont.systemFont(ofSize: 12.5, weight: .regular).withTraits(.italicFontMask)

    static func background(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white }
    static func secondary(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1) }
    static func mapBackground(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedWhite: 0.11, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1) }
    static func text(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedWhite: 0.91, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1) }
    static func muted(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedWhite: 0.70, alpha: 1) : NSColor(calibratedWhite: 0.39, alpha: 1) }
    static func separator(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedWhite: 0.28, alpha: 1) : NSColor(calibratedWhite: 0.88, alpha: 1) }
    static func selection(_ dark: Bool) -> NSColor { dark ? NSColor(calibratedRed: 0.22, green: 0.45, blue: 0.78, alpha: 1) : NSColor(calibratedRed: 0.04, green: 0.39, blue: 0.85, alpha: 1) }
    static func frame(_ dark: Bool) -> NSColor { dark ? .white : .white }
    static func frameShadow(_ dark: Bool) -> NSColor { dark ? .black : NSColor(calibratedWhite: 0.0, alpha: 0.65) }

    private static let lightColors: [MapColor] = [
        MapColor(82, 140, 216), MapColor(221, 115, 92), MapColor(92, 169, 110),
        MapColor(211, 165, 69), MapColor(151, 110, 191), MapColor(61, 161, 170),
        MapColor(203, 102, 153), MapColor(129, 150, 67), MapColor(104, 122, 191),
        MapColor(191, 127, 78), MapColor(80, 168, 204), MapColor(176, 101, 106)
    ]
    private static let darkColors: [MapColor] = [
        MapColor(93, 151, 222), MapColor(218, 120, 100), MapColor(99, 180, 120),
        MapColor(215, 170, 79), MapColor(166, 125, 208), MapColor(76, 177, 184),
        MapColor(214, 116, 167), MapColor(147, 166, 78), MapColor(114, 133, 206),
        MapColor(205, 141, 92), MapColor(89, 184, 216), MapColor(188, 112, 118)
    ]
    static func color(for index: Int, dark: Bool) -> NSColor {
        let colors = dark ? darkColors : lightColors
        guard index >= 0 && index < colors.count else { return dark ? NSColor(calibratedWhite: 0.55, alpha: 1) : NSColor(calibratedWhite: 0.69, alpha: 1) }
        let c = colors[index]
        return NSColor(calibratedRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }
    static func mapParams(dark: Bool) -> TreemapParams {
        var p = TreemapParams()
        p.palette = dark ? darkColors : lightColors
        p.otherColor = dark ? MapColor(130, 135, 143) : MapColor(175, 177, 182)
        p.backgroundColor = dark ? MapColor(28, 28, 31) : MapColor(242, 242, 244)
        p.ridgeHeight = 0.68
        p.ridgeFactor = 0.83
        p.ambient = dark ? 0.57 : 0.68
        p.diffuse = 0.40
        return p
    }
}

extension NSFont {
    fileprivate func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}
