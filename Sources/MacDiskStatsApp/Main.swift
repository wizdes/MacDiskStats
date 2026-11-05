import AppKit
import DiskCore
import QuickLookUI

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
    private var progress: NSProgressIndicator!
    private var banner: NSView?
    private var tree: FileTree?
    private var rootPath: String?
    private var zoomNode: Int32 = 0
    private var selectedNode: Int32?
    private var hoveredNode: Int32?
    private var highlightedType: Int32?
    private var scanTask: Task<Void, Never>?
    private var mapTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var renderVersion = 0
    private var renderedRoot: Int32 = -1
    private var selecting = false
    private var topWindow: NSWindow?
    private var topTable: NSTableView?
    private var topIDs: [Int32] = []
    private var isScanning = false
    private var checkingSharedFiles = false
    private var bannerDismissed = false
    private var pendingSelect: String?
    private var snapshotPath: String?
    private var snapshotAppearance: String?
    private var volumeFreeBytes: Int64 = 0
    private let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    private let fileIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    #if DEBUG
    private var measurePending = false
    #endif
    private var dark: Bool { window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.isScanning == true { self?.cancelScan(); return nil }
            if event.modifierFlags.contains(.command) && event.keyCode == 126 { self?.zoomOut(); return nil }
            if event.modifierFlags.contains(.command) && event.keyCode == 36 { self?.zoomIn(); return nil }
            if event.keyCode == 49 && !event.modifierFlags.contains(.command) && self?.selectedNode != nil { self?.quickLook(); return nil }
            return event
        }
        content = NSView(frame: NSRect(origin: .zero, size: Tokens.windowSize))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Tokens.windowSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MacDiskStats"
        window.minSize = NSSize(width: Tokens.minTreeWidth + Tokens.minTypesWidth, height: Tokens.minTopHeight + Tokens.minMapHeight + Tokens.statusHeight)
        window.center()
        window.delegate = self
        window.contentView = content
        if let snapshotAppearance { window.appearance = NSAppearance(named: snapshotAppearance == "dark" ? .darkAqua : .aqua) }
        showStart()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let rootPath { startScan(rootPath) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowDidResize(_ notification: Notification) { scheduleMapRender() }
    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleMapRender() }
    func windowDidChangeEffectiveAppearance(_ notification: Notification) { refreshAppearance() }

    private func parseArguments() {
        let args = CommandLine.arguments
        for i in args.indices {
            #if DEBUG
            if args[i] == "--measure" { measurePending = true; continue }
            #endif
            guard i + 1 < args.count else { continue }
            switch args[i] {
            case "--scan": rootPath = args[i + 1]
            case "--select": pendingSelect = args[i + 1]
            case "--snapshot": snapshotPath = args[i + 1]
            case "--appearance": snapshotAppearance = args[i + 1]
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

    private func showStart() {
        scanView?.removeFromSuperview(); scanView = nil
        startView?.removeFromSuperview()
        let view = NSView(frame: content.bounds); view.autoresizingMask = [.width, .height]
        view.wantsLayer = true; view.layer?.backgroundColor = Tokens.background(dark).cgColor
        content.addSubview(view); startView = view
        let title = label("Choose a disk to scan", font: Tokens.startTitleFont, color: Tokens.text(dark))
        title.frame = NSRect(x: Tokens.inset, y: view.bounds.height - Tokens.startTopInset, width: Tokens.startWidth, height: Tokens.startSpacing * 2)
        title.autoresizingMask = [.minYMargin]; view.addSubview(title)
        let note = label("MacDiskStats reads file names and sizes. It never changes your files.", font: Tokens.startDetailFont, color: Tokens.muted(dark))
        note.frame = NSRect(x: Tokens.inset, y: title.frame.minY - Tokens.startSpacing * 2, width: Tokens.startWidth, height: Tokens.startSpacing * 2)
        note.autoresizingMask = [.minYMargin]; view.addSubview(note)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey], options: [.skipHiddenVolumes]) ?? []
        var y = note.frame.minY - Tokens.startSpacing - Tokens.startRowHeight
        for url in volumes {
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let name = values?.volumeName ?? url.lastPathComponent
            let detail: String
            if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity {
                detail = "\(format(max(0, Int64(total - free)))) used · \(format(Int64(free))) free"
            } else { detail = "size unavailable" }
            let button = NSButton(title: "\(name)   \(detail)", target: self, action: #selector(startVolume(_:)))
            button.bezelStyle = .rounded; button.alignment = .left; button.font = Tokens.bodyFont
            button.identifier = NSUserInterfaceItemIdentifier(url.path)
            button.frame = NSRect(x: Tokens.inset, y: y, width: Tokens.startWidth, height: Tokens.startRowHeight)
            button.autoresizingMask = [.minYMargin]; view.addSubview(button)
            y -= Tokens.startRowHeight + Tokens.startSpacing
        }
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded; choose.font = Tokens.bodyFont
        choose.frame = NSRect(x: Tokens.inset, y: y, width: Tokens.startWidth, height: Tokens.startRowHeight)
        choose.autoresizingMask = [.minYMargin]; view.addSubview(choose)
    }
    @objc private func startVolume(_ sender: NSButton) { if let path = sender.identifier?.rawValue { startScan(path) } }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.startScan(path)
        }
    }

    private func buildScanView() {
        startView?.removeFromSuperview(); startView = nil
        scanView?.removeFromSuperview()
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
            c.headerCell.font = Tokens.headerFont
            if name != "Type" { c.headerCell.alignment = .right }
            types.addTableColumn(c)
        }
        typeScroll.documentView = types
        let panes = PaneLayoutView(frame: NSRect(x: 0, y: Tokens.statusHeight, width: host.bounds.width, height: host.bounds.height - Tokens.statusHeight), tree: treeScroll, types: typeScroll, map: map)
        panes.autoresizingMask = [.width, .height]
        host.addSubview(panes)
        panes.layoutSubtreeIfNeeded()
        progress = NSProgressIndicator(frame: NSRect(x: Tokens.inset, y: Tokens.statusHeight, width: host.bounds.width - Tokens.inset * 2, height: Tokens.statusHeight))
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        progress.autoresizingMask = [.width, .maxYMargin]; host.addSubview(progress)
        map.dark = dark
        if snapshotPath != nil {
            window.setContentSize(Tokens.snapshotSize)
            panes.layoutSubtreeIfNeeded()
        }
        refreshAppearance()
    }

    private func startScan(_ path: String) {
        scanTask?.cancel(); mapTask?.cancel()
        tree = nil; checkingSharedFiles = false; rootPath = path; zoomNode = 0; selectedNode = nil; highlightedType = nil; bannerDismissed = false
        let rootURL = URL(fileURLWithPath: path)
        do {
            let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            volumeFreeBytes = Int64(values.volumeAvailableCapacity ?? -1)
        } catch {
            volumeFreeBytes = -1
            showError("Could not read free space for \(path): \(error.localizedDescription)")
        }
        buildScanView(); isScanning = true
        window.title = "MacDiskStats — \(URL(fileURLWithPath: path).lastPathComponent)"
        status.stringValue = "Scanning \(path)…"
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Scanner.scan(root: path, progress: { [weak self] report in
                    Task { @MainActor [weak self] in self?.showProgress(report) }
                }, phase1: { [weak self] snapshot in self?.publishTree(snapshot, final: false) })
                guard !Task.isCancelled else { return }
                self.publishTree(result, final: true)
            } catch {
                if Task.isCancelled { return }
                self.isScanning = false
                self.checkingSharedFiles = false
                self.progress.stopAnimation(nil); self.progress.isHidden = true
                self.status.stringValue = self.tree == nil ? "Scan failed: \(error.localizedDescription)" : "Shared file check failed: \(error.localizedDescription)"
                self.showError("Could not scan \(path): \(error.localizedDescription)")
                self.makeSnapshotIfNeeded()
            }
        }
    }
    private func publishTree(_ result: FileTree, final: Bool) {
        let previous = tree
        var expanded: [Int32] = []
        var scrollPoint: NSPoint?
        if previous != nil {
            scrollPoint = outline.enclosingScrollView?.contentView.bounds.origin
            for row in 0..<outline.numberOfRows {
                if let item = outline.item(atRow: row) as? NSNumber, outline.isItemExpanded(item) { expanded.append(item.int32Value) }
            }
        }
        let selectedType = highlightedType.flatMap { id in previous.flatMap { old in Int(id) < old.extensions.count ? old.extensions[Int(id)].name : nil } }
        tree = result; checkingSharedFiles = !final; isScanning = !final
        progress.stopAnimation(nil); progress.isHidden = true
        outline.headerView?.toolTip = final ? "At least this much space comes back if you delete this." : "Frees is still being calculated."
        selecting = true
        outline.reloadData()
        for id in expanded { outline.expandItem(NSNumber(value: id), expandChildren: false) }
        if let selectedNode {
            let row = outline.row(forItem: NSNumber(value: selectedNode))
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        if let scrollPoint { outline.enclosingScrollView?.contentView.scroll(to: scrollPoint) }
        selecting = false
        types.reloadData()
        if let selectedType, let newIndex = result.extensions.firstIndex(where: { $0.name == selectedType }) {
            highlightedType = Int32(newIndex)
            types.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        }
        if let topTable {
            topIDs = result.largestFiles
            topTable.reloadData()
            if let selectedNode, let row = topIDs.firstIndex(of: selectedNode) {
                topTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        updateStatus(); updateBanner()
        if let pending = pendingSelect { selectPath(pending); pendingSelect = nil }
        renderMap()
    }
    private func showProgress(_ report: ScanProgress) {
        guard isScanning, tree == nil else { return }
        status.stringValue = "Scanning… \(report.filesSeen.formatted()) files · \(format(report.bytesCounted)) counted"
        if let rootPath { mapView.showPreview(report.firstTwoLevels, root: rootPath) }
    }
    @objc private func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel(); isScanning = false; checkingSharedFiles = false
        progress.stopAnimation(nil); progress.isHidden = true
        status.stringValue = "Scan cancelled. Choose a folder to scan again."
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
        guard let tree, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        mapTask?.cancel(); renderVersion += 1
        let version = renderVersion
        let scale = window.backingScaleFactor
        let width = Int((mapView.bounds.width * scale).rounded()), height = Int((mapView.bounds.height * scale).rounded())
        let root = zoomNode, highlight = highlightedType, params = Tokens.mapParams(dark: dark)
        let existing = shadeOnly && renderedRoot == root && mapView.layoutData?.width == width && mapView.layoutData?.height == height ? mapView.layoutData : nil
        mapTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> (TreemapLayout, [UInt8]) in
                let layout = existing ?? Treemap.layout(tree: tree, rootNode: root, widthPx: width, heightPx: height, params: params)
                var rgba: [UInt8] = []
                Treemap.shade(layout, into: &rgba, params: params, highlightExtension: highlight)
                return (layout, rgba)
            }.value
            guard let self, version == self.renderVersion else { return }
            self.mapView.layoutData = rendered.0
            self.renderedRoot = root
            self.mapView.show(rendered.1, width: width, height: height)
            self.mapView.selectedNode = self.selectedNode
            self.makeSnapshotIfNeeded()
            #if DEBUG
            if self.measurePending {
                self.measurePending = false
                Task { await self.measureUI() }
            }
            #endif
        }
    }

    private func selectNode(_ id: Int32, fromMap: Bool = false) {
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
        guard let tree else { return 0 }
        let id = item == nil ? 0 : Int((item as? NSNumber)?.int32Value ?? 0)
        return Int(tree.childCount[id])
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let id = item == nil ? 0 : Int((item as? NSNumber)?.int32Value ?? 0)
        let tree = tree!
        return NSNumber(value: tree.children[Int(tree.firstChild[id]) + index])
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tree, let id = (item as? NSNumber)?.int32Value else { return false }
        return tree.flags[Int(id)].contains(.isDir) && tree.childCount[Int(id)] > 0
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tree, let id = (item as? NSNumber)?.int32Value, let column = tableColumn else { return nil }
        let kind = column.identifier.rawValue
        let cell = cellView(in: outlineView, key: kind, right: kind != "Name")
        let n = Int(id)
        switch kind {
        case "Name":
            let a = Int(tree.nameOffset[n]), b = a + Int(tree.nameLength[n])
            let name = String(decoding: tree.names[a..<b], as: UTF8.self)
            cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "\(name)  unreadable" : name
            cell.textField?.font = tree.flags[n].contains(.unreadable) ? Tokens.unreadableFont : Tokens.bodyFont
            cell.imageView?.image = tree.flags[n].contains(.isDir) ? folderIcon : fileIcon
        case "Size": cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "unreadable" : format(tree.countedSize[n])
        case "Frees": cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "unreadable" : (checkingSharedFiles ? "–" : format(tree.privateSize[n]))
        default:
            let root = max(1, tree.countedSize[0]); cell.textField?.stringValue = tree.flags[n].contains(.unreadable) ? "unreadable" : String(format: "%.1f%%", Double(tree.countedSize[n]) / Double(root) * 100)
        }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let item = outline.item(atRow: outline.selectedRow) as? NSNumber else { return }
        selectNode(item.int32Value)
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === types { return tree?.extensions.count ?? 0 }
        if tableView === topTable { return topIDs.count }
        return 0
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let tree else { return nil }
        let kind = column.identifier.rawValue
        let cell = cellView(in: tableView, key: kind, right: kind == "Size" || kind == "%")
        if tableView === types {
            let ext = tree.extensions[row]
            switch kind {
            case "Type":
                cell.textField?.stringValue = ext.name.isEmpty ? "(no extension)" : ".\(ext.name)"
                cell.imageView?.image = swatch(row)
            case "Size": cell.textField?.stringValue = format(ext.bytes)
            default: cell.textField?.stringValue = String(format: "%.1f%%", Double(ext.bytes) / Double(max(1, tree.countedSize[0])) * 100)
            }
        } else if tableView === topTable {
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
    private func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        return byteFormatter.string(fromByteCount: bytes)
    }
    private func updateStatus() {
        guard let tree, status != nil else { return }
        let suffix = checkingSharedFiles ? " · checking shared files…" : ""
        if let id = hoveredNode ?? selectedNode {
            let size = tree.flags[Int(id)].contains(.unreadable) ? "unreadable" : format(tree.countedSize[Int(id)])
            status.stringValue = "\(tree.path(of: id)) · \(size)" + suffix
        } else {
            let isVolumeRoot = tree.rootPath == "/" || tree.rootPath == "/System/Volumes/Data"
            let used = isVolumeRoot ? tree.volumeUsedBytes : tree.countedSize[0]
            let free = volumeFreeBytes
            let gap = isVolumeRoot ? max(0, tree.volumeUsedBytes - tree.countedSize[0]) : 0
            let freeText = free < 0 ? "free unavailable" : "\(format(free)) free"
            if isVolumeRoot {
                status.stringValue = "\(format(used)) used · \(freeText) · \(format(gap)) not counted · \(tree.unreadablePaths.count) folders unreadable" + suffix
            } else {
                let unreadable = tree.unreadablePaths.count
                status.stringValue = "\(format(tree.countedSize[0])) in this folder · \(freeText) on disk" + (unreadable > 0 ? " · \(unreadable) folders unreadable" : "") + suffix
            }
        }
    }
    private func updateBanner() {
        banner?.removeFromSuperview(); banner = nil
        guard let tree, !tree.unreadablePaths.isEmpty, !bannerDismissed, let host = scanView else { return }
        let row = NSView(frame: NSRect(x: 0, y: Tokens.statusHeight, width: host.bounds.width, height: Tokens.bannerHeight))
        row.autoresizingMask = [.width, .maxYMargin]; row.wantsLayer = true; row.layer?.backgroundColor = Tokens.secondary(dark).cgColor
        let text = label("Some folders could not be read. The map leaves out their contents.", font: Tokens.statusFont, color: Tokens.text(dark))
        text.frame = NSRect(x: Tokens.inset, y: 0, width: row.bounds.width * Tokens.bannerTextFraction, height: Tokens.bannerHeight)
        text.autoresizingMask = [.width]; row.addSubview(text)
        let settings = NSButton(title: "Full Disk Access", target: self, action: #selector(openFullDiskAccess))
        settings.bezelStyle = .inline; settings.font = Tokens.statusFont
        settings.frame = NSRect(x: row.bounds.width - Tokens.bannerActionWidth - Tokens.bannerCloseWidth, y: 0, width: Tokens.bannerActionWidth, height: Tokens.bannerHeight)
        settings.autoresizingMask = [.minXMargin]; row.addSubview(settings)
        let close = NSButton(title: "×", target: self, action: #selector(dismissBanner))
        close.bezelStyle = .inline; close.frame = NSRect(x: row.bounds.width - Tokens.bannerCloseWidth, y: 0, width: Tokens.bannerCloseWidth, height: Tokens.bannerHeight)
        close.autoresizingMask = [.minXMargin]; row.addSubview(close)
        host.addSubview(row); banner = row
    }
    @objc private func dismissBanner() { bannerDismissed = true; banner?.removeFromSuperview(); banner = nil }
    @objc private func openFullDiskAccess() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    private func refreshAppearance() {
        guard scanView != nil else { return }
        mapView?.dark = dark
        status?.textColor = Tokens.muted(dark)
        scanView?.wantsLayer = true; scanView?.layer?.backgroundColor = Tokens.background(dark).cgColor
        outline?.reloadData(); types?.reloadData(); updateBanner(); renderMap()
    }

    @objc private func zoomIn() {
        guard let tree, let selectedNode, tree.flags[Int(selectedNode)].contains(.isDir) else { return }
        zoomNode = selectedNode; window.title = "MacDiskStats — \(tree.path(of: zoomNode))"; renderMap()
    }
    @objc private func zoomOut() {
        guard let tree, zoomNode != 0 else { return }
        zoomNode = tree.parent[Int(zoomNode)]; window.title = "MacDiskStats — \(tree.path(of: zoomNode))"; renderMap()
    }
    @objc private func zoomTop() { guard let tree else { return }; zoomNode = 0; window.title = "MacDiskStats — \(tree.rootPath)"; renderMap() }
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
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tree.path(of: selectedNode))])
    }
    @objc private func copyPath() {
        guard let tree, let selectedNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tree.path(of: selectedNode), forType: .string)
    }
    @objc private func quickLook() {
        guard selectedNode != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.delegate = self; panel.makeKeyAndOrderFront(nil); panel.reloadData()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedNode == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let tree, let selectedNode else { return nil }
        return URL(fileURLWithPath: tree.path(of: selectedNode)) as NSURL
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
            DebugSnapshot.capture(window: window, path: snapshotPath)
        }
        #endif
    }

    #if DEBUG
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
