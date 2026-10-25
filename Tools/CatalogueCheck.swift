import AppKit
import PDFKit
import SwiftUI
import CSQLite

@main
enum CatalogueCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/catalogue-check", isDirectory: true)
        let folder = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let booksFolder = folder.appendingPathComponent("Books", isDirectory: true)
        let nested = booksFolder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let names = ["Sample A.pdf", "Sample B.pdf", "Sample C.PDF", "Sample D.pdf"]
        var urls: [URL] = []
        for (index, name) in names.enumerated() {
            let url = (index == 2 ? nested : booksFolder).appendingPathComponent(name)
            let document = PDFDocument()
            for _ in 0..<8 { document.insert(try BaselineDocument.make().page(at: 0)!, at: document.pageCount) }
            check(document.write(to: url), "Create PDF fixture"); urls.append(url)
        }
        try Data("ignored".utf8).write(to: booksFolder.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: booksFolder.appendingPathComponent("cycle"), withDestinationURL: booksFolder)
        let databaseURL = folder.appendingPathComponent("Library.sqlite")
        let store = try LibraryStore(url: databaseURL)
        let session = ReaderSession(store: store)
        session.registerFolder(booksFolder)
        check(await wait { !session.isScanning }, "Folder scan completes")
        check(session.library.books.count == 4, "Recursive PDF discovery; skip non-PDF and symlink cycle")
        check(session.documentPool.count == 0 && session.book == nil, "Discovery does not parse or open PDF documents")
        check(session.library.books(in: "recent").isEmpty, "Discovered books are not marked read")
        let firstFolderID = session.library.folders[0].id
        session.registerFolder(booksFolder)
        check(await wait { !session.isScanning }, "Repeat scan")
        check(session.library.books.count == 4 && session.library.folders.count == 1, "Re-registering is idempotent")
        session.registerFolder(nested)
        check(await wait { !session.isScanning }, "Overlapping scan")
        check(session.library.books.count == 4, "Overlapping folders retain one identity per file")
        let firstBook = session.library.books.first { $0.title == names[0] }!
        let secondBook = session.library.books.first { $0.title == names[1] }!
        let thirdBook = session.library.books.first { $0.title == names[2] }!
        let primaryCollection = session.createCollection("Collection A")!
        let reading = session.createCollection("Current Reading")!
        session.setMembership([firstBook.id, thirdBook.id], collectionID: primaryCollection, included: true)
        session.setMembership([firstBook.id, secondBook.id], collectionID: reading, included: true)
        check(session.library.books(in: "collection:\(primaryCollection)").count == 2, "Collection filtering")
        check(session.library.collections.allSatisfy { $0.bookIDs.contains(firstBook.id) }, "Overlapping memberships share identity")
        check(session.createCollection(" collection a ") == nil, "Collection names are trimmed and case-insensitive")
        session.renameCollection(primaryCollection, to: "Collection One")
        check(session.library.collections.first { $0.id == primaryCollection }?.name == "Collection One", "Rename preserves collection ID")
        session.selectScope("collection:\(primaryCollection)")
        check(session.library.books(in: session.activeScope, matching: "smp a").first?.id == firstBook.id, "Fuzzy title matching")
        check(session.library.books(in: session.activeScope, matching: "sample b").isEmpty, "Search respects selected scope")

        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 820, height: 900))
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.displayBox = .mediaBox
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        session.openBook(firstBook.id); check(await wait { !session.isOpening }, "Open discovered book"); attach(session, view)
        let firstDocument = session.book!.document
        session.go(to: 6); session.setMark("a")
        let firstPosition = session.captureLocation()!
        session.openBook(secondBook.id); check(await wait { !session.isOpening }, "Switch book"); attach(session, view)
        session.go(to: 3)
        let secondPosition = session.captureLocation()!
        session.openBook(firstBook.id); check(await wait { !session.isOpening }, "Switch back"); attach(session, view)
        check(session.lastOpenUsedCache && session.book?.document === firstDocument, "Warm switch reuses native document")
        near(session.captureLocation()!, firstPosition, "First position restored")
        check(session.visibleMarks.contains { $0.symbol == "a" }, "Marks retained across collections and switches")
        session.openBook(secondBook.id); check(await wait { !session.isOpening }, "Reopen second book"); attach(session, view)
        near(session.captureLocation()!, secondPosition, "Second position restored independently")
        session.openBook(thirdBook.id); check(await wait { !session.isOpening }, "Open third book"); attach(session, view)
        let fourthBook = session.library.books.first { $0.title == names[3] }!
        session.openBook(fourthBook.id); check(await wait { !session.isOpening }, "Open fourth book"); attach(session, view)
        check(session.documentPool.count == 3, "Native document cache has three-entry cap")
        check(session.documentPool.sourceBytes <= session.documentPool.byteBudget, "Cache source-byte budget")
        session.openBook(firstBook.id); check(await wait { !session.isOpening }, "Reopen evicted book"); attach(session, view)
        check(!session.lastOpenUsedCache && session.book?.document !== firstDocument, "LRU evicts least-recent document")
        near(session.captureLocation()!, firstPosition, "Eviction does not discard reading position")
        let oldDocument = session.book!.document
        try (Data(contentsOf: urls[0]) + Data("\n% updated\n".utf8)).write(to: urls[0])
        session.openBook(firstBook.id); check(await wait { !session.isOpening }, "Reopen changed PDF"); attach(session, view)
        check(!session.lastOpenUsedCache && session.book?.document !== oldDocument, "Revision change invalidates warm cache")
        check(session.captureLocation()!.page == 0, "Changed PDF does not restore stale position")

        // Rename during a library scan: collection membership, marks, and identity survive.
        let renamed = booksFolder.appendingPathComponent("Sample A Renamed.pdf")
        try FileManager.default.moveItem(at: urls[0], to: renamed)
        session.refreshLibrary(); check(await wait { !session.isScanning }, "Rescan moved file")
        check(session.library.books.count == 4 && session.library.books.first(where: { $0.id == firstBook.id })?.path == renamed.path, "Rename reconnects identity")
        check(session.library.collections.first { $0.id == primaryCollection }!.bookIDs.contains(firstBook.id), "Rename retains collection membership")
        try FileManager.default.removeItem(at: urls[1])
        session.refreshLibrary(); check(await wait { !session.isScanning }, "Rescan missing file")
        check(session.library.books.first { $0.id == secondBook.id }?.missing == true, "Missing files remain visible")
        check(session.library.collections.first { $0.id == reading }!.bookIDs.contains(secondBook.id), "Missing file preserves membership")
        session.removeFolder(firstFolderID)
        check(session.library.books.count == 4, "Removing a scan root retains reading records")
        session.deleteCollection(reading)
        check(FileManager.default.fileExists(atPath: renamed.path) && session.library.books.count == 4, "Deleting a collection never deletes books")
        session.registerFolder(folder.appendingPathComponent("unavailable"))
        check(await wait { !session.isScanning }, "Unavailable folder completes with status")
        check(session.scanMessage.contains("unavailable") && session.library.books.count == 4, "Failed scan retains library")
        session.refreshLibrary(); session.cancelScan()
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(!session.isScanning && session.library.books.count == 4, "Canceled scan cannot apply stale results")
        session.selectScope("collection:\(primaryCollection)")
        session.flush()
        let restored = ReaderSession(store: try LibraryStore(url: databaseURL))
        check(restored.library.collections.count == 1 && restored.activeScope == "collection:\(primaryCollection)", "Collections and scope survive restart")
        check(restored.library.marks.count == session.library.marks.count, "Collection persistence preserves existing marks")
        window.orderOut(nil); window.close()

        // Version-1 database upgrade preserves data and saves an untouched rollback snapshot.
        var old = LibraryState(); old.version = 1; old.books = session.library.books; old.marks = session.library.marks
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for key in ["collections", "folders", "activeScope", "didOfferDefaultFolder"] { object.removeValue(forKey: key) }
        let legacyURL = folder.appendingPathComponent("legacy.sqlite")
        try seed(legacyURL, payload: JSONSerialization.data(withJSONObject: object))
        let legacyStore = try LibraryStore(url: legacyURL)
        let migrated = try legacyStore.load()
        check(migrated.version == 4 && migrated.books.count == 4 && migrated.marks.count == old.marks.count && migrated.collections.isEmpty, "Version-1 migration")
        check(try backupCount(legacyURL) == 1, "Migration retains original snapshot")
        var versionTwo = session.library; versionTwo.version = 2
        let versionTwoURL = folder.appendingPathComponent("version-two.sqlite")
        var versionTwoObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(versionTwo)) as! [String: Any]
        versionTwoObject.removeValue(forKey: "workspaces"); versionTwoObject.removeValue(forKey: "activeWorkspaceID")
        try seed(versionTwoURL, payload: JSONSerialization.data(withJSONObject: versionTwoObject))
        let upgraded = try LibraryStore(url: versionTwoURL).load()
        check(upgraded.version == 4 && upgraded.collections.map(\.id) == versionTwo.collections.map(\.id) && upgraded.marks.count == versionTwo.marks.count, "Version-2 migration preserves collections and marks")
        check(try backupCount(versionTwoURL, version: 2) == 1, "Version-2 migration retains original snapshot")

        // The product rename copies the live SQLite snapshot and leaves the old database intact.
        let oldProductDirectory = folder.appendingPathComponent("Paperman", isDirectory: true)
        let newProductDirectory = folder.appendingPathComponent("Foreedge", isDirectory: true)
        try FileManager.default.createDirectory(at: oldProductDirectory, withIntermediateDirectories: true)
        let oldProductURL = oldProductDirectory.appendingPathComponent("Library.sqlite")
        try seed(oldProductURL, payload: JSONEncoder().encode(session.library))
        try LibraryStore.migrateLegacyData(from: oldProductDirectory, to: newProductDirectory)
        let renamedLibrary = try LibraryStore(url: newProductDirectory.appendingPathComponent("Library.sqlite")).load()
        check(renamedLibrary.books.count == session.library.books.count && renamedLibrary.marks.count == session.library.marks.count,
              "Product rename preserves the library through SQLite backup")
        check(FileManager.default.fileExists(atPath: oldProductURL.path), "Product rename retains the legacy database")

        var future = old; future.version = 99
        let futureURL = folder.appendingPathComponent("future.sqlite")
        try seed(futureURL, payload: JSONEncoder().encode(future))
        do { _ = try LibraryStore(url: futureURL).load(); check(false, "Future schema must be rejected") } catch {}

        // Exercise the real quick picker with native typing/Return and a restored collection scope.
        let host = NSHostingView(rootView: ReadingStudy(session: restored))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 960)
        let ui = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        ui.isReleasedWhenClosed = false; ui.contentView = host; ui.makeKeyAndOrderFront(nil)
        restored.panel = .quickOpen
        check(await wait { ui.attachedSheet != nil }, "Quick picker presents")
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let sheet = ui.attachedSheet, let editor = sheet.firstResponder as? NSTextView else { fatalError("Quick picker must focus search") }
        editor.insertText("sample c", replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(nanoseconds: 100_000_000)
        sheet.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        check(await wait { restored.recordID == thirdBook.id && !restored.isOpening }, "Quick picker opens typed match")
        check(await wait { ui.attachedSheet == nil }, "Quick picker dismisses")
        restored.panel = .catalogue
        check(await wait { ui.attachedSheet != nil }, "Library browser presents")
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let content = ui.attachedSheet?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("library.png"))
        }
        restored.panel = nil
        check(await wait { ui.attachedSheet == nil }, "Library browser dismisses")
        ui.orderOut(nil); ui.close()
        print("Catalogue checks passed: recursive discovery, idempotent/overlapping folders, collections, fuzzy scope, independent positions, warm reuse, eviction, revision invalidation, renames/missing files, cancellation, persistence/migration, and native quick-picker input.")
    }
    @MainActor static func attach(_ session: ReaderSession, _ view: ReaderPDFView) {
        view.onWillNavigate = {}; view.document = session.book!.document; view.autoScales = true; view.layoutDocumentView()
        session.pdfView = view; session.viewDidAssign(); view.onWillNavigate = session.recordDeparture
    }
    @MainActor static func wait(_ condition: () -> Bool) async -> Bool {
        let limit = Date().addingTimeInterval(20)
        while !condition() { if Date() > limit { return false }; try? await Task.sleep(nanoseconds: 10_000_000) }
        return true
    }
    static func check(_ condition: Bool, _ message: String) { if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    static func near(_ a: BookLocation, _ b: BookLocation, _ message: String) { check(a.bookID == b.bookID && a.page == b.page && abs(a.y - b.y) < 0.025, message) }
    static func seed(_ url: URL, payload: Data) throws {
        var db: OpaquePointer?; check(sqlite3_open(url.path, &db) == SQLITE_OK, "Open test database"); defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE state(id INTEGER PRIMARY KEY, payload BLOB)", nil, nil, nil) == SQLITE_OK, "Create legacy table")
        var statement: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT INTO state VALUES(1, ?)", -1, &statement, nil); defer { sqlite3_finalize(statement) }
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        check(sqlite3_step(statement) == SQLITE_DONE, "Seed test database")
    }
    static func backupCount(_ url: URL, version: Int = 1) throws -> Int {
        var db: OpaquePointer?; sqlite3_open(url.path, &db); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; sqlite3_prepare_v2(db, "SELECT count(*) FROM migration_backup WHERE version=\(version)", -1, &statement, nil); defer { sqlite3_finalize(statement) }
        check(sqlite3_step(statement) == SQLITE_ROW, "Read migration backup")
        return Int(sqlite3_column_int(statement, 0))
    }
}
