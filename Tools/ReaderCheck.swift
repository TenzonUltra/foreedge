import AppKit
import CoreGraphics
import CoreText
import PDFKit

@main
enum ReaderCheck {
    @MainActor
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/reader-check", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("navigation-1000-pages.pdf")
        try await Task.detached { try makeFixture(at: url, pageCount: 1000) }.value
        _ = NSApplication.shared
        let base = try await PaperWorker.shared.baseTexture()
        let cachedBase = try await PaperWorker.shared.baseTexture()
        check(base.image === cachedBase.image, "Base paper must be prepared once")
        check(base.byteCount == 3 * 1224 * 1584, "Shared base cache must contain only three maps")

        let session = ReaderSession()
        session.open(url)
        check(await waitFor { !session.isOpening }, "Document opening timed out")
        let book = session.book!
        check(book.pageCount == 1000 && session.errorMessage == nil, "Open the 1,000-page fixture")
        if case .file = book.source {} else { check(false, "Real PDFs must retain a file source rather than serialize to Data") }
        let parseMilliseconds = book.openMilliseconds

        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 820, height: 900))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .mediaBox
        let coordinator = PDFSurface.Coordinator(appearance: PaperAppearance(), texture: base)
        coordinator.attach(view)
        coordinator.onPageChange = { session.pageNumber = $0 }
        coordinator.setDocument(source: book.source, id: book.id)
        view.pageOverlayViewProvider = coordinator
        let assignStart = ProcessInfo.processInfo.systemUptime
        view.document = book.document
        view.autoScales = true
        let assignMilliseconds = (ProcessInfo.processInfo.systemUptime - assignStart) * 1000
        session.pdfView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Foreedge navigation verification"
        window.contentView = view
        window.orderBack(nil)
        check(await waitFor { !view.visiblePages.isEmpty }, "PDFView must show a page")

        session.go(to: 1000)
        check(await waitFor { session.pageNumber == 1000 }, "Jump to the final page")
        session.nextPage()
        check(session.pageNumber == 1000, "Next at the last page must be bounded")
        session.go(to: 1)
        check(await waitFor { session.pageNumber == 1 }, "Return to the first page")
        session.nextPage()
        check(await waitFor { session.pageNumber == 2 }, "Next page")
        session.previousPage()
        check(await waitFor { session.pageNumber == 1 }, "Previous page")
        session.fitWidth()
        check(view.scaleFactor > 0 && view.document === book.document, "Fit width must retain the document")
        check(coordinator.cachedPageCount == 0, "Balanced must not prepare any page masks")

        coordinator.update(appearance: PaperAppearance(experiment: .adaptive), texture: base)
        for page in [1, 9, 17, 45, 100, 200, 500, 1000, 6, 4, 3] {
            session.go(to: page)
            check(await waitFor { coordinator.cachedPages.contains(page - 1) }, "Prepare adaptive page \(page)")
            check(coordinator.cachedPageCount <= 6, "Adaptive cache must stay within six pages")
            check(coordinator.pendingPageCount <= 4, "Adaptive queue must contain only the current visible set")
        }
        let maximumAdaptiveBytes = 6 * PaperTexture.width * PaperTexture.height
        let baseAfterNavigation = try await PaperWorker.shared.baseTexture()
        check(baseAfterNavigation.image === base.image, "Navigation must not regenerate the shared surface")

        // Rapid navigation followed immediately by a different document must discard stale work.
        for page in 700..<720 { session.go(to: page) }
        let replacement = try BaselineDocument.make()
        let replacementID = UUID()
        let replacementData = replacement.dataRepresentation()!
        coordinator.setDocument(source: .data(replacementData), id: replacementID)
        view.document = replacement
        view.autoScales = true
        check(await waitFor { coordinator.cachedPages == Set([0]) }, "Only the replacement document's page may populate the cache")
        check(view.document === replacement, "Old preparation must not replace the visible document")
        coordinator.shutdown()
        view.pageOverlayViewProvider = nil
        window.orderOut(nil)
        window.close()

        let beforeFailure = session.book!.id
        session.open(folder.appendingPathComponent("does-not-exist.pdf"))
        check(await waitFor { !session.isOpening }, "Invalid open must finish")
        check(session.errorMessage != nil && session.book?.id == beforeFailure, "A failed open must retain the current book")

        // A newer request wins even if the older request is still queued in the loader.
        let smallURL = folder.appendingPathComponent("replacement.pdf")
        try replacementData.write(to: smallURL)
        session.open(url)
        session.open(smallURL)
        check(await waitFor { !session.isOpening }, "Replacement open timed out")
        check(session.book?.pageCount == 1 && session.book?.name == "replacement.pdf", "Latest open request must win")

        let report = """
        Reader checks passed: file-backed opening, 1,000-page navigation, previous/next boundaries,
        page-number notification, fit width, no masks in Balanced, six-page adaptive cache,
        bounded pending work, base-image reuse, document-switch stale-work rejection,
        failed-open preservation, and latest-open-request handling.
        Fixture open/parse CPU: \(String(format: "%.2f", parseMilliseconds)) ms.
        Assign PDFView CPU: \(String(format: "%.2f", assignMilliseconds)) ms.
        Shared CPU image bytes: \(base.byteCount); maximum cached adaptive CPU image bytes: \(maximumAdaptiveBytes).
        Fixture: \(url.lastPathComponent). Generated vector pages, not a scanned-book performance benchmark.
        Timings exclude first visible frame and do not establish GPU cost, scroll FPS, or total memory.
        """
        print(report)
        try report.write(to: folder.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func waitFor(_ condition: () -> Bool, seconds: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            pumpEvents()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private static func pumpEvents() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

    private static func makeFixture(at url: URL, pageCount: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            let text = NSAttributedString(string: "Foreedge navigation fixture — page \(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 48, y: 720)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: index % 2 == 0 ? 48 : 340, y: 120, width: 220, height: 480))
            context.endPDFPage()
        }
        context.closePDF()
    }
}

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}
