import AppKit
import PDFKit

@main
enum BookBenchmark {
    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { fatalError("Usage: book-check output-directory book.pdf ...") }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let base = try await PaperWorker.shared.baseTexture()
        let session = ReaderSession()
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 820, height: 900))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .mediaBox
        let coordinator = PDFSurface.Coordinator(appearance: PaperAppearance(), texture: base)
        coordinator.attach(view)
        coordinator.onPageChange = { session.pageNumber = $0 }
        view.pageOverlayViewProvider = coordinator
        session.pdfView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Foreedge book responsiveness check"
        window.contentView = view
        window.orderBack(nil)
        var results: [[String: Any]] = []

        for path in arguments.dropFirst(2) {
            let url = URL(fileURLWithPath: path)
            session.open(url)
            guard await waitFor({ !session.isOpening }), let book = session.book, session.errorMessage == nil else {
                throw NSError(domain: "BookBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: session.errorMessage ?? "Opening timed out"])
            }
            coordinator.setDocument(source: book.source, id: book.id)
            coordinator.update(appearance: PaperAppearance(), texture: base)
            let assignStart = ProcessInfo.processInfo.systemUptime
            view.document = book.document
            view.autoScales = true
            let assignment = (ProcessInfo.processInfo.systemUptime - assignStart) * 1000
            guard await waitFor({ !view.visiblePages.isEmpty }) else { fatalError("No visible page") }
            session.fitWidth()
            var navigationCalls: [Double] = []
            let samplePages = Array(Set([1, min(20, book.pageCount), max(1, book.pageCount / 2), book.pageCount])).sorted()
            for pageNumber in samplePages {
                let start = ProcessInfo.processInfo.systemUptime
                session.go(to: pageNumber)
                navigationCalls.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                guard await waitFor({ session.pageNumber == pageNumber }) else { fatalError("Page navigation timed out") }
            }

            // Same region, same viewport, same scripted scroll distance for each appearance.
            // Warm PDF/OS caches and test order affect these samples. Gaps are main-thread
            // scheduling observations, not frame presentation or a trackpad gesture benchmark.
            var scrollResults: [[String: Any]] = []
            for mode in [PaperMode.plain, .paper, .plain, .paper] {
                coordinator.update(appearance: PaperAppearance(mode: mode), texture: base)
                session.go(to: min(20, book.pageCount))
                _ = await waitFor { session.pageNumber == min(20, book.pageCount) }
                pumpEvents()
                var gaps: [Double] = []
                var previous = ProcessInfo.processInfo.systemUptime
                if let scroll = view.documentView?.enclosingScrollView {
                    for _ in 0..<90 {
                        try await Task.sleep(nanoseconds: 16_666_667)
                        let now = ProcessInfo.processInfo.systemUptime
                        gaps.append((now - previous) * 1000)
                        previous = now
                        let clip = scroll.contentView
                        let old = clip.bounds.origin
                        let documentHeight = scroll.documentView?.bounds.height ?? 0
                        let nextY = min(max(0, documentHeight - clip.bounds.height), old.y + 24)
                        clip.scroll(to: CGPoint(x: old.x, y: nextY))
                        scroll.reflectScrolledClipView(clip)
                    }
                }
                gaps.sort()
                guard !gaps.isEmpty else { fatalError("No native scroll view") }
                scrollResults.append([
                    "mode": mode.rawValue, "samples": gaps.count,
                    "main_thread_gap_median_ms": gaps[gaps.count / 2],
                    "main_thread_gap_p95_ms": gaps[Int(Double(gaps.count - 1) * 0.95)],
                    "main_thread_gap_max_ms": gaps.last!
                ])
            }
            coordinator.update(appearance: PaperAppearance(experiment: .adaptive), texture: base)
            var adaptiveWaits: [Double] = []
            for pageNumber in samplePages {
                session.go(to: pageNumber)
                let start = ProcessInfo.processInfo.systemUptime
                guard await waitFor({ coordinator.cachedPages.contains(pageNumber - 1) }) else { fatalError("Adaptive page timed out") }
                adaptiveWaits.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                guard coordinator.cachedPageCount <= 6 else { fatalError("Unbounded adaptive cache") }
            }
            let metadata = try FileManager.default.attributesOfItem(atPath: path)
            let row: [String: Any] = [
                "book": url.lastPathComponent, "bytes": metadata[.size] as? Int ?? 0,
                "pages": book.pageCount, "open_parse_cpu_ms": book.openMilliseconds,
                "assign_pdfview_cpu_ms": assignment, "sample_pages": samplePages,
                "navigation_call_cpu_ms": navigationCalls,
                "scripted_scroll": scrollResults,
                "adaptive_wait_ms_including_navigation_and_polling": adaptiveWaits,
                "adaptive_cached_pages": coordinator.cachedPageCount
            ]
            results.append(row)
            print("Checked \(url.lastPathComponent): \(book.pageCount) pages, \(String(format: "%.1f", book.openMilliseconds)) ms open/parse, \(String(format: "%.1f", assignment)) ms assign")
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("results.json"))
        }
        coordinator.shutdown()
        view.pageOverlayViewProvider = nil
        window.orderOut(nil)
        window.close()
        print("Real-book checks passed. Scripted-scroll gaps are NOT GPU/display frame times.")
    }

    @MainActor
    private static func waitFor(_ condition: () -> Bool, seconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            pumpEvents()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private static func pumpEvents() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
}
