import AppKit
import DiskCore
import QuickLookUI
import UniformTypeIdentifiers

@MainActor private final class AppearanceView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

private struct MapRenderRequest: Sendable {
    let tree: FileTree
    let root: Int32
    let width: Int
    let height: Int
    let params: TreemapParams
    let highlight: Int32?
    let existing: TreemapLayout?
    let version: Int
}

@MainActor
final class MacDiskStatsApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var window: NSWindow!
    private var content: NSView!
    private var startView: NSView?
    private var scanView: NSView?
    private var mapView: MapView!
    private var outline: NSOutlineView!
    private var types: NSTableView!
    private var status: NSTextField!
    private var pathBar: NSPathControl!
    private var pathItemNodes: [ObjectIdentifier: Int32] = [:]
    private var fullStatusSummary = ""
    private var summary: NSTextField!
    private var estimateNote: NSTextField!
    private var progress: StatusProgressView!
    private var startSheet: NSWindow?
    private var volumePaths: [String] = []
    private var selectedVolume = 0
    private var snapshotStartPath: String?
    private var snapshotMidPath: String?
    private var snapshotMidRow = false
    private var banner: NSView?
    private var tree: FileTree?
    private var liveScan: LiveScan?
    private var liveRows: [Int32: [LiveNode]] = [:]
    private var expandedIDs = Set<Int32>()
    private var liveTypes: [ExtensionTotal] = []
    private var liveFrame: LiveSnapshot?
    private var liveTickTask: Task<Void, Never>?
    private var liveStarted = Date()
    private var firstLiveRows: TimeInterval?
    private var firstLiveMap: TimeInterval?
    private var lastLiveSort = Date.distantPast
    private var lastLiveMap = Date.distantPast
    private var snapshotAtSeconds: TimeInterval?
    #if DEBUG
    private var measureLive = false
    private var stallTimer: DispatchSourceTimer?
    private var expectedTimerFire = Date()
    private var worstStallMs = 0.0
    private var worstTickMs = 0.0
    private var worstLiveApplyMs = 0.0
    private var worstLiveOutlineMs = 0.0
    private var phaseOneSeconds = 0.0
    #endif
    private var rootPath: String?
    private var zoomNode: Int32 = 0
    private var selectedNode: Int32?
    private var hoveredNode: Int32?
    private var highlightedType: Int32?
    private var scanTask: Task<Void, Never>?
    private var mapTask: Task<Void, Never>?
    private var renderWork: Task<(TreemapLayout, [UInt8]), Never>?
    private var pendingRender: MapRenderRequest?
    private var resizeTask: Task<Void, Never>?
    private var renderVersion = 0
    private var scanVersion = 0
    private var renderedRoot: Int32 = -1
    private var selecting = false
    private var topWindow: NSWindow?
    private var topTable: NSTableView?
    private var topIDs: [Int32] = []
    private var isScanning = false
    private var checkingSharedFiles = false
    private var bannerDismissed = false
    private var pendingSelect: String?
    private var revealFiles: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    private var snapshotPath: String?
    private var snapshotAppearance: String?
    private var snapshotMinWidth = false
    private var volumeFreeBytes: Int64 = 0
    // The light-mode blue folder, drawn once, so dark mode shows the same icon.
    private let folderIcon: NSImage = {
        let source = NSWorkspace.shared.icon(for: .folder)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return source }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
            NSGraphicsContext.restoreGraphicsState()
        }
        rep.size = NSSize(width: 32, height: 32)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }()
    private let fileIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    #if DEBUG
    private var measurePending = false
    private var e2eScript: String?
    private var e2eCancelOnLive = false
    private var e2eCancelledLive = false
    private var e2eRefreshAfterCapture: (() -> Void)?
    private var e2ePhaseTwoClick: (() -> Void)?
    #endif
    private var dark: Bool { window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.startSheet != nil { self?.closeStartSheet(); return nil }
            if self?.startSheet != nil, event.keyCode == 125 || event.keyCode == 126 { self?.moveVolumeSelection(event.keyCode == 125 ? 1 : -1); return nil }
            if event.keyCode == 53, self?.isScanning == true, self?.window.attachedSheet == nil { self?.cancelScan(); return nil }
            if event.modifierFlags.contains(.command) && event.keyCode == 126 { self?.zoomOut(); return nil }
            if event.modifierFlags.contains(.command) && event.keyCode == 36 { self?.zoomIn(); return nil }
            if event.keyCode == 49 && !event.modifierFlags.contains(.command) && self?.selectedNode != nil { self?.quickLook(); return nil }
            return event
        }
        let appearanceView = AppearanceView(frame: NSRect(origin: .zero, size: Tokens.windowSize))
        appearanceView.onAppearanceChange = { [weak self] in self?.refreshAppearance() }
        content = appearanceView
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Tokens.windowSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MacDiskStats"
        window.minSize = NSSize(width: Tokens.minWindowWidth, height: Tokens.minTopHeight + Tokens.minMapHeight + Tokens.statusHeight)
        window.center()
        window.delegate = self
        window.contentView = content
        if let snapshotAppearance { window.appearance = NSAppearance(named: snapshotAppearance == "dark" ? .darkAqua : .aqua) }
        buildScanView()
        #if DEBUG
        if snapshotMinWidth { window.setContentSize(NSSize(width: Tokens.minWindowWidth, height: Tokens.windowSize.height)) }
        #endif
        status.stringValue = "No scan yet"
        progress.isHidden = true
        #if DEBUG
        if let e2eScript {
            Task { await runE2E(e2eScript) }
        }
        #endif
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        if let snapshotMidPath {
            self.snapshotMidPath = nil
            snapshotMidRow = true
            outline.reloadData()
            progress.isHidden = false; progress.isIndeterminate = false; progress.doubleValue = 47
            status.stringValue = "Scanning… 47%"
            DispatchQueue.main.async { DebugSnapshot.capture(window: self.window, path: snapshotMidPath) }
        } else if rootPath == nil || e2eScript != nil { showStart() }
        #else
        if rootPath == nil { showStart() }
        #endif
        if let rootPath {
            #if DEBUG
            if e2eScript == nil { startScan(rootPath) }
            #else
            startScan(rootPath)
            #endif
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowDidResize(_ notification: Notification) { layoutStatusLine(); scheduleMapRender() }
    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleMapRender() }

    private func parseArguments() {
        let args = CommandLine.arguments
        for i in args.indices {
            #if DEBUG
            if args[i] == "--snapshot-mid-scan", i + 1 < args.count { snapshotMidPath = args[i + 1]; continue }
            if args[i] == "--snapshot-start", i + 1 < args.count { snapshotStartPath = args[i + 1]; continue }
            if args[i] == "--snapshot-min-width" { snapshotMinWidth = true; continue }
            if args[i] == "--measure" { measurePending = true; continue }
            if args[i] == "--measure-live" { measureLive = true; continue }
            if args[i] == "--e2e", i + 1 < args.count { e2eScript = args[i + 1]; continue }
            #endif
            guard i + 1 < args.count else { continue }
            switch args[i] {
            case "--scan": rootPath = args[i + 1]
            case "--select": pendingSelect = args[i + 1]
            case "--snapshot": snapshotPath = args[i + 1]
            case "--appearance": snapshotAppearance = args[i + 1]
            case "--snapshot-at-seconds": snapshotAtSeconds = TimeInterval(args[i + 1])
            default: break
            }
        }
    }

    private func buildMenu() {
        let bar = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(title: "MacDiskStats")
        appMenu.addItem(withTitle: "Quit MacDiskStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; bar.addItem(app)
        let file = NSMenuItem(); let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Scan", action: #selector(showStart), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Rescan", action: #selector(rescan), keyEquivalent: "R").target = self
        fileMenu.addItem(withTitle: "Rescan Folder", action: #selector(rescanFolder), keyEquivalent: "") .target = self
        fileMenu.addItem(withTitle: "Cancel Scan", action: #selector(cancelScan), keyEquivalent: ".").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "r").target = self
        fileMenu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "c").target = self
        fileMenu.addItem(withTitle: "Quick Look", action: #selector(quickLook), keyEquivalent: " ").target = self
        file.submenu = fileMenu; bar.addItem(file)
        let view = NSMenuItem(); let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "\r").target = self
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "\u{F700}").target = self
        viewMenu.addItem(withTitle: "Zoom to Top", action: #selector(zoomTop), keyEquivalent: "") .target = self
        viewMenu.addItem(withTitle: "100 Largest Files", action: #selector(showLargest), keyEquivalent: "l").target = self
        view.submenu = viewMenu; bar.addItem(view)
        NSApp.mainMenu = bar
    }

    @objc private func showStart() {
        guard startSheet == nil, window.attachedSheet == nil else { return }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey], options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.sorted { a, b in a.path == "/" ? true : (b.path == "/" ? false : a.path < b.path) }
        let sheetSize = NSSize(width: Tokens.sheetSize.width, height: Tokens.sheetHeight(rows: volumes.count))
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: sheetSize), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = ""
        sheet.appearance = window.appearance
        let host = NSView(frame: NSRect(origin: .zero, size: sheetSize))
        host.wantsLayer = true; host.layer?.backgroundColor = Tokens.secondary(dark).cgColor
        sheet.contentView = host
        let title = label("Scan a disk", font: Tokens.startTitleFont, color: Tokens.text(dark))
        title.frame = NSRect(x: Tokens.sheetPadding, y: sheetSize.height - Tokens.sheetTitleTop, width: 400, height: 30); host.addSubview(title)
        let note = label("MacDiskStats reads names and sizes only. It never changes your files.", font: Tokens.statusFont, color: Tokens.muted(dark))
        note.frame = NSRect(x: Tokens.sheetPadding, y: sheetSize.height - Tokens.sheetNoteTop, width: 410, height: 19); host.addSubview(note)
        let listHeight = CGFloat(max(1, min(volumes.count, Tokens.sheetVisibleRows))) * Tokens.sheetRowHeight
        let list = NSScrollView(frame: NSRect(x: Tokens.sheetPadding, y: 69, width: sheetSize.width - 2 * Tokens.sheetPadding, height: listHeight))
        list.hasVerticalScroller = volumes.count > Tokens.sheetVisibleRows; list.autohidesScrollers = true; list.drawsBackground = false
        volumePaths = volumes.map(\.path); selectedVolume = 0
        let document = NSView(frame: NSRect(x: 0, y: 0, width: list.bounds.width, height: max(listHeight, CGFloat(volumes.count) * Tokens.sheetRowHeight)))
        for (index, url) in volumes.enumerated() {
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let name = values?.volumeName ?? url.lastPathComponent
            let total = max(0, Int64(values?.volumeTotalCapacity ?? 0))
            let used = max(0, total - Int64(values?.volumeAvailableCapacity ?? 0))
            let row = NSButton(title: "", target: self, action: #selector(selectVolume(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(url.path); row.tag = index
            row.isBordered = false; row.frame = NSRect(x: 0, y: document.bounds.height - CGFloat(index + 1) * Tokens.sheetRowHeight, width: document.bounds.width, height: Tokens.sheetRowHeight)
            row.wantsLayer = true
            row.setAccessibilityLabel("\(name), \(format(used)) used of \(format(total)) total")
            row.setAccessibilityRole(.button)
            let icon = NSImageView(frame: NSRect(x: 8, y: 8, width: Tokens.sheetIconSize, height: Tokens.sheetIconSize))
            icon.image = volumeIcon(for: url.path, scale: sheet.backingScaleFactor); row.addSubview(icon)
            let nameLabel = label(name, font: Tokens.bodyFont, color: Tokens.text(dark))
            nameLabel.frame = NSRect(x: 46, y: 4, width: 190, height: 17); row.addSubview(nameLabel)
            let sizeLabel = label(total > 0 ? "\(format(used)) of \(format(total))" : "Size unavailable", font: Tokens.statusFont, color: Tokens.muted(dark))
            sizeLabel.alignment = .right; sizeLabel.frame = NSRect(x: 230, y: 4, width: 168, height: 17); row.addSubview(sizeLabel)
            let bar = NSView(frame: NSRect(x: 46, y: 34, width: Tokens.sheetBarWidth, height: Tokens.sheetBarHeight))
            bar.wantsLayer = true; bar.layer?.backgroundColor = Tokens.progressTrack(dark).cgColor; bar.layer?.cornerRadius = Tokens.sheetBarHeight / 2; row.addSubview(bar)
            let fill = NSView(frame: NSRect(x: 0, y: 0, width: Tokens.sheetBarWidth * CGFloat(Double(used) / Double(max(1, total))), height: Tokens.sheetBarHeight))
            fill.wantsLayer = true; fill.layer?.backgroundColor = Tokens.progressFill(dark).cgColor; fill.layer?.cornerRadius = Tokens.sheetBarHeight / 2; bar.addSubview(fill)
            document.addSubview(row)
        }
        list.documentView = document; host.addSubview(list); startView = document
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded; choose.font = Tokens.bodyFont
        choose.frame = NSRect(x: Tokens.sheetPadding, y: 20, width: 135, height: Tokens.sheetButtonHeight); host.addSubview(choose)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeStartSheet))
        cancel.bezelStyle = .rounded; cancel.frame = NSRect(x: 257, y: 20, width: Tokens.sheetButtonWidth, height: Tokens.sheetButtonHeight); host.addSubview(cancel)
        let scan = NSButton(title: "Scan", target: self, action: #selector(scanSelectedVolume))
        scan.bezelStyle = .rounded; scan.keyEquivalent = "\r"; scan.frame = NSRect(x: 350, y: 20, width: Tokens.sheetButtonWidth, height: Tokens.sheetButtonHeight); host.addSubview(scan)
        startSheet = sheet; updateVolumeSelection()
        window.beginSheet(sheet)
        sheet.defaultButtonCell = scan.cell as? NSButtonCell
        sheet.makeFirstResponder(volumes.isEmpty ? choose : document.subviews.first)
        #if DEBUG
        if let snapshotStartPath {
            self.snapshotStartPath = nil
            DispatchQueue.main.async { DebugSnapshot.capture(window: self.window, path: snapshotStartPath, sheet: sheet) }
        }
        #endif
    }
    private func updateVolumeSelection() {
        for row in startView?.subviews.compactMap({ $0 as? NSButton }) ?? [] {
            row.layer?.backgroundColor = row.tag == selectedVolume ? Tokens.sheetSelection(dark).cgColor : NSColor.clear.cgColor
            row.layer?.cornerRadius = 6
        }
    }
    private func moveVolumeSelection(_ delta: Int) {
        guard !volumePaths.isEmpty else { return }
        selectedVolume = min(max(0, selectedVolume + delta), volumePaths.count - 1)
        updateVolumeSelection()
        if let row = startView?.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == selectedVolume }) {
            row.scrollToVisible(row.bounds)
            startSheet?.makeFirstResponder(row)
        }
    }
    @objc private func selectVolume(_ sender: NSButton) {
        selectedVolume = sender.tag; updateVolumeSelection()
        if NSApp.currentEvent?.clickCount ?? 0 > 1 { scanSelectedVolume() }
    }
    @objc private func closeStartSheet() {
        guard let sheet = startSheet else { return }
        window.endSheet(sheet); sheet.orderOut(nil); startSheet = nil; startView = nil
    }
    @objc private func scanSelectedVolume() {
        guard volumePaths.indices.contains(selectedVolume) else { return }
        let path = volumePaths[selectedVolume]
        closeStartSheet(); startScan(path)
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if let sheet = startSheet { window.endSheet(sheet); sheet.orderOut(nil); startSheet = nil; startView = nil }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let path = panel.url?.path { self.startScan(path) }
            else if self.tree == nil && !self.isScanning { self.status.stringValue = "No scan yet" }
        }
    }

    private func buildScanView() {
        let buildStarted = Date()
        defer {
            #if DEBUG
            if measureLive { print(String(format: "measure live build scan view %.1f ms", Date().timeIntervalSince(buildStarted) * 1000)) }
            #endif
        }
        guard scanView == nil else { return }
        let host = NSView(frame: content.bounds); host.autoresizingMask = [.width, .height]
        content.addSubview(host); scanView = host
        let status = label("", font: Tokens.statusFont, color: Tokens.muted(dark))
        status.frame = NSRect(x: Tokens.inset, y: 0, width: host.bounds.width - Tokens.inset * 2, height: Tokens.statusHeight)
        status.autoresizingMask = [.width, .maxYMargin]; status.alignment = .center
        host.addSubview(status); self.status = status
        let map = MapView(frame: .zero); mapView = map
        map.onSelect = { [weak self] in self?.selectNode($0, fromMap: true) }
        map.onHover = { [weak self] in self?.hoveredNode = $0; self?.updateStatus() }
        map.onDoubleClick = { [weak self] in self?.selectNode($0, fromMap: true); self?.zoomIn() }
        map.onContextMenu = { [weak self] _ in self?.contextMenu() }
        map.onResize = { [weak self] in self?.scheduleMapRender() }
        let treeScroll = NSScrollView(frame: .zero); treeScroll.hasVerticalScroller = true; treeScroll.autohidesScrollers = true
        outline = ActionOutlineView(frame: .zero); outline.rowHeight = Tokens.rowHeight; outline.usesAutomaticRowHeights = false; outline.headerView = NSTableHeaderView()
        (outline as? ActionOutlineView)?.onMenu = { [weak self] node in
            self?.selectNode(node)
            return self?.contextMenu()
        }
        outline.dataSource = self; outline.delegate = self; outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (name, width) in Tokens.treeColumns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); c.title = name; c.width = width
            if name == "%" { c.minWidth = width }
            c.headerCell.font = Tokens.headerFont
            if name != "Name" { c.headerCell.alignment = .right }
            if name == "Frees" { outline.headerView?.toolTip = "At least this much space comes back if you delete this." }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.doubleAction = #selector(zoomIn)
        treeScroll.documentView = outline
        let typeScroll = NSScrollView(frame: .zero); typeScroll.hasVerticalScroller = true; typeScroll.autohidesScrollers = true
        types = NSTableView(frame: .zero); types.rowHeight = Tokens.rowHeight; types.headerView = NSTableHeaderView()
        types.dataSource = self; types.delegate = self
        types.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (name, width) in Tokens.typeColumns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); c.title = name; c.width = width
            if name == "%" { c.minWidth = width }
            c.headerCell.font = Tokens.headerFont
            if name != "Type" { c.headerCell.alignment = .right }
            types.addTableColumn(c)
        }
        typeScroll.documentView = types
        let panes = PaneLayoutView(frame: NSRect(x: 0, y: Tokens.statusHeight, width: host.bounds.width, height: host.bounds.height - Tokens.statusHeight), tree: treeScroll, types: typeScroll, map: map)
        panes.autoresizingMask = [.width, .height]
        host.addSubview(panes)
        panes.layoutSubtreeIfNeeded()
        progress = StatusProgressView(frame: NSRect(x: Tokens.inset, y: Tokens.statusBarInset, width: Tokens.statusBarWidth, height: Tokens.statusBarHeight))
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 100; progress.isIndeterminate = true; progress.startAnimation(nil)
        progress.autoresizingMask = [.maxYMargin]; host.addSubview(progress)
        status.frame.origin.x = Tokens.inset + Tokens.statusBarWidth + Tokens.inset
        status.frame.size.width = host.bounds.width - status.frame.origin.x - Tokens.inset
        let pathBar = NSPathControl(frame: .zero)
        pathBar.pathStyle = .standard
        pathBar.isEditable = false
        pathBar.unregisterDraggedTypes()
        pathBar.target = self; pathBar.action = #selector(pathItemClicked(_:))
        pathBar.isHidden = true
        host.addSubview(pathBar); self.pathBar = pathBar
        let summary = label("", font: Tokens.statusFont, color: Tokens.muted(dark))
        summary.alignment = .right; summary.isHidden = true
        host.addSubview(summary); self.summary = summary
        let estimateNote = label("Some sizes are estimates", font: Tokens.statusFont, color: Tokens.muted(dark))
        estimateNote.isHidden = true
        host.addSubview(estimateNote); self.estimateNote = estimateNote
        layoutStatusLine()
        map.dark = dark
        if snapshotPath != nil {
            window.setContentSize(Tokens.snapshotSize)
            panes.layoutSubtreeIfNeeded()
        }
        refreshAppearance()
    }

    private func startScan(_ path: String) {
        scanTask?.cancel(); renderWork?.cancel(); pendingRender = nil; renderVersion += 1; scanVersion += 1
        let version = scanVersion
        tree = nil; liveScan = nil; liveFrame = nil; liveRows = [:]; liveTypes = []; expandedIDs = []; liveTickTask?.cancel(); checkingSharedFiles = false; rootPath = path; zoomNode = 0; selectedNode = nil; hoveredNode = nil; highlightedType = nil; bannerDismissed = false; fullStatusSummary = ""
        banner?.removeFromSuperview(); banner = nil
        pathItemNodes.removeAll()
        pathBar?.isHidden = true; summary?.isHidden = true; estimateNote?.isHidden = true; status?.isHidden = false
        liveStarted = Date(); firstLiveRows = nil; firstLiveMap = nil
        #if DEBUG
        if measureLive {
            worstStallMs = 0; worstTickMs = 0; worstLiveApplyMs = 0; worstLiveOutlineMs = 0; phaseOneSeconds = 0
            stallTimer?.cancel()
            expectedTimerFire = Date().addingTimeInterval(0.01)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Date()
                self.worstStallMs = max(self.worstStallMs, max(0, now.timeIntervalSince(self.expectedTimerFire) * 1000))
                self.expectedTimerFire = now.addingTimeInterval(0.01)
            }
            stallTimer = timer; timer.resume()
        }
        #endif
        let rootURL = URL(fileURLWithPath: path)
        do {
            let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            volumeFreeBytes = Int64(values.volumeAvailableCapacity ?? -1)
        } catch {
            volumeFreeBytes = -1
            showError("Could not read free space for \(path): \(error.localizedDescription)")
        }
        outline.reloadData(); types.reloadData(); mapView.layoutData = nil; mapView.selectedNode = nil; mapView.show([], width: 0, height: 0); mapView.clearPreview()
        progress.isIndeterminate = true; progress.isHidden = false; progress.startAnimation(nil); isScanning = true
        window.title = "MacDiskStats — \(URL(fileURLWithPath: path).lastPathComponent)"
        status.stringValue = "Scanning \(path)…"
        layoutStatusLine()
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                let scanOptions = ScanOptions(workers: self.e2eScript == nil ? 16 : 1)
                #else
                let scanOptions = ScanOptions()
                #endif
                let result = try await Scanner.scan(root: path, options: scanOptions, phase1: { [weak self] snapshot in if self?.scanVersion == version { self?.publishTree(snapshot, final: false) } }, live: { [weak self] model in
                    guard let self, self.scanVersion == version else { return }
                    self.liveScan = model
                    self.updateStatus()
                    #if DEBUG
                    if self.e2eCancelOnLive {
                        self.e2eCancelOnLive = false
                        self.e2eCancelledLive = true
                        self.cancelScan()
                        return
                    }
                    #endif
                    self.liveTickTask = Task { [weak self] in
                        while let self, self.scanVersion == version, self.tree == nil, !Task.isCancelled {
                            await self.refreshLive()
                            try? await Task.sleep(for: .milliseconds(self.firstLiveRows == nil ? 2 : 250))
                        }
                    }
                }, phase2Progress: { [weak self] done, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.scanVersion == version, self.checkingSharedFiles else { return }
                        self.progress.doubleValue = 100 * Double(done) / Double(max(1, total))
                        self.updateStatus()
                        self.status.stringValue += " · \(done.formatted()) of \(total.formatted()) folders checked"
                    }
                })
                guard !Task.isCancelled, version == self.scanVersion else { return }
                self.publishTree(result, final: true)
                #if DEBUG
                if self.measureLive {
                    self.stallTimer?.cancel(); self.stallTimer = nil
                    print(String(format: "measure live rows %.1f ms map %.1f ms stall %.1f ms tick %.1f ms apply %.1f ms outline %.1f ms phase1 %.3f s phase2 %.3f s files %lld dirs %lld", (self.firstLiveRows ?? -1) * 1000, (self.firstLiveMap ?? -1) * 1000, self.worstStallMs, self.worstTickMs, self.worstLiveApplyMs, self.worstLiveOutlineMs, self.phaseOneSeconds, Date().timeIntervalSince(self.liveStarted) - self.phaseOneSeconds, result.filesSeen, result.dirsSeen))
                    fflush(stdout); NSApp.terminate(nil)
                }
                #endif
            } catch {
                if Task.isCancelled || version != self.scanVersion { return }
                #if DEBUG
                if self.measureLive {
                    print("measure live failed: \(error)")
                    print(String(format: "measure live partial rows %.1f ms map %.1f ms stall %.1f ms tick %.1f ms phase1 %.3f s", (self.firstLiveRows ?? -1) * 1000, (self.firstLiveMap ?? -1) * 1000, self.worstStallMs, self.worstTickMs, self.phaseOneSeconds))
                    fflush(stdout); NSApp.terminate(nil)
                }
                #endif
                self.finishFailedScan(error, path: path)
            }
        }
    }
    private func finishFailedScan(_ error: Error, path: String, presentAlert: Bool = true) {
        liveTickTask?.cancel(); liveTickTask = nil
        let failedLive = liveScan
        liveScan = nil; liveFrame = nil; liveRows = [:]; liveTypes = []
        if let failedLive { DispatchQueue.global(qos: .utility).async { withExtendedLifetime(failedLive) {} } }
        if tree == nil {
            selecting = true; outline.reloadData(); selecting = false
            types.reloadData(); mapView.clearPreview()
            pathBar.isHidden = true; summary.isHidden = true; status.isHidden = false; pathItemNodes.removeAll()
        }
        isScanning = false; checkingSharedFiles = false
        progress.stopAnimation(nil); progress.isHidden = true
        status.stringValue = tree == nil ? "Scan failed: \(error.localizedDescription)" : "Shared file check failed: \(error.localizedDescription)"
        if tree != nil { summary.stringValue = status.stringValue; fullStatusSummary = summary.stringValue; layoutStatusLine() }
        else { pathBar.isHidden = true; summary.isHidden = true; status.isHidden = false; pathItemNodes.removeAll(); layoutStatusLine() }
        if presentAlert { showError("Could not scan \(path): \(error.localizedDescription)") }
        makeSnapshotIfNeeded()
    }
    private func publishTree(_ result: FileTree, final: Bool) {
        let publishStarted = Date()
        defer {
            #if DEBUG
            if measureLive { print(String(format: "measure live %@ publish %.1f ms", final ? "phase2" : "phase1", Date().timeIntervalSince(publishStarted) * 1000)) }
            #endif
        }
        #if DEBUG
        if !final { phaseOneSeconds = Date().timeIntervalSince(liveStarted) }
        #endif
        let previous = tree
        let expanded = Array(expandedIDs)
        var scrollPoint: NSPoint?
        if previous != nil || liveScan != nil {
            scrollPoint = outline.enclosingScrollView?.contentView.bounds.origin
        }
        let selectedType = highlightedType.flatMap { id -> String? in
            let names = previous?.extensions ?? liveTypes
            return id >= 0 && Int(id) < names.count ? names[Int(id)].name : nil
        }
        #if DEBUG
        if measureLive { print(String(format: "measure live pre-publish capture %.1f ms", Date().timeIntervalSince(publishStarted) * 1000)) }
        #endif
        liveTickTask?.cancel()
        let finishedLive = liveScan
        liveScan = nil; liveFrame = nil; liveRows = [:]; liveTypes = []
        if let finishedLive { DispatchQueue.global(qos: .utility).async { withExtendedLifetime(finishedLive) {} } }
        #if DEBUG
        if measureLive { print(String(format: "measure live drop live handle %.1f ms", Date().timeIntervalSince(publishStarted) * 1000)) }
        #endif
        tree = result; checkingSharedFiles = !final; isScanning = !final
        if final { progress.stopAnimation(nil); progress.isHidden = true }
        else { progress.isIndeterminate = false; progress.doubleValue = 0; progress.isHidden = false }
        outline.headerView?.toolTip = final ? "At least this much space comes back if you delete this." : "Frees is still being calculated."
        #if DEBUG
        if measureLive { print(String(format: "measure live before outline %.1f ms", Date().timeIntervalSince(publishStarted) * 1000)) }
        #endif
        selecting = true
        let outlineStarted = Date()
        outline.reloadData()
        for id in expanded { outline.expandItem(NSNumber(value: id), expandChildren: false) }
        if let selectedNode {
            let row = outline.row(forItem: NSNumber(value: selectedNode))
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        if let scrollPoint { outline.enclosingScrollView?.contentView.scroll(to: scrollPoint) }
        selecting = false
        #if DEBUG
        if measureLive { print(String(format: "measure live outline reload %.1f ms", Date().timeIntervalSince(outlineStarted) * 1000)) }
        #endif
        let typesStarted = Date()
        types.reloadData()
        if let selectedType, let newIndex = result.extensions.firstIndex(where: { $0.name == selectedType }) {
            highlightedType = nil
            types.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            highlightedType = Int32(newIndex)
        }
        if let topTable {
            topIDs = result.largestFiles
            topTable.reloadData()
            if let selectedNode, let row = topIDs.firstIndex(of: selectedNode) {
                topTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        #if DEBUG
        if measureLive { print(String(format: "measure live types reload %.1f ms", Date().timeIntervalSince(typesStarted) * 1000)) }
        #endif
        let statusStarted = Date()
        updateStatus(); updateBanner()
        #if DEBUG
        if !final { e2ePhaseTwoClick?(); e2ePhaseTwoClick = nil }
        #endif
        #if DEBUG
        if measureLive { print(String(format: "measure live status and banner %.1f ms", Date().timeIntervalSince(statusStarted) * 1000)) }
        #endif
        if let pending = pendingSelect { selectPath(pending); pendingSelect = nil }
        let renderScheduledAt = Date()
        renderMap()
        #if DEBUG
        if measureLive { print(String(format: "measure live publish render scheduling %.1f ms", Date().timeIntervalSince(renderScheduledAt) * 1000)) }
        #endif
    }
    private func refreshLive() async {
        let tickStarted = Date()
        defer {
            #if DEBUG
            worstTickMs = max(worstTickMs, Date().timeIntervalSince(tickStarted) * 1000)
            #endif
        }
        guard let model = liveScan, tree == nil else { return }
        let expanded = Array(expandedIDs)
        let ids = Array(Set([Int32(0), zoomNode] + expanded + (liveRows[zoomNode] ?? []).prefix(Tokens.livePreviewLimit).filter(\.isDirectory).map(\.id)))
        let maySort = Date().timeIntervalSince(lastLiveSort) >= 1 && !((outline as? ActionOutlineView)?.pointerInside ?? false) && !((outline as? ActionOutlineView)?.acting ?? false)
        let oldRows = liveRows
        #if DEBUG
        e2eRefreshAfterCapture?()
        #endif
        let (frame, preparedRows, changed) = await Task.detached(priority: .userInitiated) { () -> (LiveSnapshot, [Int32: [LiveNode]], Bool) in
            let frame = model.snapshot(childrenOf: ids)
            var prepared: [Int32: [LiveNode]] = [:]
            var changed = false
            for id in ids {
                var rows = frame.children[id] ?? []
                if maySort { rows.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes } }
                else if let old = oldRows[id] {
                    let ranks = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id, $0.offset) })
                    rows.sort { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
                }
                if oldRows[id]?.map(\.id) != rows.map(\.id) { changed = true }
                prepared[id] = rows
            }
            return (frame, prepared, changed)
        }.value
        guard !Task.isCancelled, liveScan === model, tree == nil else { return }
        let currentSelection = selectedNode
        let currentScroll = outline.enclosingScrollView?.contentView.bounds.origin
        let applyStarted = Date()
        liveFrame = frame
        for id in ids {
            let rows = preparedRows[id] ?? []
            liveRows[id] = rows
        }
        if maySort { lastLiveSort = Date() }
        let selectedLiveType = highlightedType.flatMap { id in id >= 0 && Int(id) < liveTypes.count ? liveTypes[Int(id)].name : nil }
        liveTypes = frame.extensions
        types.reloadData()
        if let selectedLiveType, let newIndex = liveTypes.firstIndex(where: { $0.name == selectedLiveType }) {
            highlightedType = nil
            types.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            highlightedType = Int32(newIndex)
        } else if selectedLiveType != nil {
            highlightedType = nil
            types.deselectAll(nil)
        }
        let wholeVolume = rootPath == "/" || rootPath == "/System/Volumes/Data"
        if wholeVolume && frame.volumeUsedBytes > 0 {
            progress.isIndeterminate = false
            progress.doubleValue = min(100, 100 * Double(frame.countedBytes) / Double(frame.volumeUsedBytes))
            status.stringValue = "\(format(frame.countedBytes)) of \(format(frame.volumeUsedBytes)) · \(frame.filesSeen.formatted()) files"
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            status.stringValue = "\(format(frame.countedBytes)) · \(frame.filesSeen.formatted()) files"
        }
        if changed {
            let outlineStarted = Date()
            selecting = true
            outline.reloadData()
            for id in expanded { outline.expandItem(NSNumber(value: id), expandChildren: false) }
            if let currentSelection {
                let row = outline.row(forItem: NSNumber(value: currentSelection))
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            if let currentScroll { outline.enclosingScrollView?.contentView.scroll(to: currentScroll) }
            selecting = false
            #if DEBUG
            worstLiveOutlineMs = max(worstLiveOutlineMs, Date().timeIntervalSince(outlineStarted) * 1000)
            #endif
        } else {
            let visible = outline.rows(in: outline.visibleRect)
            if visible.length > 0 { outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: IndexSet(integersIn: 1..<outline.numberOfColumns)) }
        }
        if firstLiveRows == nil && outline.numberOfRows > 0 {
            firstLiveRows = Date().timeIntervalSince(liveStarted)
            #if DEBUG
            print(String(format: "live first tree row %.1f ms", firstLiveRows! * 1000))
            #endif
        }
        if Date().timeIntervalSince(lastLiveMap) >= 0.5 { showLiveMap(frame) }
        updateStatus()
        #if DEBUG
        worstLiveApplyMs = max(worstLiveApplyMs, Date().timeIntervalSince(applyStarted) * 1000)
        #endif
        if let snapshotAtSeconds, Date().timeIntervalSince(liveStarted) >= snapshotAtSeconds { makeSnapshotIfNeeded() }
    }
    private func showLiveMap(_ frame: LiveSnapshot) {
        let rows = frame.children[zoomNode] ?? []
        guard !rows.isEmpty else { mapView.clearPreview(); return }
        mapView.showPreview(rows: rows, children: frame.children, extensions: frame.extensions, mapTypes: frame.mapTypes, remainder: zoomNode == 0 && (rootPath == "/" || rootPath == "/System/Volumes/Data") ? max(0, frame.volumeUsedBytes - frame.countedBytes) : 0)
        lastLiveMap = Date()
        if firstLiveMap == nil {
            firstLiveMap = Date().timeIntervalSince(liveStarted)
            #if DEBUG
            print(String(format: "live first map %.1f ms", firstLiveMap! * 1000))
            #endif
        }
    }
    @objc private func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel(); scanVersion += 1; isScanning = false; checkingSharedFiles = false
        liveTickTask?.cancel()
        let cancelledLive = liveScan
        liveScan = nil; liveFrame = nil; liveRows = [:]; liveTypes = []
        if let cancelledLive { DispatchQueue.global(qos: .utility).async { withExtendedLifetime(cancelledLive) {} } }
        selecting = true; outline.reloadData(); selecting = false; types.reloadData(); mapView.clearPreview()
        progress.stopAnimation(nil); progress.isHidden = true
        status.stringValue = "Scan cancelled. Choose a folder to scan again."
        if tree != nil { summary.stringValue = status.stringValue; fullStatusSummary = summary.stringValue; layoutStatusLine() }
        else { pathBar.isHidden = true; summary.isHidden = true; status.isHidden = false; pathItemNodes.removeAll(); layoutStatusLine() }
    }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "MacDiskStats could not finish"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func scheduleMapRender() {
        guard tree != nil, mapView != nil else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Tokens.resizeDelay))
            guard !Task.isCancelled else { return }
            self?.renderMap()
        }
    }
    private func renderMap(shadeOnly: Bool = false) {
        let renderEnteredAt = Date()
        defer {
            #if DEBUG
            if measureLive { print(String(format: "measure live renderMap call %.1f ms", Date().timeIntervalSince(renderEnteredAt) * 1000)) }
            #endif
        }
        guard let tree, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        renderWork?.cancel(); renderVersion += 1
        let version = renderVersion
        let scale = window.backingScaleFactor
        let width = Int((mapView.bounds.width * scale).rounded()), height = Int((mapView.bounds.height * scale).rounded())
        let root = zoomNode, highlight = highlightedType, params = Tokens.mapParams(dark: dark)
        let existing = shadeOnly && renderedRoot == root && mapView.layoutData?.width == width && mapView.layoutData?.height == height ? mapView.layoutData : nil
        pendingRender = MapRenderRequest(tree: tree, root: root, width: width, height: height, params: params,
                                         highlight: highlight, existing: existing, version: version)
        guard mapTask == nil else { return }
        mapTask = Task { [weak self] in
            while let self, let request = self.pendingRender {
                self.pendingRender = nil
                let work = Task.detached(priority: .userInitiated) { () -> (TreemapLayout, [UInt8]) in
                    let layout = request.existing ?? Treemap.layout(tree: request.tree, rootNode: request.root,
                                                                     widthPx: request.width, heightPx: request.height, params: request.params)
                    guard !Task.isCancelled else { return (layout, []) }
                    var rgba: [UInt8] = []
                    Treemap.shade(layout, into: &rgba, params: request.params, highlightExtension: request.highlight)
                    return (layout, rgba)
                }
                self.renderWork = work
                let rendered = await work.value
                self.renderWork = nil
                guard !Task.isCancelled, request.version == self.renderVersion, !rendered.1.isEmpty else { continue }
                self.mapView.layoutData = rendered.0
                self.renderedRoot = request.root
                self.mapView.show(rendered.1, width: request.width, height: request.height)
                self.mapView.selectedNode = self.selectedNode
                self.makeSnapshotIfNeeded()
                #if DEBUG
                if self.measurePending {
                    self.measurePending = false
                    Task { await self.measureUI() }
                }
                #endif
            }
            self?.mapTask = nil
        }
    }

    private func selectNode(_ id: Int32, fromMap: Bool = false) {
        if tree == nil, let model = liveScan, let node = model.node(id) {
            selectedNode = id; mapView.selectedNode = id
            if node.isDirectory && node.isSizing { model.prioritize(id) }
            status.stringValue = "\(node.name) · \(format(node.bytes))" + (node.isSizing ? " · sizing…" : "")
            updateStatus()
            if fromMap {
                let row = outline.row(forItem: NSNumber(value: id))
                if row >= 0 { selecting = true; outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row); selecting = false }
            }
            return
        }
        guard let tree, id >= 0, Int(id) < tree.parent.count else { return }
        var ancestor = id
        while ancestor > 0 && ancestor != zoomNode { ancestor = tree.parent[Int(ancestor)] }
        if ancestor != zoomNode {
            zoomNode = 0
            window.title = "MacDiskStats — \(tree.rootPath)"
            renderMap()
        }
        selectedNode = id; mapView.selectedNode = id; updateStatus()
        if fromMap {
            var ancestors: [Int32] = []; var parent = tree.parent[Int(id)]
            while parent > 0 { ancestors.append(parent); parent = tree.parent[Int(parent)] }
            selecting = true
            outline.beginUpdates()
            for item in ancestors.reversed() {
                let number = NSNumber(value: item)
                if !outline.isItemExpanded(number) { outline.expandItem(number, expandChildren: false) }
            }
            outline.endUpdates()
            let row = outline.row(forItem: NSNumber(value: id))
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
            selecting = false
        }
        let type = tree.extensionIndex[Int(id)]
        if type >= 0, Int(type) < tree.extensions.count { types.selectRowIndexes(IndexSet(integer: Int(type)), byExtendingSelection: false); types.scrollRowToVisible(Int(type)) }
        else { types.deselectAll(nil) }
    }
    private func selectPath(_ path: String) {
        guard let tree else { return }
        var current: Int32 = 0
        let root = tree.rootPath == "/" ? "" : tree.rootPath
        guard path == tree.rootPath || path.hasPrefix(root + "/") else { status.stringValue = "Selection is outside the scan: \(path)"; return }
        let relative = path.dropFirst(root.count).split(separator: "/")
        for part in relative {
            let begin = Int(tree.firstChild[Int(current)]), count = Int(tree.childCount[Int(current)])
            guard let child = (begin..<(begin + count)).lazy.map({ tree.children[$0] }).first(where: { tree.path(of: $0).split(separator: "/").last == part }) else {
                status.stringValue = "Could not find \(path) in this scan"; return
            }
            current = child
        }
        selectNode(current, fromMap: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let id = item == nil ? 0 : Int((item as? NSNumber)?.int32Value ?? 0)
        guard let tree else {
            #if DEBUG
            if snapshotMidRow && item == nil { return 1 }
            #endif
            return liveRows[Int32(id)]?.count ?? 0
        }
        return Int(tree.childCount[id])
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let id = item == nil ? 0 : Int((item as? NSNumber)?.int32Value ?? 0)
        guard let tree else {
            #if DEBUG
            if snapshotMidRow && item == nil { return NSNumber(value: -42) }
            #endif
            return NSNumber(value: liveRows[Int32(id)]?[index].id ?? 0)
        }
        return NSNumber(value: tree.children[Int(tree.firstChild[id]) + index])
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let id = (item as? NSNumber)?.int32Value else { return false }
        guard let tree else { return liveFrame?.nodes[id]?.isDirectory == true }
        return tree.flags[Int(id)].contains(.isDir) && tree.childCount[Int(id)] > 0
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = (item as? NSNumber)?.int32Value, let column = tableColumn else { return nil }
        #if DEBUG
        if snapshotMidRow && id == -42 {
            let cell = cellView(in: outlineView, key: column.identifier.rawValue, right: column.identifier.rawValue != "Name")
            switch column.identifier.rawValue {
            case "Name": cell.textField?.stringValue = "Large folder"; cell.imageView?.image = folderIcon
            case "Size":
                cell.textField?.stringValue = "999.99 GB"
                cell.subviews.compactMap { $0 as? NSProgressIndicator }.forEach { $0.isHidden = false; $0.startAnimation(nil) }
            case "Frees": cell.textField?.stringValue = "999.99 GB"
            default: cell.textField?.stringValue = "47.0%"
            }
            return cell
        }
        #endif
        let kind = column.identifier.rawValue
        let cell = cellView(in: outlineView, key: kind, right: kind != "Name")
        guard let tree else {
            guard let node = liveFrame?.nodes[id] else { return nil }
            switch kind {
            case "Name":
                cell.textField?.stringValue = node.isUnreadable ? "\(node.name)  unreadable" : node.name
                cell.textField?.font = node.isUnreadable ? Tokens.unreadableFont : Tokens.bodyFont
                cell.imageView?.image = node.isDirectory ? folderIcon : fileIcon
            case "Size":
                cell.textField?.stringValue = node.isUnreadable ? "unreadable" : (node.isSizing && node.bytes == 0 ? "" : format(node.bytes))
                cell.textField?.textColor = node.isSizing ? Tokens.muted(dark) : Tokens.text(dark)
                if let spinner = cell.subviews.compactMap({ $0 as? NSProgressIndicator }).first {
                    let animate = node.isSizing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    spinner.isHidden = !animate
                    if animate { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
                }
            case "Frees": cell.textField?.stringValue = "–"
            default:
                let total = liveFrame?.countedBytes ?? 0
                cell.textField?.stringValue = node.isUnreadable ? "—" : (total > 0 ? String(format: "%.1f%%", Double(node.bytes) / Double(total) * 100) : "")
            }
            return cell
        }
        let n = Int(id)
        switch kind {
        case "Name":
            let a = Int(tree.nameOffset[n]), b = a + Int(tree.nameLength[n])
            let name = String(decoding: tree.names[a..<b], as: UTF8.self)
            cell.textField?.stringValue = name
            cell.textField?.font = tree.flags[n].contains(.unreadable) ? Tokens.unreadableFont : Tokens.bodyFont
            cell.imageView?.image = tree.flags[n].contains(.isDir) ? folderIcon : fileIcon
        case "Size":
            cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "unreadable" : format(tree.countedSize[n])
            cell.subviews.compactMap { $0 as? NSProgressIndicator }.forEach { $0.stopAnimation(nil); $0.isHidden = true }
        case "Frees": cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "–" : (checkingSharedFiles ? "–" : format(tree.privateSize[n]))
        default:
            let root = max(1, tree.countedSize[0]); cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "—" : String(format: "%.1f%%", Double(tree.countedSize[n]) / Double(root) * 100)
        }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let item = outline.item(atRow: outline.selectedRow) as? NSNumber else { return }
        selectNode(item.int32Value)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NSNumber else { return }
        expandedIDs.insert(item.int32Value)
        if tree == nil { liveScan?.prioritize(item.int32Value) }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NSNumber else { return }
        expandedIDs.remove(item.int32Value)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === types { return tree?.extensions.count ?? liveTypes.count }
        if tableView === topTable { return topIDs.count }
        return 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let kind = column.identifier.rawValue
        let cell = cellView(in: tableView, key: kind, right: kind == "Size" || kind == "%")
        if tableView === types {
            let ext = tree?.extensions[row] ?? liveTypes[row]
            switch kind {
            case "Type":
                cell.textField?.stringValue = ext.name.isEmpty ? "(no extension)" : ".\(ext.name)"
                cell.imageView?.image = swatch(row)
            case "Size": cell.textField?.stringValue = format(ext.bytes)
            default:
                let total = tree?.countedSize[0] ?? liveFrame?.countedBytes ?? 0
                cell.textField?.stringValue = String(format: "%.1f%%", Double(ext.bytes) / Double(max(1, total)) * 100)
            }
        } else if tableView === topTable {
            guard let tree else { return nil }
            let id = topIDs[row]
            cell.textField?.stringValue = kind == "Size" ? format(tree.countedSize[Int(id)]) : tree.path(of: id)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === types {
            let selected = types.selectedRow >= 0 ? Int32(types.selectedRow) : nil
            if selected != highlightedType { highlightedType = selected; renderMap(shadeOnly: true) }
        } else if table === topTable, table.selectedRow >= 0, table.selectedRow < topIDs.count {
            selectNode(topIDs[table.selectedRow], fromMap: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === types && highlightedType == Int32(row) {
            types.deselectAll(nil); highlightedType = nil; renderMap(shadeOnly: true); return false
        }
        return true
    }
    private func cellView(in table: NSTableView, key: String, right: Bool) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("Cell-\(key)")
        if let old = table.makeView(withIdentifier: id, owner: self) as? NSTableCellView { return old }
        let columnWidth = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.width ?? 200
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: columnWidth, height: Tokens.rowHeight)); cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.font = right ? Tokens.numberFont : Tokens.bodyFont
        label.textColor = Tokens.text(dark)
        label.alignment = right ? .right : .left
        label.lineBreakMode = .byTruncatingMiddle
        let hasImage = key == "Name" || key == "Type"
        let leading = key == "%" ? CGFloat(2) : Tokens.cellInset + (hasImage ? Tokens.swatchSize + Tokens.cellInset : 0)
        let trailing = key == "%" ? CGFloat(2) : Tokens.cellInset
        label.frame = NSRect(x: leading, y: 2, width: max(0, columnWidth - leading - trailing), height: Tokens.rowHeight - 4)
        label.autoresizingMask = .width
        cell.addSubview(label); cell.textField = label
        if key == "Size" {
            let spinner = NSProgressIndicator(frame: NSRect(x: 1, y: (Tokens.rowHeight - Tokens.sizingSpinnerSize) / 2,
                                                             width: Tokens.sizingSpinnerSize, height: Tokens.sizingSpinnerSize))
            spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true
            cell.addSubview(spinner)
        }
        if hasImage {
            let image = NSImageView(frame: NSRect(x: Tokens.cellInset, y: (Tokens.rowHeight - Tokens.swatchSize) / 2, width: Tokens.swatchSize, height: Tokens.swatchSize))
            cell.addSubview(image); cell.imageView = image
        }
        return cell
    }
    private func swatch(_ index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: Tokens.swatchSize, height: Tokens.swatchSize))
        image.lockFocus(); Tokens.color(for: index, dark: dark).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: Tokens.swatchSize / 4, yRadius: Tokens.swatchSize / 4).fill()
        image.unlockFocus(); return image
    }
    private func label(_ value: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: value); field.font = font; field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
    private func volumeIcon(for path: String, scale: CGFloat) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        let side = Int((Tokens.sheetIconSize * max(1, scale)).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: Tokens.sheetIconSize, height: Tokens.sheetIconSize))
        image.addRepresentation(rep)
        return image
    }
    private func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        return byteFormatter.string(fromByteCount: bytes)
    }
    private func updateStatus() {
        guard status != nil else { return }
        if tree == nil {
            guard let model = liveScan, let rootPath else { layoutStatusLine(); return }
            let id = hoveredNode ?? selectedNode ?? zoomNode
            var ids: [Int32] = []
            var cursor = id
            while let node = model.node(cursor) {
                ids.append(cursor)
                if cursor == 0 { break }
                cursor = node.parent
            }
            if ids.last != 0 { ids = [0] }
            ids.reverse()
            let names = ids.map { $0 == 0 ? URL(fileURLWithPath: rootPath).lastPathComponent : (model.node($0)?.name ?? "") }
            let urls = ids.indices.map { index -> URL in
                if index == 0 { return URL(fileURLWithPath: rootPath) }
                return names[1...index].reduce(URL(fileURLWithPath: rootPath)) { $0.appendingPathComponent($1) }
            }
            setPathItems(ids: ids, urls: urls, directories: ids.map { model.node($0)?.isDirectory ?? true })
            summary.stringValue = status.stringValue
            fullStatusSummary = summary.stringValue
            summary.isHidden = false; status.isHidden = true; estimateNote.isHidden = true
            layoutStatusLine()
            return
        }
        guard let tree else { return }
        let suffix = checkingSharedFiles ? " · checking shared files…" : ""
        if let id = hoveredNode ?? selectedNode, id >= 0, Int(id) < tree.parent.count {
            let size = tree.flags[Int(id)].contains(.unreadable) ? "unreadable" : format(tree.countedSize[Int(id)])
            status.stringValue = "\(tree.path(of: id)) · \(size)" + suffix
        } else {
            let isVolumeRoot = tree.rootPath == "/" || tree.rootPath == "/System/Volumes/Data"
            let used = isVolumeRoot ? tree.volumeUsedBytes : tree.countedSize[0]
            let free = volumeFreeBytes
            let gap = isVolumeRoot ? max(0, tree.volumeUsedBytes - tree.countedSize[0]) : 0
            let freeText = free < 0 ? "free unavailable" : "\(format(free)) free"
            if isVolumeRoot {
                status.stringValue = "\(format(used)) used · \(freeText) · \(format(gap)) not counted · \(tree.unreadablePaths.count) entries unreadable" + suffix
            } else {
                let unreadable = tree.unreadablePaths.count
                status.stringValue = "\(format(tree.countedSize[0])) in this folder · \(freeText) on disk" + (unreadable > 0 ? " · \(unreadable) entries unreadable" : "") + suffix
            }
        }
        let isVolumeRoot = tree.rootPath == "/" || tree.rootPath == "/System/Volumes/Data"
        let used = isVolumeRoot ? tree.volumeUsedBytes : tree.countedSize[0]
        let freeText = volumeFreeBytes < 0 ? "free unavailable" : "\(format(volumeFreeBytes)) free"
        let gap = max(0, tree.volumeUsedBytes - tree.countedSize[0])
        summary.stringValue = isVolumeRoot
            ? "\(format(used)) used · \(freeText) · \(format(gap)) not counted · \(tree.unreadablePaths.count) unreadable" + suffix
            : "\(format(used)) in this folder · \(freeText) on disk" + (tree.unreadablePaths.isEmpty ? "" : " · \(tree.unreadablePaths.count) unreadable") + suffix
        fullStatusSummary = summary.stringValue
        summary.isHidden = false; status.isHidden = true
        estimateNote.isHidden = tree.limitations.isEmpty && tree.unreadablePaths.isEmpty
        let limits = tree.limitations + (tree.unreadablePaths.isEmpty ? [] : ["Some entries could not be read. The map leaves out their contents."])
        estimateNote.toolTip = limits.isEmpty ? nil : limits.joined(separator: "\n")
        let id = hoveredNode ?? selectedNode ?? zoomNode
        if id >= 0, Int(id) < tree.parent.count {
            let ids = Array(sequence(first: id, next: { $0 == 0 ? nil : tree.parent[Int($0)] }).reversed())
            setPathItems(ids: ids, urls: ids.map { tree.url(of: $0) }, directories: ids.map { tree.flags[Int($0)].contains(.isDir) })
        }
        layoutStatusLine()
    }
    private func setPathItems(ids: [Int32], urls: [URL], directories: [Bool]) {
        guard let last = urls.last else { return }
        pathBar.url = last
        let items = Array(pathBar.pathItems.suffix(ids.count))
        pathBar.pathItems = items
        pathItemNodes.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            let node = ids[index]
            item.image = index == 0 && (rootPath == "/" || rootPath == "/System/Volumes/Data")
                ? NSWorkspace.shared.icon(forFile: urls[index].path)
                : (directories[index] ? folderIcon : NSWorkspace.shared.icon(forFile: urls[index].path))
            pathItemNodes[ObjectIdentifier(item)] = node
        }
        pathBar.isHidden = items.isEmpty
    }
    private func layoutStatusLine() {
        guard let host = scanView, let pathBar, let summary, let estimateNote, let progress else { return }
        let right = host.bounds.width - Tokens.inset
        let progressWidth = progress.isHidden ? 0 : Tokens.statusBarWidth
        if pathBar.isHidden {
            progress.frame.origin.x = right - progressWidth
            status.frame = NSRect(x: Tokens.inset, y: 0, width: max(0, progress.frame.minX - 2 * Tokens.inset), height: Tokens.statusHeight)
            return
        }
        let fullSummary = fullStatusSummary.isEmpty ? summary.stringValue : fullStatusSummary
        let shortSummary = fullSummary.components(separatedBy: Tokens.statusSeparator).first ?? fullSummary
        let fullEstimateWidth = estimateNote.isHidden ? 0 : ("Some sizes are estimates" as NSString).size(withAttributes: [.font: Tokens.statusFont]).width + Tokens.inset
        let shortEstimateWidth = estimateNote.isHidden ? 0 : (Tokens.estimateIcon as NSString).size(withAttributes: [.font: Tokens.statusFont]).width + Tokens.inset
        let fullSummaryWidth = (fullSummary as NSString).size(withAttributes: [.font: Tokens.statusFont]).width + Tokens.inset
        let shortSummaryWidth = (shortSummary as NSString).size(withAttributes: [.font: Tokens.statusFont]).width + Tokens.inset
        let budget = max(0, right - Tokens.inset - Tokens.minPathBarWidth - progressWidth - (progressWidth > 0 ? Tokens.inset : 0) - 2 * Tokens.inset)
        let useShortSummary = fullSummaryWidth + fullEstimateWidth > budget
        summary.stringValue = useShortSummary ? shortSummary : fullSummary
        let useIcon = useShortSummary && shortSummaryWidth + fullEstimateWidth > budget
        estimateNote.stringValue = useIcon ? Tokens.estimateIcon : "Some sizes are estimates"
        let estimateWidth = useIcon ? shortEstimateWidth : fullEstimateWidth
        let summaryWidth = min((summary.stringValue as NSString).size(withAttributes: [.font: Tokens.statusFont]).width + Tokens.inset,
                               host.bounds.width * Tokens.summaryMaxFraction, max(0, budget - estimateWidth))
        summary.frame = NSRect(x: right - summaryWidth, y: 0, width: summaryWidth, height: Tokens.statusHeight)
        var next = summary.frame.minX - Tokens.inset
        if !progress.isHidden {
            progress.frame.origin.x = next - Tokens.statusBarWidth
            next = progress.frame.minX - Tokens.inset
        }
        if !estimateNote.isHidden {
            estimateNote.frame = NSRect(x: next - estimateWidth, y: 0, width: estimateWidth, height: Tokens.statusHeight)
            next = estimateNote.frame.minX - Tokens.inset
        }
        pathBar.frame = NSRect(x: Tokens.inset, y: Tokens.pathBarVerticalInset,
                               width: max(Tokens.minPathBarWidth, next - 2 * Tokens.inset), height: Tokens.statusHeight - 2 * Tokens.pathBarVerticalInset)
    }
    @objc private func pathItemClicked(_ sender: NSPathControl) {
        guard let item = sender.clickedPathItem, let id = pathItemNodes[ObjectIdentifier(item)] else { updateStatus(); return }
        if let tree {
            guard id >= 0, Int(id) < tree.parent.count else { return }
            selectNode(id, fromMap: true)
            if tree.flags[Int(id)].contains(.isDir) {
                zoomNode = id; window.title = "MacDiskStats — \(tree.path(of: id))"; renderMap()
            }
        } else if let model = liveScan, let node = model.node(id) {
            selectNode(id, fromMap: true)
            if node.isDirectory { zoomNode = id; model.prioritize(id); if let liveFrame { showLiveMap(liveFrame) } }
        }
        updateStatus()
    }
    private func updateBanner() {
        banner?.removeFromSuperview(); banner = nil
        guard let tree, !tree.unreadablePaths.isEmpty, !bannerDismissed, let host = scanView else { return }
        let row = NSView(frame: NSRect(x: 0, y: Tokens.statusHeight, width: host.bounds.width, height: Tokens.bannerHeight))
        row.autoresizingMask = [.width, .maxYMargin]; row.wantsLayer = true; row.layer?.backgroundColor = Tokens.secondary(dark).cgColor
        let text = label("Some entries could not be read. The map leaves out their contents.", font: Tokens.statusFont, color: Tokens.text(dark))
        text.frame = NSRect(x: Tokens.inset, y: (Tokens.bannerHeight - Tokens.bannerTextHeight) / 2,
                            width: row.bounds.width - Tokens.bannerActionWidth - Tokens.bannerCloseWidth - 3 * Tokens.inset - Tokens.bannerGap,
                            height: Tokens.bannerTextHeight)
        text.autoresizingMask = [.width]; row.addSubview(text)
        let settings = NSButton(title: "Full Disk Access", target: self, action: #selector(openFullDiskAccess))
        settings.bezelStyle = .rounded; settings.font = Tokens.statusFont
        settings.frame = NSRect(x: row.bounds.width - Tokens.inset - Tokens.bannerCloseWidth - Tokens.bannerGap - Tokens.bannerActionWidth,
                                y: (Tokens.bannerHeight - Tokens.bannerControlHeight) / 2,
                                width: Tokens.bannerActionWidth, height: Tokens.bannerControlHeight)
        settings.autoresizingMask = [.minXMargin]; row.addSubview(settings)
        let close = NSButton(title: "×", target: self, action: #selector(dismissBanner))
        close.bezelStyle = .circular
        close.frame = NSRect(x: row.bounds.width - Tokens.inset - Tokens.bannerCloseWidth,
                             y: (Tokens.bannerHeight - Tokens.bannerControlHeight) / 2,
                             width: Tokens.bannerCloseWidth, height: Tokens.bannerControlHeight)
        close.autoresizingMask = [.minXMargin]; row.addSubview(close)
        host.addSubview(row); banner = row
    }
    @objc private func dismissBanner() { bannerDismissed = true; banner?.removeFromSuperview(); banner = nil }
    @objc private func openFullDiskAccess() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    private func refreshAppearance() {
        guard scanView != nil else { return }
        mapView?.dark = dark
        status?.textColor = Tokens.muted(dark)
        summary?.textColor = Tokens.muted(dark)
        estimateNote?.textColor = Tokens.muted(dark)
        scanView?.wantsLayer = true; scanView?.layer?.backgroundColor = Tokens.background(dark).cgColor
        outline?.reloadData(); types?.reloadData(); updateBanner(); renderMap()
    }

    @objc private func zoomIn() {
        if tree == nil, let selectedNode, let node = liveScan?.node(selectedNode), node.isDirectory {
            zoomNode = selectedNode; liveScan?.prioritize(selectedNode); window.title = "MacDiskStats — \(node.name)"; if let liveFrame { showLiveMap(liveFrame) }; return
        }
        guard let tree, let selectedNode, tree.flags[Int(selectedNode)].contains(.isDir) else { return }
        zoomNode = selectedNode; window.title = "MacDiskStats — \(tree.path(of: zoomNode))"; renderMap()
    }
    @objc private func zoomOut() {
        if tree == nil, zoomNode != 0, let node = liveScan?.node(zoomNode) {
            zoomNode = node.parent; if let liveFrame { showLiveMap(liveFrame) }; return
        }
        guard let tree, zoomNode != 0 else { return }
        zoomNode = tree.parent[Int(zoomNode)]; window.title = "MacDiskStats — \(tree.path(of: zoomNode))"; renderMap()
    }
    @objc private func zoomTop() {
        if tree == nil { zoomNode = 0; if let liveFrame { showLiveMap(liveFrame) }; return }
        guard let tree else { return }; zoomNode = 0; window.title = "MacDiskStats — \(tree.rootPath)"; renderMap()
    }
    @objc private func rescan() { if let rootPath { startScan(rootPath) } }
    @objc private func rescanFolder() {
        guard let tree, let selectedNode, tree.flags[Int(selectedNode)].contains(.isDir), let rootPath else { return }
        pendingSelect = tree.path(of: selectedNode)
        startScan(rootPath)
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quick Look", action: #selector(quickLook), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rescan Folder", action: #selector(rescanFolder), keyEquivalent: "").target = self
        return menu
    }
    @objc private func reveal() {
        guard let tree, let selectedNode else { return }
        revealFiles([tree.url(of: selectedNode)])
    }
    @objc private func copyPath() {
        guard let tree, let selectedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([tree.url(of: selectedNode) as NSURL])
        NSPasteboard.general.setString(tree.path(of: selectedNode), forType: .string)
    }
    @objc private func quickLook() {
        guard tree != nil, selectedNode != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.delegate = self; panel.makeKeyAndOrderFront(nil); panel.reloadData()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { tree != nil && selectedNode != nil ? 1 : 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let tree, let selectedNode else { return nil }
        return tree.url(of: selectedNode) as NSURL
    }
    @objc private func showLargest() {
        guard let tree else { return }
        topIDs = tree.topFiles(limit: 100)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: Tokens.startWidth, height: Tokens.windowSize.height * Tokens.topFraction)), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "100 Largest Files"
        let scroll = NSScrollView(frame: win.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let table = NSTableView(frame: .zero); table.rowHeight = Tokens.rowHeight; table.dataSource = self; table.delegate = self
        for (name, width) in Tokens.largestColumns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); col.title = name; col.width = width; col.headerCell.font = Tokens.headerFont; table.addTableColumn(col)
        }
        topTable = table; scroll.documentView = table; win.contentView?.addSubview(scroll)
        topWindow = win; win.makeKeyAndOrderFront(nil)
    }

    private func makeSnapshotIfNeeded() {
        #if DEBUG
        if let snapshotPath {
            self.snapshotPath = nil
            DebugSnapshot.capture(window: window, path: snapshotPath, size: snapshotMinWidth ? NSSize(width: Tokens.minWindowWidth, height: Tokens.windowSize.height) : nil)
        }
        #endif
    }

    #if DEBUG
    private func runE2E(_ script: String) async {
        var failed = 0, passed = 0
        func check(_ name: String, _ good: Bool) {
            print("\(good ? "PASS" : "FAIL") e2e: \(name)")
            if good { passed += 1 } else { failed += 1 }
            fflush(stdout)
        }
        func sendKey(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
            NSApp.sendEvent(event)
        }
        func clickPathItem(at index: Int) -> Bool {
            guard let pathBar = self.pathBar, let cell = pathBar.cell as? NSPathCell, index < cell.pathComponentCells.count else { return false }
            let component = cell.pathComponentCells[index]
            let rect = cell.rect(of: component, withFrame: pathBar.bounds, in: pathBar)
            guard !rect.isEmpty else { return false }
            let location = pathBar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return false }
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            return true
        }
        let volumeButtons = startView?.subviews.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "/" || $0.identifier?.rawValue.hasPrefix("/Volumes/") == true } ?? []
        check("start screen lists disks", startView != nil && !volumeButtons.isEmpty)
        if script == "start" {
            check("bug: empty layout is present before scan", scanView != nil && outline.numberOfRows == 0 && types.numberOfRows == 0 && mapView.layoutData == nil && status.stringValue == "No scan yet")
            check("bug: path bar absent before scan", pathBar.isHidden && summary.isHidden)
            check("bug: scan sheet is attached at launch", startSheet != nil && window.attachedSheet === startSheet && !volumePaths.isEmpty)
            let firstSheet = startSheet
            sendKey(45, "n", .command); sendKey(45, "n", .command)
            check("bug: repeated Cmd-N keeps one sheet", startSheet === firstSheet && window.attachedSheet === firstSheet)
            let list = startSheet?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first
            check("bug: one disk uses one list row", list.map { abs($0.frame.height - CGFloat(max(1, min(volumePaths.count, Tokens.sheetVisibleRows))) * Tokens.sheetRowHeight) < 1 } == true)
            let scanButton = startSheet?.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Scan" }
            check("bug: Scan is the default button", scanButton?.keyEquivalent == "\r" && startSheet?.defaultButtonCell === scanButton?.cell)
            let firstIcon = startView?.subviews.compactMap { $0 as? NSButton }.first?.subviews.compactMap { $0 as? NSImageView }.first
            check("bug: volume icon uses backing scale", firstIcon?.image?.representations.contains(where: { $0.pixelsWide >= Int(Tokens.sheetIconSize * (startSheet?.backingScaleFactor ?? 1)) }) == true)
            let cancelButton = startSheet?.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }
            sendKey(53, "\u{1b}")
            check("bug: Escape closes start sheet", startSheet == nil)
            if startSheet != nil, let cancelButton { NSApp.sendAction(cancelButton.action!, to: cancelButton.target, from: cancelButton) }
            check("bug: cancel keeps empty layout", startSheet == nil && scanView != nil && outline.numberOfRows == 0 && status.stringValue == "No scan yet")
            let newScanItem = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu?.item(withTitle: "New Scan")
            if let newScanItem { NSApp.sendAction(newScanItem.action!, to: newScanItem.target, from: newScanItem) }
            check("bug: New Scan reopens sheet", newScanItem?.keyEquivalent == "n" && startSheet != nil && window.attachedSheet === startSheet)
            sendKey(45, "n", .command)
            check("bug: Cmd-N with sheet open does not queue another", startSheet != nil && window.attachedSheet === startSheet)
            let originalHost = scanView
            let expectedPath = rootPath
            if let expectedPath { volumePaths = [expectedPath]; selectedVolume = 0; sendKey(36, "\r") }
            check("bug: sheet Scan keeps the same layout", startSheet == nil && isScanning && scanView === originalHost)
            check("bug: Return starts selected scan", isScanning && self.rootPath == expectedPath)
            check("bug: progress does not cover scanning text", status.frame.maxX <= progress.frame.minX - Tokens.inset)
            progress.isIndeterminate = false; progress.doubleValue = 47
            check("bug: progress fill matches 47 percent", abs(progress.fillWidth - progress.bounds.width * 0.47) <= 2)
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Tokens.statusBarWidth), pixelsHigh: Int(Tokens.statusBarHeight), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                progress.draw(progress.bounds); context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
                let filled = rep.colorAt(x: 12, y: 3)?.usingColorSpace(.deviceRGB)
                let unfilled = rep.colorAt(x: 100, y: 3)?.usingColorSpace(.deviceRGB)
                check("bug: progress pixels show actual fill", filled != nil && unfilled != nil && abs((filled?.redComponent ?? 0) - (unfilled?.redComponent ?? 0)) > 0.05)
            } else { check("bug: progress pixels show actual fill", false) }
            let sizeColumn = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Size"))
            let cell = cellView(in: outline, key: "Size", right: true)
            let textFits = ("999.99 GB" as NSString).size(withAttributes: [.font: Tokens.numberFont]).width <= cell.textField!.bounds.width
            check("bug: large Size fits with spinner", (sizeColumn?.width ?? 0) >= 110 && textFits && cell.subviews.contains(where: { $0 is NSProgressIndicator }))
            cancelScan()
            showStart()
            check("bug: reopen sheet after scan cancellation", startSheet != nil && window.attachedSheet === startSheet)
            chooseFolder()
            await Task.yield()
            let picker = window.attachedSheet as? NSOpenPanel
            check("bug: Choose Folder replaces start sheet", startSheet == nil && picker != nil)
            sendKey(45, "n", .command)
            check("bug: Cmd-N cannot queue behind folder picker", startSheet == nil && window.attachedSheet === picker)
            picker?.cancel(nil)
            await Task.yield()
            showStart()
            let sheetAtClose = startSheet
            window.close()
            check("bug: closing window with sheet open closes window", sheetAtClose != nil && !window.isVisible)
            print("e2e \(passed) passed, \(failed) failed"); fflush(stdout); NSApp.terminate(nil); return
        }
        guard script == "fixture", let rootPath else {
            check("fixture script and path supplied", false); print("e2e \(passed) passed, \(failed) failed"); NSApp.terminate(nil); return
        }
        closeStartSheet()
        startScan(rootPath)
        var sawLiveRows = false, sawSizing = false, liveFolder: Int32?
        var selectedLiveExtension: String?
        var clickedPhaseTwo = false
        e2ePhaseTwoClick = { [weak self] in
            guard let self, let liveFolder else { check("bug: phase two path click selects and zooms", false); return }
            self.selectNode(liveFolder, fromMap: true)
            self.selectedNode = nil; self.zoomNode = 0
            clickedPhaseTwo = clickPathItem(at: 1)
            check("bug: phase two path click selects and zooms", clickedPhaseTwo && self.checkingSharedFiles && self.selectedNode == liveFolder && self.zoomNode == liveFolder)
            if let selectedLiveExtension, let row = self.tree?.extensions.firstIndex(where: { $0.name == selectedLiveExtension }) {
                self.types.deselectAll(nil)
                self.highlightedType = nil
                self.types.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.highlightedType = Int32(row)
            }
        }
        for _ in 0..<200 {
            if tree != nil { break }
            if let model = liveScan, outline.numberOfRows > 0 {
                sawLiveRows = true
                if selectedLiveExtension == nil { selectedLiveExtension = liveTypes.first?.name }
                if let folder = model.children(of: 0).first(where: { $0.isDirectory && $0.isSizing }) {
                    sawSizing = true; liveFolder = folder.id
                    outline.expandItem(NSNumber(value: folder.id))
                    selectNode(folder.id, fromMap: true)
                    zoomIn()
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check("bug: tree rows absent until phase one ends", sawLiveRows)
        if let model = liveScan { zoomNode = 0; showLiveMap(model.snapshot(childrenOf: [0])) }
        check("bug: map and file types stay blank during phase one", sawLiveRows && mapView.hasPreview && types.numberOfRows > 0)
        check("bug: folder has no sizing state during scan", sawSizing)
        if let liveFolder {
            selectNode(liveFolder, fromMap: true)
            check("bug: live path bar follows node ids", !pathBar.isHidden && pathBar.pathItems.count > 1 && pathBar.pathItems.last?.title == liveScan?.node(liveFolder)?.name)
            selectedNode = nil; zoomNode = 0
            let clicked = clickPathItem(at: 1)
            await Task.yield()
            check("bug: phase one path click selects and zooms", clicked && tree == nil && selectedNode == liveFolder && zoomNode == liveFolder)
        }
        check("bug: expanding during scan loses live children", liveFolder.map { outline.isItemExpanded(NSNumber(value: $0)) } == true)
        if let liveFolder {
            liveTickTask?.cancel()
            selectNode(0, fromMap: true)
            liveRows[0] = []
            e2eRefreshAfterCapture = { [weak self] in
                guard let self else { return }
                self.selectNode(liveFolder, fromMap: true)
            }
            await refreshLive()
            e2eRefreshAfterCapture = nil
            check("bug: live refresh overrides selection made during snapshot", selectedNode == liveFolder && outline.item(atRow: outline.selectedRow) as? NSNumber == NSNumber(value: liveFolder))
            liveTickTask = Task { [weak self] in
                while let self, self.isScanning, self.tree == nil, !Task.isCancelled {
                    await self.refreshLive()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } else { check("bug: live refresh overrides selection made during snapshot", false) }
        var emptyLiveFolder: Int32?
        if let liveFolder {
            for _ in 0..<100 {
                emptyLiveFolder = liveScan?.children(of: liveFolder).first(where: { $0.isDirectory })?.id
                if emptyLiveFolder != nil { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        if let emptyLiveFolder, let model = liveScan {
            zoomNode = emptyLiveFolder
            showLiveMap(model.snapshot(childrenOf: [emptyLiveFolder]))
        }
        check("bug: empty live zoom retains old map hit targets", emptyLiveFolder != nil && !mapView.hasPreview)
        if let liveFolder { zoomNode = liveFolder; if let model = liveScan { showLiveMap(model.snapshot(childrenOf: [liveFolder])) } }
        if let selectedLiveExtension, let row = liveTypes.firstIndex(where: { $0.name == selectedLiveExtension }) {
            types.deselectAll(nil)
            highlightedType = nil
            types.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        check("bug: live Quick Look advertises missing item", selectedNode == nil || numberOfPreviewItems(in: QLPreviewPanel.shared()) == 0)
        for _ in 0..<200 where isScanning || tree == nil || mapView.layoutData == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !clickedPhaseTwo { check("bug: phase two path click selects and zooms", false) }
        guard let tree else {
            check("fixture scan completed", false); print("e2e \(passed) passed, \(failed) failed"); NSApp.terminate(nil); return
        }
        check("bug: selected live type changes rank at final handoff", selectedLiveExtension != nil && tree.extensions.first?.name != selectedLiveExtension && highlightedType.flatMap { id in id >= 0 && Int(id) < tree.extensions.count ? tree.extensions[Int(id)].name : nil } == selectedLiveExtension)
        check("bug: live selection and zoom lost across scan phases", liveFolder == nil || selectedNode == liveFolder && zoomNode == liveFolder)
        check("bug: phase two path bar keeps node ids", liveFolder.map { !pathBar.isHidden && pathBar.pathItems.last?.title == tree.path(of: $0).split(separator: "/").last.map(String.init) } ?? true)
        zoomTop(); await mapTask?.value
        await mapTask?.value
        check("tree types and map filled", tree.filesSeen >= 2 && outline.numberOfRows > 0 && types.numberOfRows > 0 && mapView.layoutData?.boxCount ?? 0 > 0)
        let parts = banner?.subviews ?? []
        let bannerCenters = parts.map { $0.frame.midY }
        let bannerInside = parts.allSatisfy { part in
            guard let frame = part.superview?.convert(part.frame, to: content) else { return false }
            return content.bounds.contains(frame)
        }
        let bannerMargins = banner.map { row in
            parts.dropFirst().allSatisfy { $0.frame.minY >= 2 && $0.frame.maxY <= row.bounds.height - 2 }
                && (parts.last?.frame.maxX ?? row.bounds.width) <= row.bounds.width - Tokens.inset
        } == true
        check("bug: banner text button and close share vertical center inside window", !tree.unreadablePaths.isEmpty && parts.count == 3 && (bannerCenters.max() ?? 100) - (bannerCenters.min() ?? 0) <= 1 && bannerInside && bannerMargins)
        check("bug: estimates label holds full limitation text", !estimateNote.isHidden && estimateNote.stringValue == "Some sizes are estimates" && estimateNote.toolTip?.contains("Some entries could not be read") == true)
        setPathItems(ids: [0], urls: [URL(fileURLWithPath: "/")], directories: [true])
        check("bug: volume root slash has one path item", pathBar.pathItems.count == 1 && pathBar.pathItems[0].url?.path == "/" && pathItemNodes[ObjectIdentifier(pathBar.pathItems[0])] == 0)
        updateStatus()
        check("bug: path control refuses outside root drops", !pathBar.isEditable && pathBar.registeredDraggedTypes.isEmpty)
        let percentColumn = outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("%"))
        let percentCell = cellView(in: outline, key: "%", right: true)
        check("bug: percent cells fit 100 percent", percentColumn.map { $0.minWidth >= Tokens.treeColumns.last?.1 ?? 0 } == true && ("100.0%" as NSString).size(withAttributes: [.font: Tokens.numberFont]).width <= (percentCell.textField?.frame.width ?? 0))
        let typePercentColumn = types.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("%"))
        let typePercentCell = cellView(in: types, key: "%", right: true)
        check("bug: type percent cells fit 100 percent", typePercentColumn.map { $0.minWidth >= Tokens.typeColumns.last?.1 ?? 0 } == true && ("100.0%" as NSString).size(withAttributes: [.font: Tokens.numberFont]).width <= (typePercentCell.textField?.frame.width ?? 0))
        if let unreadable = tree.parent.indices.first(where: { tree.flags[$0].contains(.unreadable) }), let percentColumn {
            let percent = outlineView(outline, viewFor: percentColumn, item: NSNumber(value: unreadable)) as? NSTableCellView
            check("bug: unreadable appears only in Size column", percent?.textField?.stringValue == "—")
        } else { check("bug: unreadable appears only in Size column", false) }
        guard let layout = mapView.layoutData, let file = tree.children.first(where: { !tree.flags[Int($0)].contains(.isDir) && tree.countedSize[Int($0)] > 0 }), let box = layout.rect(of: file) else {
            check("fixture has a visible file box", false); print("e2e \(passed) passed, \(failed) failed"); NSApp.terminate(nil); return
        }
        if let hit = layout.hitTest(x: box.x + box.width / 2, y: box.y + box.height / 2) { selectNode(hit, fromMap: true) }
        check("map hit selects tree row and type", selectedNode == file && outline.selectedRow >= 0 && types.selectedRow == Int(tree.extensionIndex[Int(file)]))
        selectNode(file, fromMap: true)
        check("row selection frames map box", mapView.selectedNode == file && layout.rect(of: file) != nil)
        if let frame = mapView.selectionFrameBounds() {
            let visualY = mapView.layer?.isGeometryFlipped == true ? frame.midY : mapView.bounds.height - frame.midY
            let hitY = Int(visualY / mapView.bounds.height * CGFloat(layout.height))
            let hitX = Int(frame.midX / mapView.bounds.width * CGFloat(layout.width))
            check("selection frame matches hit at real backing scale", layout.width == Int((mapView.bounds.width * window.backingScaleFactor).rounded()) && layout.hitTest(x: hitX, y: hitY) == file)
        } else { check("selection frame matches hit at real backing scale", false) }
        let beforeArrow = outline.selectedRow
        let nextArrow = min(beforeArrow + 1, outline.numberOfRows - 1)
        outline.selectRowIndexes(IndexSet(integer: nextArrow), byExtendingSelection: false)
        check("arrow navigation selection callback moves row", outline.selectedRow == nextArrow && nextArrow != beforeArrow)
        selectNode(file, fromMap: true)
        check("selection status has path", status.stringValue.contains(tree.path(of: file)))
        let pathBar = scanView?.subviews.compactMap { $0 as? NSPathControl }.first
        let deepFile = tree.children.first { tree.path(of: $0).hasSuffix("/nested/other.png") } ?? file
        selectNode(deepFile, fromMap: true)
        let pathIDs: [Int32] = Array(sequence(first: deepFile, next: { $0 == 0 ? nil : tree.parent[Int($0)] }).reversed())
        check("bug: path bar has one item per folder from scan root", pathBar?.pathItems.count == pathIDs.count && zip(pathBar?.pathItems ?? [], pathIDs).allSatisfy { $0.url?.path == tree.path(of: $1) })
        check("bug: path items have direct node identity", pathBar?.pathItems.count == pathIDs.count && zip(pathBar?.pathItems ?? [], pathIDs).allSatisfy { pathItemNodes[ObjectIdentifier($0)] == $1 })
        check("bug: path items use file and folder icons", pathBar?.pathItems.last?.image != nil && pathBar?.pathItems.dropLast().allSatisfy { $0.image === folderIcon } == true)
        check("bug: drawn path cells use folder icons", folderIcon.isTemplate == false && (pathBar?.cell as? NSPathCell).map { cell in cell.pathComponentCells.dropLast().allSatisfy { $0.image === folderIcon } } == true)
        if let link = tree.parent.indices.first(where: { tree.flags[$0].contains(.symlink) }) {
            selectNode(Int32(link), fromMap: true)
            check("bug: symlink path keeps its node identity", self.pathBar.pathItems.last.flatMap { pathItemNodes[ObjectIdentifier($0)] } == Int32(link))
            selectNode(deepFile, fromMap: true)
        } else { check("bug: symlink path keeps its node identity", false) }
        let invalidName = FileTree.displayName(bytes: [0xFF])
        let literalName = FileTree.displayName(bytes: Array("%FF".utf8))
        let rawURL = FileTree.url(pathBytes: Array(rootPath.utf8) + [47, 0xFF], isDirectory: false)
        setPathItems(ids: [0, 1], urls: [URL(fileURLWithPath: rootPath), rawURL], directories: [true, false])
        let rawID = self.pathBar.pathItems.last.flatMap { pathItemNodes[ObjectIdentifier($0)] }
        setPathItems(ids: [0, 2], urls: [URL(fileURLWithPath: rootPath), URL(fileURLWithPath: rootPath).appendingPathComponent("%FF")], directories: [true, false])
        let literalID = self.pathBar.pathItems.last.flatMap { pathItemNodes[ObjectIdentifier($0)] }
        check("bug: colliding display names keep distinct ids", invalidName == literalName && rawID == 1 && literalID == 2)
        updateStatus()
        check("bug: path bar gives way to scan summary", pathBar.map { $0.frame.maxX <= summary.frame.minX && (progress.isHidden || $0.frame.maxX <= progress.frame.minX) } == true)
        if let folder = pathIDs.dropLast().last, let pathBar {
            if let cell = pathBar.cell as? NSPathCell, cell.pathComponentCells.count >= pathIDs.count {
                let component = cell.pathComponentCells[cell.pathComponentCells.count - 2]
                let rect = cell.rect(of: component, withFrame: pathBar.bounds, in: pathBar)
                let location = pathBar.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                if !rect.isEmpty,
                   let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                   let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
                    NSApp.postEvent(up, atStart: false)
                    NSApp.sendEvent(down)
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            check("bug: clicking path folder selects and zooms", selectedNode == folder && zoomNode == folder)
        } else { check("bug: clicking path folder selects and zooms", false) }
        selectNode(deepFile, fromMap: true)
        hoveredNode = file; updateStatus()
        check("hover status has path", status.stringValue.contains(tree.path(of: file)))
        hoveredNode = nil; updateStatus()
        check("bug: leaving map restores selected path", pathBar?.url?.path == tree.path(of: deepFile))
        selectNode(file, fromMap: true)
        var plain: [UInt8] = [], restored: [UInt8] = [], highlighted: [UInt8] = []
        let params = Tokens.mapParams(dark: dark)
        Treemap.shade(layout, into: &plain, params: params)
        types.selectRowIndexes(IndexSet(integer: Int(tree.extensionIndex[Int(file)])), byExtendingSelection: false)
        await mapTask?.value
        Treemap.shade(layout, into: &highlighted, params: params, highlightExtension: highlightedType)
        types.deselectAll(nil); highlightedType = nil; renderMap(shadeOnly: true)
        await mapTask?.value
        Treemap.shade(layout, into: &restored, params: params)
        check("type highlight clears to identical pixels", highlighted != plain && restored == plain)
        for i in 0..<30 {
            zoomNode = i.isMultiple(of: 2) ? 0 : (tree.children.first { tree.flags[Int($0)].contains(.isDir) } ?? 0)
            renderMap()
        }
        zoomNode = 0; renderMap(); await mapTask?.value
        check("bug: rapid zoom queues unbounded renders", pendingRender == nil && renderWork == nil && renderedRoot == 0)
        showLargest()
        check("Top 100 opens", topWindow != nil && !topIDs.isEmpty)
        if let topTable, !topIDs.isEmpty {
            topTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            check("Top 100 row selects main window", selectedNode == topIDs[0])
        }
        selectNode(file, fromMap: true)
        var revealed: [URL] = []
        revealFiles = { revealed = $0 }
        reveal()
        check("Reveal in Finder sends selected URL", revealed == [tree.url(of: file)])
        copyPath()
        check("Copy Path writes exact path", NSPasteboard.general.string(forType: .string) == tree.path(of: file))
        let item = previewPanel(QLPreviewPanel.shared(), previewItemAt: 0) as? NSURL
        check("Quick Look source resolves exact URL", item?.path == URL(fileURLWithPath: tree.path(of: file)).path)
        let allowed = ["Delete", "Trash", "Move", "Rename"]
        func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
        check("menus contain no write actions", !titles(NSApp.mainMenu!).contains { title in allowed.contains { title.localizedCaseInsensitiveContains($0) } })
        check("context menu contains no write actions", !titles(contextMenu()).contains { title in allowed.contains { title.localizedCaseInsensitiveContains($0) } })
        if let folder = tree.children.first(where: { tree.flags[Int($0)].contains(.isDir) && tree.childCount[Int($0)] > 0 }) {
            selectNode(folder, fromMap: true); zoomIn(); await mapTask?.value
            check("zoom in enters folder", zoomNode == folder)
            zoomOut(); await mapTask?.value
            check("zoom out returns to parent", zoomNode == 0)
            zoomIn(); zoomTop(); await mapTask?.value
            check("zoom top returns to root", zoomNode == 0)
        } else { check("fixture folder for zoom", false) }
        let oldSize = mapView.layoutData?.width
        window.setContentSize(NSSize(width: window.contentLayoutRect.width + 100, height: window.contentLayoutRect.height + 30))
        scheduleMapRender()
        try? await Task.sleep(for: .milliseconds(250)); await mapTask?.value
        check("resize redraws map", mapView.layoutData?.width != oldSize)
        let wideSize = window.contentLayoutRect.size
        window.setContentSize(NSSize(width: Tokens.minTreeWidth + Tokens.minTypesWidth, height: wideSize.height))
        let progressWasHidden = progress.isHidden
        progress.isHidden = false
        layoutStatusLine()
        check("bug: narrow window keeps path summary and progress separate",
              self.pathBar.frame.width >= Tokens.minPathBarWidth && self.pathBar.frame.maxX <= (estimateNote.isHidden ? (progress.isHidden ? summary.frame.minX : progress.frame.minX) : estimateNote.frame.minX)
                  && summary.frame.maxX <= (scanView?.bounds.maxX ?? 0) - Tokens.inset
                  && progress.frame.minX >= Tokens.inset)
        progress.isHidden = progressWasHidden
        window.setContentSize(wideSize); scheduleMapRender(); await mapTask?.value
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(50))
            await mapTask?.value
            check("\(name) map renders", mapView.layoutData?.boxCount ?? 0 > 0)
            check("bug: \(name) status labels follow appearance", summary.textColor == Tokens.muted(dark) && estimateNote.textColor == Tokens.muted(dark))
        }
        let deleted = URL(fileURLWithPath: rootPath).appendingPathComponent("delete-me.txt")
        check("rescan fixture initially includes file", tree.children.contains { tree.path(of: $0) == deleted.path })
        print("E2E DELETE NOW"); fflush(stdout)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: deleted.path) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("test script removed fixture file", !FileManager.default.fileExists(atPath: deleted.path))
        rescan()
        for _ in 0..<200 where isScanning || self.tree == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("Rescan removes deleted file", self.tree?.children.contains { self.tree?.path(of: $0) == deleted.path } == false)
        if let current = self.tree, let folder = current.children.first(where: { current.flags[Int($0)].contains(.isDir) }) {
            outline.expandItem(NSNumber(value: folder))
            selectNode(folder, fromMap: true); zoomIn(); await mapTask?.value
            let clip = outline.enclosingScrollView?.contentView
            clip?.scroll(to: NSPoint(x: 0, y: 300))
            let scrollBefore = clip?.bounds.origin.y ?? 0
            publishTree(current, final: true); await mapTask?.value
            check("phase update keeps selection and zoom", selectedNode == folder && zoomNode == folder)
            check("phase update keeps expansion", outline.isItemExpanded(NSNumber(value: folder)))
            check("bug: phase update loses outline scroll", scrollBefore > 0 && abs((clip?.bounds.origin.y ?? -1) - scrollBefore) < 2)
        } else { check("phase update fixture folder exists", false) }
        let otherFixture = URL(fileURLWithPath: rootPath).appendingPathComponent("nested").path
        startScan(rootPath)
        check("bug: unreadable banner clears on new scan", banner == nil)
        for _ in 0..<200 where (liveScan?.completedDirectories ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        sendKey(45, "n", .command)
        check("bug: Cmd-N during scan opens one sheet", startSheet != nil && window.attachedSheet === startSheet && isScanning)
        if startSheet != nil { sendKey(53, "\u{1b}") }
        check("bug: Escape from sheet does not cancel scan", startSheet == nil && isScanning)
        let oldScanWasActive = (liveScan?.completedDirectories ?? 0) > 0
        startScan(otherFixture)
        for _ in 0..<200 where isScanning || self.tree == nil { try? await Task.sleep(for: .milliseconds(50)) }
        check("bug: active rescan publishes stale first scan", oldScanWasActive && !isScanning && self.tree?.rootPath == otherFixture && self.tree?.children.contains(where: { self.tree?.path(of: $0).hasSuffix("other.png") == true }) == true && self.tree?.children.contains(where: { self.tree?.path(of: $0).hasSuffix("large.txt") == true }) == false)
        finishFailedScan(Scanner.ScanError.storageLimit, path: otherFixture, presentAlert: false)
        check("bug: shared file check error stays visible", summary.stringValue.contains("Shared file check failed:"))
        startScan(rootPath); cancelScan()
        check("Cancel action stops scan", !isScanning && status.stringValue.contains("cancelled"))
        startScan(rootPath)
        var workersActive = false
        for _ in 0..<200 {
            if let model = liveScan, model.completedDirectories > 1 && isScanning && self.tree == nil {
                workersActive = true
                cancelScan()
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check("bug: cancelling during live updates leaves stale rows", workersActive && liveScan == nil && outline.numberOfRows == 0 && mapView.layoutData == nil && !isScanning)
        startScan(rootPath)
        for _ in 0..<200 where liveScan == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let hadFailedLive = liveScan != nil
        scanTask?.cancel(); scanVersion += 1
        finishFailedScan(Scanner.ScanError.storageLimit, path: rootPath, presentAlert: false)
        let failedStatus = status.stringValue
        try? await Task.sleep(for: .milliseconds(350))
        check("bug: failed live scan keeps refreshing stale rows", hadFailedLive && liveScan == nil && liveTickTask == nil && outline.numberOfRows == 0 && !mapView.hasPreview && !isScanning && status.stringValue == failedStatus)
        print("e2e \(passed) passed, \(failed) failed")
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private func measureUI() async {
        guard let tree, let layout = mapView.layoutData else { NSApp.terminate(nil); return }
        print("tree column widths " + outline.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))" }.joined(separator: " "))
        print("type column widths " + types.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))" }.joined(separator: " "))
        let files = tree.parent.indices.filter { !tree.flags[$0].contains(.isDir) }
        let deepFile = files.max { left, right in
            func depth(_ id: Int) -> Int { var n = Int32(id), d = 0; while n > 0 { d += 1; n = tree.parent[Int(n)] }; return d }
            return depth(left) < depth(right)
        }.map(Int32.init) ?? 0
        let folder = tree.parent.indices.dropFirst().filter { tree.flags[$0].contains(.isDir) && tree.childCount[$0] > 0 }
            .max { tree.countedSize[$0] < tree.countedSize[$1] }.map(Int32.init)
        let type = tree.extensionIndex[Int(deepFile)] >= 0 ? tree.extensionIndex[Int(deepFile)] : nil
        func measure(_ name: String, target: Double, _ work: () -> Void) {
            var worst = 0.0
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                work()
                worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            print(String(format: "%@ %.3f ms worst of 20 (target %.0f ms)", name, worst, target))
        }
        var selectWorst = 0.0
        for _ in 0..<20 {
            outline.collapseItem(nil, collapseChildren: true)
            let start = DispatchTime.now().uptimeNanoseconds
            selectNode(deepFile, fromMap: true)
            selectWorst = max(selectWorst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print(String(format: "tree select, expand, scroll %.3f ms worst of 20 (target 16 ms)", selectWorst))
        measure("map frame update", target: 16) { mapView.selectedNode = deepFile }
        measure("hit test", target: 16) { _ = layout.hitTest(x: layout.width / 2, y: layout.height / 2) }
        measure("hover status update", target: 16) { hoveredNode = deepFile; updateStatus() }
        measure("type highlight shade", target: 16) {
            var pixels: [UInt8] = []
            Treemap.shade(layout, into: &pixels, params: Tokens.mapParams(dark: dark), highlightExtension: type)
        }
        let width = layout.width, height = layout.height, params = Tokens.mapParams(dark: dark)
        measure("full layout plus shade", target: 100) {
            let fresh = Treemap.layout(tree: tree, rootNode: zoomNode, widthPx: width, heightPx: height, params: params)
            var pixels: [UInt8] = []
            Treemap.shade(fresh, into: &pixels, params: params)
        }
        if let folder {
            var worst = 0.0
            for _ in 0..<20 {
                selectedNode = folder
                let startIn = DispatchTime.now().uptimeNanoseconds
                zoomIn()
                let inMS = Double(DispatchTime.now().uptimeNanoseconds - startIn) / 1_000_000
                await mapTask?.value
                let startOut = DispatchTime.now().uptimeNanoseconds
                zoomOut()
                let outMS = Double(DispatchTime.now().uptimeNanoseconds - startOut) / 1_000_000
                await mapTask?.value
                worst = max(worst, inMS + outMS)
            }
            print(String(format: "zoom in and back UI calls %.3f ms worst of 20 (target 16 ms; rendering measured separately)", worst))
        } else { print("zoom in and back unavailable: no folder with children") }
        fflush(stdout)
        NSApp.terminate(nil)
    }
    #endif
}

@main
struct MacDiskStatsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MacDiskStatsApp()
        app.delegate = delegate
        app.run()
    }
}
