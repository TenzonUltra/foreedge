import AppKit
import PDFKit

@main
enum SwitchCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 else { fatalError("Usage: check output-directory books-folder") }
        let output = URL(fileURLWithPath: args[0], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: args[1], isDirectory: true)
        let session = ReaderSession() // Intentionally no persistent user database.
        let scanStart = ProcessInfo.processInfo.systemUptime
        session.registerFolder(folder)
        try await wait { !session.isScanning }
        let scanMS = (ProcessInfo.processInfo.systemUptime - scanStart) * 1000
        let names = ["Sample-A.pdf", "Sample-B.pdf", "Sample-C.pdf"]
        let records = try names.map { name -> BookRecord in
            guard let record = session.library.books.first(where: { $0.title == name }) else { throw Failure(message: "Missing sample book: \(name)") }
            return record
        }
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 820, height: 900))
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.displayBox = .mediaBox
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        var expected: [UUID: BookLocation] = [:]
        var samples: [[String: Any]] = []
        for pass in 0..<2 {
            for (index, record) in records.enumerated() {
                let start = ProcessInfo.processInfo.systemUptime
                session.openBook(record.id)
                try await wait { !session.isOpening }
                guard session.errorMessage == nil, let book = session.book else { throw Failure(message: session.errorMessage ?? "Open failed") }
                let readyMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                guard session.lastOpenUsedCache == (pass == 1) else { throw Failure(message: "Unexpected cache behavior") }
                view.onWillNavigate = {}; let assignStart = ProcessInfo.processInfo.systemUptime
                view.document = book.document; view.autoScales = true; view.layoutDocumentView()
                session.pdfView = view; session.viewDidAssign(); view.onWillNavigate = session.recordDeparture
                let assignMS = (ProcessInfo.processInfo.systemUptime - assignStart) * 1000
                if pass == 0 {
                    session.go(to: min(book.pageCount, 40 + index * 20)); session.fitWidth()
                    expected[record.id] = session.captureLocation()
                } else {
                    guard let actual = session.captureLocation(), let saved = expected[record.id],
                          actual.page == saved.page, abs(actual.y - saved.y) < 0.025 else { throw Failure(message: "Reading position was not restored") }
                }
                samples.append(["book": record.title, "pages": book.pageCount, "cached": session.lastOpenUsedCache,
                    "request_to_ready_ms_including_polling": readyMS, "assign_and_restore_cpu_ms": assignMS])
            }
        }
        window.orderOut(nil); window.close()
        let result: [String: Any] = ["discovered_books": session.library.books.count, "discovery_ms_including_polling": scanMS,
            "cached_documents": session.documentPool.count, "cached_source_bytes": session.documentPool.sourceBytes,
            "samples": samples,
            "limits": "CPU-side operation intervals only; ready time includes 2 ms polling. No first-frame, GPU, total memory or scrolling claim. Native PDFView only; paper appearance unchanged by this work."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("Discovered \(session.library.books.count) real PDFs. Cold/warm switching and independent position restoration passed for Sample A, Sample B, and Sample C. Cache: \(session.documentPool.count) documents.")
        for sample in samples { print("\(sample["book"]!) cached=\(sample["cached"]!) ready=\(sample["request_to_ready_ms_including_polling"]!) ms") }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() { if Date() > deadline { throw Failure(message: "Timed out") }; try await Task.sleep(nanoseconds: 2_000_000) }
    }
    struct Failure: Error { var message: String }
}
