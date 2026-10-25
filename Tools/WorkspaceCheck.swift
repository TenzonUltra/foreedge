import AppKit
import PDFKit
import SwiftUI

@main
enum WorkspaceCheck {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/workspace-check", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let url = run.appendingPathComponent("study.pdf")
        let document = PDFDocument()
        for _ in 0..<12 { document.insert(try BaselineDocument.make().page(at: 0)!, at: document.pageCount) }
        let root = PDFOutline()
        let chapter = PDFOutline(); chapter.label = "Chapter Six"; chapter.destination = PDFDestination(page: document.page(at: 5)!, at: CGPoint(x: 0, y: 700))
        root.insertChild(chapter, at: 0); document.outlineRoot = root
        require(document.write(to: url), "Write fixture")
        let store = try LibraryStore(url: run.appendingPathComponent("Library.sqlite"))
        let session = ReaderSession(store: store)
        session.open(url)
        let opened = await wait { !session.isOpening }
        require(opened, "Open fixture")
        require(session.book?.document.outlineRoot?.child(at: 0)?.label == "Chapter Six", "Embedded outline retained")
        let persistentID = session.currentRecord!.id
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 820, height: 900))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .mediaBox
        session.pdfView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        attach(session, view)
        require(await wait { !view.visiblePages.isEmpty }, "Visible document")
        session.go(to: 6)
        session.fitWidth()
        view.go(to: PDFDestination(page: documentPage(session, 5), at: CGPoint(x: 0, y: 550)))
        let sixth = session.captureLocation()!
        require(sixth.page == 5, "Capture page six")
        session.setMark("a"); session.setMark("G")
        let historyBefore = session.library.back.count
        session.go(to: 10)
        require(session.library.back.count == historyBefore + 1, "One history entry per jump, including native callback")
        session.back()
        assertNear(session.captureLocation()!, sixth, "Back restores viewport")
        session.forward()
        require(session.captureLocation()!.page == 9, "Forward restores page ten")
        session.jumpMark("a")
        assertNear(session.captureLocation()!, sixth, "Mark restores viewport")
        session.go(to: 3); session.back(); session.go(to: 8)
        require(!session.canGoForward, "A new jump discards forward history")
        let beforeScroll = session.library.back.count
        view.scrollLineDown(nil); session.viewportChanged()
        require(session.library.back.count == beforeScroll, "Scrolling does not append history")
        session.go(toLabel: "#6")
        require(session.captureLocation()!.page == 5, "Physical page syntax")
        session.appearance.warmth = 0.37
        session.vimEnabled = true
        session.flush()
        let saved = session.captureLocation()!
        let reloaded = ReaderSession(store: try LibraryStore(url: run.appendingPathComponent("Library.sqlite")), restore: true)
        require(await wait { !reloaded.isOpening }, "Restore last book")
        require(reloaded.currentRecord?.id == persistentID, "Stable identity across restart")
        reloaded.pdfView = view; attach(reloaded, view)
        assertNear(reloaded.captureLocation()!, saved, "Restart restores viewport")
        require(reloaded.appearance.warmth == 0.37 && reloaded.vimEnabled, "Appearance and keyboard preferences survive restart")
        require(reloaded.visibleMarks.count == 2, "Local and global marks survive restart")
        reloaded.go(to: 11); reloaded.jumpMark("a")
        assertNear(reloaded.captureLocation()!, sixth, "Persisted mark resolves")

        // A failed open leaves the active book and history intact.
        let backCount = reloaded.library.back.count
        reloaded.open(run.appendingPathComponent("missing.pdf"))
        require(await wait { !reloaded.isOpening }, "Failed open completes")
        require(reloaded.currentRecord?.id == persistentID && reloaded.library.back.count == backCount, "Failed open preserves identity/history")
        reloaded.errorMessage = nil

        // Indexed whole-word matching returns ranges that resolve in the display document.
        reloaded.search.start("page", source: reloaded.book!.source)
        require(await wait { !reloaded.search.isSearching }, "Search completes")
        require(!reloaded.search.hits.isEmpty, "Search finds fixture text")
        let hit = reloaded.search.hits[0]
        let selection = reloaded.book!.document.page(at: hit.page)!.selection(for: NSRange(location: hit.offset, length: hit.length))!
        require(selection.string?.lowercased() == "page", "Search ranges map to native selections")
        reloaded.search.start("page", source: reloaded.book!.source)
        reloaded.search.start("qzxxnonexistent", source: reloaded.book!.source)
        require(await wait { !reloaded.search.isSearching }, "Newer search completes")
        require(reloaded.search.hits.isEmpty, "Stale search results rejected")
        require(fuzzyScore("ctnts", in: "Table of Contents") != nil && fuzzyScore("xyz", in: "Table of Contents") == nil, "Fuzzy command matching")
        require(ReaderCommand.contents.enabled(in: reloaded), "Command enabled with a document")
        ReaderCommand.contents.run(in: reloaded)
        require(reloaded.panel == .contents, "Command registry dispatch")
        reloaded.panel = nil

        // Move a file and open its new URL: bookmark identity reconnects it.
        let moved = run.appendingPathComponent("renamed.pdf")
        try FileManager.default.moveItem(at: url, to: moved)
        reloaded.open(moved)
        require(await wait { !reloaded.isOpening }, "Open moved PDF")
        require(reloaded.currentRecord?.id == persistentID && reloaded.library.books.count == 1, "File move retains identity")
        attach(reloaded, view)

        let key: (String, NSEvent.ModifierFlags) -> NSEvent = { text, modifiers in
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
        }
        require(reloaded.handleKey(key("m", [])) && reloaded.handleKey(key("b", [])), "Vim mark sequence handled")
        require(reloaded.visibleMarks.contains { $0.symbol == "b" }, "Vim sequence sets local mark")
        reloaded.panel = .find
        require(!reloaded.handleKey(key("m", [])), "Vim does not consume panel typing")
        reloaded.panel = nil
        require(!reloaded.handleKey(key("m", [.command])), "Vim does not consume native shortcuts")
        if let mark = reloaded.visibleMarks.first(where: { $0.symbol == "b" }) { reloaded.deleteMark(mark.id) }
        require(!reloaded.visibleMarks.contains { $0.symbol == "b" }, "Delete mark")

        // Cross-book global marks and back/forward use saved source identities.
        let otherURL = run.appendingPathComponent("other.pdf")
        require(try BaselineDocument.make().write(to: otherURL), "Write second book")
        reloaded.open(otherURL)
        require(await wait { !reloaded.isOpening }, "Open second book")
        attach(reloaded, view)
        require(reloaded.visibleMarks.contains(where: { $0.symbol == "G" }) && !reloaded.visibleMarks.contains(where: { $0.symbol == "a" }), "Global/local mark scope")
        reloaded.jumpMark("G")
        require(await wait { !reloaded.isOpening }, "Cross-book mark open")
        attach(reloaded, view)
        require(reloaded.currentRecord?.id == persistentID, "Global mark returns to first book")
        assertNear(reloaded.captureLocation()!, sixth, "Cross-book mark restores viewport")
        reloaded.back()
        require(await wait { !reloaded.isOpening }, "Cross-book history")
        attach(reloaded, view)
        require(reloaded.book?.name == "other.pdf", "Cross-book history returns to second book")

        // Persisted revision mismatch must not silently relocate an old mark.
        let originalBytes = try Data(contentsOf: moved)
        try (originalBytes + Data("\n% changed revision\n".utf8)).write(to: moved)
        let retainedID = reloaded.currentRecord?.id
        reloaded.jumpMark("G")
        require(await wait { !reloaded.isOpening }, "Changed-file lookup completes")
        require(reloaded.errorMessage != nil && reloaded.currentRecord?.id == retainedID, "Changed PDF rejects stale location")
        reloaded.errorMessage = nil
        reloaded.flush()
        window.orderOut(nil); window.close()

        // Host the actual SwiftUI reader for layout inspection; this is not a compositor benchmark.
        let host = NSHostingView(rootView: ReadingStudy(session: reloaded))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 960)
        let uiWindow = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        uiWindow.isReleasedWhenClosed = false; uiWindow.contentView = host; uiWindow.orderBack(nil)
        for _ in 0..<30 { try? await Task.sleep(nanoseconds: 10_000_000) }
        host.layoutSubtreeIfNeeded()
        uiWindow.makeKeyAndOrderFront(nil)
        reloaded.panel = .commands
        require(await wait { uiWindow.attachedSheet != nil }, "Command sheet presents")
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let editor = uiWindow.attachedSheet?.firstResponder as? NSTextView {
            editor.insertText("appearance", replacementRange: NSRange(location: NSNotFound, length: 0))
            try? await Task.sleep(nanoseconds: 150_000_000)
            let sheet = uiWindow.attachedSheet!
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            sheet.sendEvent(enter)
            require(await wait { reloaded.panel == .appearance }, "Typing and Return dispatch from command palette")
        } else { require(false, "Command palette focuses its text field") }
        require(await wait { uiWindow.attachedSheet != nil }, "Command transitions into appearance sheet")
        reloaded.panel = nil
        require(await wait { uiWindow.attachedSheet == nil }, "Sheet dismisses")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("reader.png"))
        }
        uiWindow.orderOut(nil); uiWindow.close()
        for panel in [ReaderPanel.commands, .appearance, .contents, .marks, .page] {
            let panelHost = NSHostingView(rootView: ReaderPanelView(session: reloaded, panel: panel))
            let size = panelHost.fittingSize
            panelHost.frame = CGRect(origin: .zero, size: size)
            let panelWindow = NSWindow(contentRect: panelHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
            panelWindow.isReleasedWhenClosed = false; panelWindow.contentView = panelHost; panelWindow.orderBack(nil)
            try? await Task.sleep(nanoseconds: 100_000_000)
            panelHost.layoutSubtreeIfNeeded()
            if let bitmap = panelHost.bitmapImageRepForCachingDisplay(in: panelHost.bounds) {
                panelHost.cacheDisplay(in: panelHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("panel-\(panel.rawValue).png"))
            }
            panelWindow.orderOut(nil); panelWindow.close()
        }
        print("Workspace checks passed: durable identity, restart/viewport/appearance, marks, history branching, native jumps, scroll exclusion, cross-book navigation, relocation, revision rejection, background search/cancellation, commands, and SwiftUI hosting.")
    }

    @MainActor static func attach(_ session: ReaderSession, _ view: ReaderPDFView) {
        view.onWillNavigate = {}
        view.document = session.book!.document; view.autoScales = true; view.layoutDocumentView()
        session.pdfView = view; session.viewDidAssign()
        view.onWillNavigate = session.recordDeparture
    }
    @MainActor static func documentPage(_ session: ReaderSession, _ index: Int) -> PDFPage { session.book!.document.page(at: index)! }
    @MainActor static func wait(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(20)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
    static func assertNear(_ a: BookLocation, _ b: BookLocation, _ message: String) {
        require(a.bookID == b.bookID && a.page == b.page && abs(a.x - b.x) < 0.025 && abs(a.y - b.y) < 0.025 && abs(a.scale - b.scale) < 0.02, "\(message): \(a) vs \(b)")
    }
    static func require(_ condition: Bool, _ message: String) { if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
