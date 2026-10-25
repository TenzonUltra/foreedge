import AppKit
import PDFKit
import SwiftUI

@main enum TilingCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.regular)
        checkDirectionalGeometry()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Foreedge-tiling-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = Array(CommandLine.arguments.dropFirst())
        check(inputs.isEmpty || inputs.count == 2, "Pass either no paths or two read-only test PDFs")
        let urls = inputs.isEmpty ? [directory.appendingPathComponent("Geometry.pdf"), directory.appendingPathComponent("Topology.pdf")]
            : inputs.map { URL(fileURLWithPath: $0) }
        // User-supplied books are only opened; fixture generation stays inside the temporary directory.
        for url in inputs.isEmpty ? urls : [] {
            let doc = PDFDocument()
            for _ in 0..<80 { doc.insert(try BaselineDocument.make().page(at: 0)!, at: doc.pageCount) }
            check(doc.write(to: url), "Generate book")
        }
        let database = directory.appendingPathComponent("Library.sqlite")
        let context = LibraryContext(store: try LibraryStore(url: database))
        let workspace = WorkspaceSession(context: context)
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        workspace.reader.open(urls[0])
        check(await ready(workspace), "Initial book ready")
        let first = workspace.activePane
        first.reader.fitWidth()
        first.reader.go(to: 12); try await settle()
        let firstPosition = first.reader.captureLocation()!
        report(workspace, label: "1 pane")
        workspace.split(.horizontal)
        check(await ready(workspace), "Same book split ready")
        let second = workspace.activePane
        check(first.reader.book?.document === second.reader.book?.document, "Same-book panes share one native document")
        near(first.reader.captureLocation()!, firstPosition, "Splitting preserves original position")
        near(second.reader.captureLocation()!, firstPosition, "New split begins at the same position")
        second.reader.go(to: 35); try await settle()
        let secondPosition = second.reader.captureLocation()!
        near(first.reader.captureLocation()!, firstPosition, "Same-document scrolling is independent")
        second.reader.setMark("A")
        check(first.reader.visibleMarks.contains { $0.symbol == "A" }, "Marks are shared live")
        check(first.reader.backHistory.count != second.reader.backHistory.count, "Navigation histories are independent")
        let selected = second.reader.book!.document.page(at: 34)!.selection(for: NSRange(location: 0, length: 5))
        second.reader.pdfView?.setCurrentSelection(selected, animate: false)
        check(first.reader.pdfView?.currentSelection == nil, "Text selection is pane-local")
        report(workspace, label: "2 panes")
        let pdf = first.reader.pdfView!
        let point = pdf.convert(NSPoint(x: pdf.bounds.midX, y: 20), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
        }
        try await settle()
        check(workspace.activePaneID == first.id, "Clicking PDF content focuses its pane")
        ReaderCommand.page.run(in: workspace.reader)
        check(first.reader.panel == .page && second.reader.panel == nil, "Commands target clicked pane")
        first.reader.panel = nil; try await settle()
        workspace.cycleFocus()
        check(workspace.activePaneID == second.id, "Keyboard focus cycles in layout order")

        second.newTab(); second.reader.panel = nil; second.reader.open(urls[1])
        check(await ready(workspace), "New tab opens second book")
        second.reader.go(to: 51); try await settle()
        let topologyPosition = second.reader.captureLocation()!
        let topologyTab = second.activeTabID, geometryTab = second.tabs[0].id
        second.selectTab(geometryTab)
        check(await ready(workspace), "Tab restores original book")
        near(second.reader.captureLocation()!, secondPosition, "Tab keeps independent geometry position")
        second.selectTab(topologyTab)
        check(await ready(workspace), "Tab switches back")
        near(second.reader.captureLocation()!, topologyPosition, "Tab keeps topology position")
        workspace.split(.vertical); check(await ready(workspace), "Third pane")
        workspace.focus(first.id); workspace.split(.vertical); check(await ready(workspace), "Fourth pane")
        workspace.split(.horizontal); check(workspace.panes.count == 4, "Four-pane cap")
        report(workspace, label: "4 panes")
        for pane in workspace.panes {
            let view = pane.reader.pdfView!
            let scroll = view.documentView!.enclosingScrollView!
            check(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller, "PDF scrollbars remain hidden after splitting")
            let expected = workspace.layout.frames(in: host.bounds).first { $0.id == pane.id }!.rect
            let actual = view.convert(view.bounds, to: host)
            let top = host.isFlipped ? actual.minY : host.bounds.height - actual.maxY
            check(abs(actual.width - expected.width) < 1 && abs(actual.minX - expected.minX) < 1, "Tile widths and divider positions match layout geometry")
            let topInset = top - expected.minY
            if pane.tabs.count > 1 {
                check(topInset >= 30 && topInset <= 32, "Multiple tabs show only a tab strip")
            } else {
                check(abs(topInset) < 1, "Single-book panes have no header or reserved header space")
            }
        }
        // Width fitting follows geometry; manual zoom keeps its chosen scale.
        let autoReader = workspace.panes.first { $0.id != first.id && $0.id != second.id }!.reader
        autoReader.pdfView!.autoScales = true
        let manualView = second.reader.pdfView!
        manualView.autoScales = false; manualView.scaleFactor *= 1.15
        try await settle()
        check(autoReader.captureLocation()?.fit == "auto", "Native automatic fit remains available")
        let manualScale = manualView.scaleFactor
        let resizePositions = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0.reader.captureLocation()!) })
        let resizeHistories = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0.reader.backHistory.count) })
        if case .split(let id, _, _, _, _) = workspace.layout {
            for ratio in [0.62, 0.5] {
                workspace.resize(id, ratio: ratio); try await settle()
                checkWidthFit(first.reader)
                check(abs(manualView.scaleFactor - manualScale) < 0.001, "Pane resize preserves manual zoom")
                for pane in workspace.panes {
                    near(pane.reader.captureLocation()!, resizePositions[pane.id]!, "Divider resize preserves reading anchor")
                    check(pane.reader.backHistory.count == resizeHistories[pane.id], "Resizing adds no navigation history")
                }
            }
        }
        for size in [NSSize(width: 1080, height: 820), NSSize(width: 1200, height: 900)] {
            window.setContentSize(size); try await settle()
            checkWidthFit(first.reader)
            check(abs(manualView.scaleFactor - manualScale) < 0.001, "Window resize preserves manual zoom")
            for pane in workspace.panes { near(pane.reader.captureLocation()!, resizePositions[pane.id]!, "Window resize preserves reading anchor") }
        }
        let positions = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0.reader.captureLocation()!) })
        let histories = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0.reader.backHistory.count) })
        workspace.toggleMaximized(); check(await ready(workspace, visibleOnly: true), "Maximize")
        workspace.cycleFocus(); check(await ready(workspace, visibleOnly: true), "Cycle focus while maximized")
        workspace.cycleFocus(-1); check(await ready(workspace, visibleOnly: true), "Return to maximized pane")
        workspace.toggleMaximized(); check(await ready(workspace), "Restore layout")
        for pane in workspace.panes { near(pane.reader.captureLocation()!, positions[pane.id]!, "Maximize preserves all positions") }
        let moving = workspace.activePaneID
        let adjacent = workspace.neighbor(.right)!
        let targetRect = workspace.layout.frames(in: host.bounds).first { $0.id == adjacent }!.rect
        ReaderCommand.focusRight.run(in: workspace.reader)
        check(workspace.activePaneID == adjacent, "Directional command focuses the pane to the right")
        ReaderCommand.focusLeft.run(in: workspace.reader)
        check(workspace.activePaneID == moving, "Directional focus returns to the left pane")
        ReaderCommand.moveRight.run(in: workspace.reader)
        check(await ready(workspace), "Directional swap")
        check(workspace.activePaneID == moving, "Focus follows the moved pane")
        check(workspace.layout.frames(in: host.bounds).first { $0.id == moving }!.rect == targetRect, "Swap places the pane in its right-hand neighbor's slot")
        let edgeLayout = workspace.layout
        ReaderCommand.moveRight.run(in: workspace.reader)
        check(workspace.layout == edgeLayout, "Directional move stops at the outer edge")
        for pane in workspace.panes { near(pane.reader.captureLocation()!, positions[pane.id]!, "Moving preserves all positions") }
        if case .split(let id, _, _, _, _) = workspace.layout { workspace.resize(id, ratio: 0.6) }
        try await settle()
        let collection = workspace.reader.createCollection("Seminar")!
        let firstWorkspaceID = workspace.activeWorkspaceID
        workspace.flush()
        let savedLayout = workspace.layout
        check(workspace.createWorkspace("Second desk"), "Create workspace")
        check(workspace.panes.count == 1 && workspace.reader.book == nil, "New workspace is empty")
        workspace.context.selectScope("all")
        workspace.reader.open(urls[1]); check(await ready(workspace), "Second workspace book")
        workspace.reader.go(to: 7); try await settle()
        workspace.switchWorkspace(firstWorkspaceID); check(await ready(workspace), "Restore saved desk")
        check(workspace.panes.count == 4 && workspace.layout == savedLayout, "Workspace restores split tree and ratio")
        let geometryReaders = workspace.panes.filter { $0.reader.recordID == firstPosition.bookID }
        check(geometryReaders.allSatisfy { $0.reader.book?.document === geometryReaders.first?.reader.book?.document }, "Concurrent restore deduplicates native document loading")
        check(workspace.context.activeScope == "collection:\(collection)", "Workspace restores collection scope")
        for pane in workspace.panes {
            check(pane.reader.backHistory.count == histories[pane.id], "Workspace restores per-pane history")
            check(pane.reader.currentRecord?.id == positions[pane.id]?.bookID, "Workspace restores book identity")
        }
        check(workspace.panes.first { $0.id == second.id }?.tabs.count == 2, "Workspace restores tabs")
        workspace.flush()
        let restartPositions = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0.reader.captureLocation()!) })
        workspace.panes.forEach { $0.reader.prepareForReattachment() }
        let restored = WorkspaceSession(context: LibraryContext(store: try LibraryStore(url: database)))
        check(restored.panes.count == 4 && restored.layout == savedLayout && restored.activePaneID == workspace.activePaneID, "Restart restores layout and focus")
        check(restored.context.library.marks.contains { $0.symbol == "A" }, "Restart preserves marks")
        check(restored.context.library.workspaces.count == 2, "Both named workspaces persist")
        host.rootView = WorkspaceView(workspace: restored)
        check(await ready(restored), "Restart reattaches native PDF views")
        for pane in restored.panes { near(pane.reader.captureLocation()!, restartPositions[pane.id]!, "Restart restores actual viewport") }
        ReaderCommand.palette.run(in: restored.reader); try await settle()
        ReaderCommand.workspaces.run(in: restored.reader); try await settle()
        check(window.attachedSheet != nil && restored.reader.panel == .workspaces, "Palette transitions to workspace picker")
        restored.reader.panel = nil; try await settle()
        check(restored.renameWorkspace(restored.activeWorkspaceID, to: "Renamed desk"), "Rename workspace")
        check(!restored.createWorkspace("Renamed desk"), "Reject duplicate workspace name")
        if let other = restored.context.library.workspaces.first(where: { $0.id != restored.activeWorkspaceID }) { restored.deleteWorkspace(other.id) }
        check(restored.context.library.workspaces.count == 1 && restored.context.library.books.count == 2, "Delete workspace keeps books")
        restored.panes.forEach { $0.reader.suspend() }
        host.rootView = WorkspaceView(workspace: workspace)
        check(await ready(workspace), "Reattach original test workspace")
        workspace.focus(second.id); workspace.activePane.closeTab(); check(await ready(workspace), "Close active tab")
        check(workspace.activePane.tabs.count == 1, "Closing tab preserves another tab")
        workspace.closePane(); check(await ready(workspace), "Close pane")
        check(workspace.panes.count == 3 && workspace.context.documentPool.activeCount == 3, "Closing pane releases active document lease")
        workspace.flush()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/tiling-check/layout.png"))
        }

        // The serial actor's shared revision/page cache deduplicates same-page requests.
        let worker = PaperWorker()
        let a = UUID(), b = UUID()
        let textureA = try await worker.adaptive(source: .file(urls[0]), documentID: a, pageIndex: 0, resourceKey: "revision")
        let textureB = try await worker.adaptive(source: .file(urls[0]), documentID: b, pageIndex: 0, resourceKey: "revision")
        check(textureA.field(for: .adaptive).image === textureB.field(for: .adaptive).image, "Adaptive images shared between panes")
        check(await worker.generatedPageCount == 1, "Duplicate page computed once")
        await worker.releaseDocument(a)
        check(await worker.cachedDocumentCount == 1, "One pane closing retains another pane's worker document")
        for page in 1...14 { _ = try await worker.adaptive(source: .file(urls[0]), documentID: b, pageIndex: page, resourceKey: "revision") }
        check(await worker.cachedPageCount == PaperWorker.pageLimit, "Global adaptive cache bounded")
        await worker.releaseDocument(b)
        let remainingDocuments = await worker.cachedDocumentCount, remainingPages = await worker.cachedPageCount
        check(remainingDocuments == 0 && remainingPages == 0, "Last pane releases worker resources")
        print("Tiling checks passed: shared documents with independent viewports/selections/history, tabs, four-pane cap, maximize/move/resize, collections per workspace, persistence, resource release, and shared adaptive work.")
    }
    @MainActor static func checkWidthFit(_ reader: ReaderSession) {
        let view = reader.pdfView!, page = view.currentPage!
        let box = page.bounds(for: view.displayBox)
        let width = page.rotation % 180 == 0 ? box.width : box.height
        check(abs(width * view.scaleFactor - (view.bounds.width - 32)) < 1, "Fit width follows pane geometry")
        check(reader.captureLocation()?.fit == "width", "Resizing retains width-fit mode")
    }
    static func checkDirectionalGeometry() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let grid = PaneLayout.split(id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: .pane(a), second: .pane(b)),
            second: .split(id: UUID(), axis: .vertical, ratio: 0.5, first: .pane(c), second: .pane(d)))
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)
        check(grid.neighbor(of: a, toward: .right, in: bounds) == c, "Grid right neighbor")
        check(grid.neighbor(of: a, toward: .down, in: bounds) == b, "Grid down neighbor")
        check(grid.neighbor(of: d, toward: .left, in: bounds) == b, "Grid left neighbor")
        check(grid.neighbor(of: d, toward: .up, in: bounds) == c, "Grid up neighbor")
        check(grid.neighbor(of: a, toward: .left, in: bounds) == nil && grid.neighbor(of: a, toward: .up, in: bounds) == nil, "No wrap at edges")
        let unequal = PaneLayout.split(id: UUID(), axis: .horizontal, ratio: 0.4, first: .pane(a),
            second: .split(id: UUID(), axis: .vertical, ratio: 0.3, first: .pane(c), second: .pane(d)))
        check(unequal.neighbor(of: a, toward: .right, in: bounds) == d, "Unequal split prefers center-aligned neighbor")
        check(unequal.neighbor(of: c, toward: .left, in: bounds) == a, "Short pane finds tall neighbor")
    }
    @MainActor static func ready(_ workspace: WorkspaceSession, visibleOnly: Bool = false) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        let panes = visibleOnly ? [workspace.activePane] : workspace.panes
        while !panes.allSatisfy({ !$0.reader.isOpening && $0.reader.book != nil && $0.reader.captureLocation() != nil && $0.reader.pdfView?.window != nil }) {
            if Date() > deadline { return false }; try? await settle()
        }
        try? await settle(); return true
    }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
    @MainActor static func report(_ workspace: WorkspaceSession, label: String) {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        let start = ProcessInfo.processInfo.systemUptime
        for pane in workspace.panes {
            guard let location = pane.reader.captureLocation(), let view = pane.reader.pdfView as? ReaderPDFView,
                  let page = view.document?.page(at: min(location.page + 1, 79)) else { continue }
            let callback = view.onWillNavigate; view.onWillNavigate = {}
            view.go(to: page); pane.reader.navigate(location, recordHistory: false)
            view.onWillNavigate = callback
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("\(label): resident \(result == KERN_SUCCESS ? Int(info.resident_size / 1024 / 1024) : -1) MiB; synchronous jump + return across panes \(String(format: "%.2f", elapsed)) ms (not frame latency)")
    }
    static func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    static func near(_ a: BookLocation, _ b: BookLocation, _ message: String) {
        check(a.bookID == b.bookID && a.page == b.page && abs(a.y - b.y) < 0.03, "\(message): page \(a.page)/\(b.page), y \(a.y)/\(b.y)")
    }
}
