import AppKit
import CoreText
import PDFKit
import SwiftUI

@main enum SearchCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Foreedge-search-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("Primary.pdf"), b = folder.appendingPathComponent("Secondary.pdf")
        try fixture([
            Array(repeating: "Vector spaces are useful structures.", count: 18).joined(separator: "\n"),
            "A vector\nspace has useful operations.",
            "Metric spaces may be complete.",
            "Representa-\ntions preserve structure.",
            "A vector field accompanies a metric space.",
            "A suﬃcient condition is useful."
        ], at: a)
        try fixture(["A rare space appears in this document.", "Some other unrelated text."], at: b)
        let firstBytes = try Data(contentsOf: a), secondBytes = try Data(contentsOf: b)
        let indexURL = folder.appendingPathComponent("Search.sqlite")
        let index = SearchIndex(url: indexURL)
        let firstID = UUID(), secondID = UUID()
        let aDoc = SearchDocument(source: .file(a), bookID: firstID, title: "Primary")
        let bDoc = SearchDocument(source: .file(b), bookID: secondID, title: "Secondary")
        let aKey = try await index.prepare(aDoc)
        _ = try await index.prepare(aDoc); _ = try await index.prepare(aDoc)
        var result = try await completed(index, query: "vector space", docs: [aKey])
        check(result.hits.count == 3 && Set(result.hits.map(\.page)).count == 3, "Phrase and all-word results are grouped by page")
        check(result.hits.first?.kind == .phrase && result.hits.last?.kind == .terms, "Phrase matches rank ahead of scattered words")
        check(result.hits.first { $0.page == 0 }?.matchCount == 18, "Repeated occurrences are retained inside one result")
        check(result.hits.contains { $0.page == 1 && $0.kind == .phrase }, "Phrase matches across line breaks")
        check(await index.extractedPages == 6, "Concurrent warm requests extract each page once")
        let display = PDFDocument(url: a)!
        for hit in result.hits {
            for match in hit.matches {
                let text = display.page(at: hit.page)!.selection(for: NSRange(location: match.offset, length: match.length))?.string
                check(text != nil && !text!.isEmpty, "Search offsets resolve to native selections")
            }
        }
        result = try await index.search("rare space", documents: [aKey])
        check(result.broader && !result.hits.isEmpty && result.hits.allSatisfy { $0.kind == .broader && !$0.matchedWords.contains("rare") }, "Missing concept yields explicitly broader shared-word results")
        check(try await index.search("qzxxnonexistent", documents: [aKey]).hits.isEmpty, "No evidence produces no result")
        result = try await index.search("representation", documents: [aKey])
        check(result.hits.first?.page == 3, "Dehyphenation and word forms find the correct page")
        let selected = display.page(at: 3)!.selection(for: NSRange(location: result.hits[0].offset, length: result.hits[0].length))!.string!
        check(selected.contains("Representa") && selected.contains("tions"), "Dehyphenated matches retain original PDF offsets")
        result = try await index.search("sufficient", documents: [aKey])
        check(result.hits.first?.page == 5, "Ligature normalization finds text")
        let normalized = SearchText.matches(marked: "A \u{e000}sufficient\u{e001} condition", raw: "A suﬃcient condition")
        check(("A suﬃcient condition" as NSString).substring(with: NSRange(location: normalized[0].offset, length: normalized[0].length)) == "suﬃcient", "Ligature offsets map back exactly")
        check(await index.extractedPages == 6, "Repeated queries do not re-extract text")
        let bKey = try await index.prepare(bDoc)
        result = try await completed(index, query: "rare space", docs: [aKey,bKey])
        check(!result.broader && result.hits.count == 1 && result.hits[0].bookID == secondID, "Collection search prefers supported phrase over broader alternatives")
        let restart = SearchIndex(url: indexURL)
        let restartedKey = try await restart.prepare(aDoc)
        result = try await restart.search("vector space", documents: [restartedKey])
        check(result.isComplete && result.hits.count == 3, "Disk index is immediately searchable")
        check(await restart.extractedPages == 0, "Restart reads cached text without PDF extraction")
        let search = BookSearch(index: index)
        search.start("vector space", documents: [aDoc]); search.start("rare space", documents: [bDoc])
        check(await wait { !search.isSearching }, "Rapid search completes")
        check(search.hits.count == 1 && search.hits[0].bookID == secondID, "Canceled query cannot publish stale results")
        search.start("vector space", documents: [aDoc]); search.cancel()
        try await settle(); check(search.hits.isEmpty && !search.isSearching, "Closing search cancels pending UI work")
        _ = try await index.search("\" OR * ( )", documents: [aKey])
        check(try Data(contentsOf: a) == firstBytes && Data(contentsOf: b) == secondBytes, "Search never modifies input PDFs")

        // Exercise the actual collection picker, keyboard navigation, highlights, and history.
        NSApp.setActivationPolicy(.regular)
        let workspace = WorkspaceSession(context: LibraryContext(store: try LibraryStore(url: folder.appendingPathComponent("Library.sqlite"))))
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 850)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        let reader = workspace.reader
        reader.open(b); check(await ready(reader), "Open second book for catalogue")
        let secondaryID = reader.currentRecord!.id
        reader.open(a); check(await ready(reader), "Open first book for reading")
        let primaryID = reader.currentRecord!.id
        let collection = reader.context.createCollection("Study")!
        reader.context.setMembership([primaryID,secondaryID], collectionID: collection, included: true)
        reader.fitWidth(); reader.pdfView!.scaleFactor *= 0.8
        let manualScale = reader.pdfView!.scaleFactor
        ReaderCommand.find.run(in: reader)
        check(await wait { window.attachedSheet != nil }, "Book search opens")
        try await settle()
        (window.attachedSheet!.firstResponder as! NSTextView).insertText("vector spaces are useful structures", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(await wait { !reader.search.isSearching && !reader.search.hits.isEmpty }, "Repeated-page result is ready")
        let repeatedHit = reader.search.hits[0]
        check(repeatedHit.matches.count == 18, "Picker groups repeated page occurrences")
        let nextOccurrence = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: window.attachedSheet!.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124)!
        check(window.attachedSheet!.performKeyEquivalent(with: nextOccurrence), "Option-Right advances the selected page occurrence")
        try await settle(); sendReturn(window.attachedSheet!)
        check(await wait { window.attachedSheet == nil }, "Occurrence opens")
        try await settle()
        let pickedRange = reader.pdfView!.currentSelection!.range(at: 0, on: reader.book!.document.page(at: repeatedHit.page)!)
        check(pickedRange.location == repeatedHit.matches[1].offset, "Keyboard occurrence navigation selects the second match")
        check(abs(reader.pdfView!.scaleFactor - manualScale) < 0.001, "Search preserves manual zoom")
        reader.back(); try await settle()
        let position = reader.captureLocation()!
        ReaderCommand.findCollection.run(in: reader)
        check(await wait { window.attachedSheet != nil }, "Collection search sheet opens")
        try await settle()
        check(reader.searchScope == .collection, "Collection command sets search scope")
        let editor = window.attachedSheet?.firstResponder as? NSTextView
        check(editor != nil, "Find focuses native text input")
        editor!.insertText("rare space", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(await wait { !reader.search.isSearching && !reader.search.hits.isEmpty }, "Collection search delivers results")
        check(reader.search.hits.first?.bookID == secondaryID, "Picker searches current collection")
        sendReturn(window.attachedSheet!)
        check(await wait { !reader.isOpening && reader.currentRecord?.id == secondaryID }, "Return opens result in another book")
        try await settle()
        check(reader.pdfView?.currentSelection?.string?.lowercased() == "rare space", "Cross-book result highlights the matching phrase")
        reader.back(); check(await wait { !reader.isOpening && reader.currentRecord?.id == primaryID }, "Back returns to source book")
        try await settle()
        check(reader.captureLocation()?.page == position.page, "Search preserves return location")
        ReaderCommand.findCollection.run(in: reader)
        check(await wait { window.attachedSheet != nil }, "Reopen search")
        try await settle()
        (window.attachedSheet!.firstResponder as! NSTextView).insertText("rare space", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(await wait { !reader.search.isSearching && !reader.search.hits.isEmpty }, "Cached collection results ready")
        sendReturn(window.attachedSheet!, beside: true)
        check(await wait { workspace.panes.count == 2 && !workspace.reader.isOpening && workspace.reader.currentRecord?.id == secondaryID }, "Command-Return opens result beside")
        try await settle()
        check(reader.currentRecord?.id == primaryID && workspace.reader.pdfView?.currentSelection?.string?.lowercased() == "rare space", "Beside leaves original book in place")
        reader.context.setMembership([secondaryID], collectionID: collection, included: false)
        check(reader.searchDocuments(scope: .collection).count == 1, "Collection changes constrain search scope")

        // Changing a source invalidates its index, rather than returning old offsets.
        try fixture(["Completely replaced with a zebra."], at: a)
        let changedKey = try await index.prepare(aDoc)
        check(changedKey.revision != aKey.revision, "Changed file receives a new search revision")
        result = try await completed(index, query: "vector space", docs: [changedKey])
        check(result.hits.isEmpty, "Reindex removes stale passages")
        result = try await index.search("zebra", documents: [changedKey])
        check(result.hits.count == 1, "Replacement content is searchable")
        print("Search checks passed: shared persistent extraction, per-page grouping and occurrences, phrase ranking, honest broader fallback, line breaks/ligatures/hyphens and native offsets, cancellation, collection scope, keyboard open/beside/history, unchanged PDFs, and revision invalidation.")
    }
    static func completed(_ index: SearchIndex, query: String, docs: [SearchDocumentKey]) async throws -> SearchResponse {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let response = try await index.search(query, documents: docs)
            if response.isComplete { return response }
            if Date() > deadline { throw SearchFailure(message: "Index did not finish") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    static func fixture(_ pages: [String], at url: URL) throws {
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            for (i,line) in text.components(separatedBy: "\n").enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Times-Roman" as CFString, 14, nil)])
                context.textPosition = CGPoint(x: 48, y: 720 - Double(i)*25)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: url)
    }
    @MainActor static func sendReturn(_ window: NSWindow, beside: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: beside ? .command : [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        if beside { check(window.performKeyEquivalent(with: event), "Command-Return is registered") } else { window.sendEvent(event) }
    }
    @MainActor static func ready(_ reader: ReaderSession) async -> Bool {
        let result = await wait { !reader.isOpening && reader.pdfView?.window != nil && reader.captureLocation() != nil }
        try? await settle(); return result
    }
    @MainActor static func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while !condition() { if Date() > deadline { return false }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return true
    }
    static func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
    static func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
