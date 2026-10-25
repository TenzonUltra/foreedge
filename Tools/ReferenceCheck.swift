import AppKit
import PDFKit
import SwiftUI
import CSQLite

@main enum ReferenceCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.regular)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Foreedge-references-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["Document A", "Document B"].map { directory.appendingPathComponent($0 + ".pdf") }
        for url in urls {
            let document = PDFDocument()
            for _ in 0..<12 { document.insert(try BaselineDocument.make().page(at: 0)!, at: document.pageCount) }
            check(document.write(to: url), "Write fixture")
        }
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let database = directory.appendingPathComponent("Library.sqlite")
        let workspace = WorkspaceSession(context: LibraryContext(store: try LibraryStore(url: database)))
        let session = workspace.reader
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        session.open(urls[0]); check(await ready(session), "Open source book")
        session.go(to: 3); try await settle()
        select(session, page: 2)
        let sourceText = session.pdfView!.currentSelection!.string!
        let source = session.copyReference(to: pasteboard)!
        check(source.location.page == 2 && source.spans.count == 1 && source.quote == sourceText, "Capture selected text with character ranges")
        check(session.copyReference(to: pasteboard)?.id == source.id && session.library.references.count == 1, "Copying a passage reuses its stable anchor")
        check(session.copiedReference(from: pasteboard)?.id == source.id, "Private clipboard reference resolves")
        let citation = pasteboard.string(forType: .string)!
        pasteboard.clearContents(); pasteboard.setString(citation, forType: .string)
        check(session.copiedReference(from: pasteboard)?.id == source.id, "Plain-text citation URL resolves")
        check(PassageReference.id(from: source.url) == source.id &&
              PassageReference.id(from: URL(string: "paperman://reference/\(source.id)")!) == source.id &&
              PassageReference.id(from: URL(string: "foreedge://other/\(source.id)")!) == nil,
              "Current and legacy reference URL validation")
        pasteboard.clearContents()
        pasteboard.setString(source.id.uuidString, forType: ReaderSession.legacyReferencePasteboardType)
        check(session.copiedReference(from: pasteboard)?.id == source.id, "Legacy private clipboard reference resolves")
        pasteboard.clearContents(); pasteboard.setString(citation, forType: .string)

        session.open(urls[1]); check(await ready(session), "Open target book")
        session.go(to: 7); try await settle(); select(session, page: 6)
        session.beginReferenceLink(from: pasteboard)
        check(await wait { window.attachedSheet != nil }, "Link panel appears")
        try await settle()
        check(session.referenceDraft?.target.location.page == 6, "Draft freezes selected destination before panel focus")
        if let editor = window.attachedSheet?.firstResponder as? NSTextView {
            editor.insertText("Proof of this theorem", replacementRange: NSRange(location: NSNotFound, length: 0))
            sendReturn(window.attachedSheet!)
        } else { check(false, "Link panel focuses optional note") }
        check(await wait { session.library.referenceLinks.count == 1 && session.panel == nil }, "Return saves link")
        check(await wait { window.attachedSheet == nil }, "Link panel closes")
        let link = session.library.referenceLinks[0]
        let target = session.library.reference(link.targetID)!
        check(link.sourceID == source.id && link.note == "Proof of this theorem" && link.provenance == "user", "Directed edge and note saved")
        let backlinks = session.library.referenceRows(bookID: target.location.bookID, page: 6, scope: .page)
        check(backlinks.count == 1 && backlinks[0].incoming && backlinks[0].endpoint.id == source.id, "Target page exposes backlink")
        check(session.library.referenceRows(bookID: source.location.bookID, page: 2, scope: .page).first?.endpoint.id == target.id, "Source page exposes outgoing link")
        check(session.library.referenceRows(bookID: target.location.bookID, page: 0, scope: .page).isEmpty, "Page scope excludes other pages")
        check(session.library.referenceRows(bookID: target.location.bookID, page: 0, scope: .book).count == 1, "Book scope includes other pages")

        let departure = session.captureLocation()!, historyCount = session.backHistory.count
        ReaderCommand.references.run(in: session)
        check(await wait { window.attachedSheet != nil }, "Reference picker opens")
        try await settle()
        try capture(window.attachedSheet!.contentView!, to: ".build/reference-check/backlinks.png")
        if let editor = window.attachedSheet?.firstResponder as? NSTextView {
            editor.insertText("proof", replacementRange: NSRange(location: NSNotFound, length: 0))
            sendReturn(window.attachedSheet!)
        } else { check(false, "References picker focuses search") }
        check(await ready(session, bookID: source.location.bookID), "Return follows filtered backlink")
        check(session.pdfView?.currentSelection?.string == sourceText, "Following reference highlights source passage")
        check(session.backHistory.count == historyCount + 1, "Following and highlighting record exactly one departure")
        session.back(); check(await ready(session, bookID: target.location.bookID), "Back returns across books")
        near(session.captureLocation()!, departure, "Back preserves departure position")
        session.forward(); check(await ready(session, bookID: source.location.bookID), "Forward returns across books")
        session.openReferenceURL(target.url); check(await ready(session, bookID: target.location.bookID), "External reference URL dispatch")

        let sourcePaneID = workspace.activePaneID, sourcePosition = session.captureLocation()!
        ReaderCommand.references.run(in: session)
        check(await wait { window.attachedSheet != nil }, "References picker reopens for beside navigation")
        try await settle()
        check(!session.library.referenceRows(bookID: session.currentRecord?.id, page: session.captureLocation()?.page, scope: .page).isEmpty, "Reference picker has a destination after following a highlighted passage")
        sendReturn(window.attachedSheet!, modifiers: .command)
        check(await wait { workspace.panes.count == 2 }, "Command-Return opens beside from the search field")
        check(await ready(workspace.reader, bookID: source.location.bookID), "Open beside creates a second pane")
        check(workspace.panes.count == 2 && workspace.activePaneID != sourcePaneID, "Beside focuses destination pane")
        near(session.captureLocation()!, sourcePosition, "Beside preserves original reader")
        check(workspace.reader.pdfView?.currentSelection?.string == sourceText, "Beside highlights selected text")
        session.followReference(target.id, beside: true)
        check(await ready(workspace.reader, bookID: target.location.bookID), "Reuse adjacent pane")
        check(workspace.panes.count == 2, "Repeated beside navigation does not add panes")

        workspace.context.updateReferenceNote(link.id, note: "Equivalent argument")
        workspace.flush()
        let loaded = try LibraryStore(url: database).load()
        check(loaded.version == 4 && loaded.references.count == 2 && loaded.referenceLinks[0].note == "Equivalent argument", "References and note edits survive disk reload")
        check(loaded.reference(source.id)?.spans == source.spans && loaded.reference(source.id)?.quote == source.quote, "Text anchors survive reload")
        check(try urls.enumerated().allSatisfy { try Data(contentsOf: $0.element) == originalBytes[$0.offset] }, "Reference operations never modify PDFs")
        try checkMigration(loaded, directory: directory)

        // Scanned/no-selection pages use viewport anchors, and same-page links still have both directions.
        workspace.reader.pdfView?.clearSelection()
        workspace.reader.go(to: 9); try await settle()
        let locationRef = workspace.reader.copyReference(to: pasteboard)!
        check(locationRef.spans.isEmpty && locationRef.quote.isEmpty && locationRef.location.page == 8, "Location-only reference works without text")
        workspace.reader.beginReferenceLink(from: pasteboard)
        check(!workspace.reader.commitReferenceLink(note: "self") && workspace.context.library.referenceLinks.count == 1, "Self-link rejected")
        workspace.reader.panel = nil; try await settle()
        workspace.reader.go(to: 10); try await settle()
        workspace.reader.beginReferenceLink(from: pasteboard)
        check(workspace.reader.commitReferenceLink(note: "location"), "Location-only passages can be linked")
        try await settle()
        workspace.reader.followReference(locationRef.id); check(await ready(workspace.reader), "Follow location-only reference")
        check(workspace.reader.captureLocation()?.page == 8 && workspace.reader.pdfView?.currentSelection == nil, "Location reference restores page without a stale highlight")

        // A revision mismatch leaves the currently displayed book and its history intact.
        try (originalBytes[0] + Data("\n% revised\n".utf8)).write(to: urls[0])
        let retained = workspace.reader.currentRecord!.id, history = workspace.reader.backHistory.count
        workspace.reader.followReference(source.id)
        check(await wait { !workspace.reader.isOpening }, "Changed-file check finishes")
        check(workspace.reader.errorMessage != nil && workspace.reader.currentRecord?.id == retained && workspace.reader.backHistory.count == history, "Changed PDF rejects stale reference without losing current reading state")
        workspace.reader.errorMessage = nil
        let referenceCount = workspace.context.library.references.count
        workspace.context.deleteReferenceLink(link.id); workspace.flush()
        let afterDelete = try LibraryStore(url: database).load()
        check(!afterDelete.referenceLinks.contains { $0.id == link.id } && afterDelete.references.count == referenceCount, "Deleting link retains independently copyable anchors")
        print("Reference checks passed: selection/location capture, clipboard and URLs, keyboard link creation and backlink following, single-entry history, adjacent-pane reuse, durable notes/anchors, schema-3 migration backup, unchanged PDF bytes, self-link rejection, revision protection, and link deletion.")
    }
    @MainActor static func select(_ session: ReaderSession, page: Int) {
        let page = session.book!.document.page(at: page)!
        let selection = page.selection(for: NSRange(location: 0, length: min(24, page.numberOfCharacters)))!
        session.pdfView!.setCurrentSelection(selection, animate: false)
    }
    @MainActor static func sendReturn(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        // AppKit routes modified keys through key equivalents before normal text input.
        if !modifiers.isEmpty { check(window.performKeyEquivalent(with: event), "Modified Return is registered in the reference sheet") }
        else { window.sendEvent(event) }
    }
    @MainActor static func capture(_ view: NSView, to path: String) throws {
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    static func checkMigration(_ state: LibraryState, directory: URL) throws {
        var old = state; old.version = 3
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object.removeValue(forKey: "references"); object.removeValue(forKey: "referenceLinks")
        let data = try JSONSerialization.data(withJSONObject: object)
        let path = directory.appendingPathComponent("legacy.sqlite")
        var db: OpaquePointer?; check(sqlite3_open(path.path, &db) == SQLITE_OK, "Open migration fixture")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE state(id INTEGER PRIMARY KEY, payload BLOB)", nil, nil, nil) == SQLITE_OK, "Create migration fixture")
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO state VALUES(1, ?)", -1, &statement, nil)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        check(sqlite3_step(statement) == SQLITE_DONE, "Seed schema 3"); sqlite3_finalize(statement)
        let loaded = try LibraryStore(url: path).load()
        check(loaded.version == 4 && loaded.references.isEmpty && loaded.referenceLinks.isEmpty && loaded.workspaces.map(\.id) == state.workspaces.map(\.id) && loaded.books.map(\.id) == state.books.map(\.id), "Migration retains books and workspaces")
        sqlite3_prepare_v2(db, "SELECT payload FROM migration_backup WHERE version=3", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        check(sqlite3_step(statement) == SQLITE_ROW, "Migration stores original snapshot")
        let backup = Data(bytes: sqlite3_column_blob(statement, 0)!, count: Int(sqlite3_column_bytes(statement, 0)))
        check(backup == data, "Migration backup is byte-for-byte intact")
    }
    @MainActor static func ready(_ session: ReaderSession, bookID: UUID? = nil) async -> Bool {
        let result = await wait { !session.isOpening && session.book != nil && session.pdfView?.window != nil && session.captureLocation() != nil && (bookID == nil || session.currentRecord?.id == bookID) }
        try? await settle(); return result
    }
    @MainActor static func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while !condition() { if Date() > deadline { return false }; try? await Task.sleep(nanoseconds: 25_000_000) }
        return true
    }
    static func settle() async throws { try await Task.sleep(nanoseconds: 300_000_000) }
    static func near(_ a: BookLocation, _ b: BookLocation, _ message: String) {
        check(a.bookID == b.bookID && a.page == b.page && abs(a.y - b.y) < 0.03, message)
    }
    static func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
