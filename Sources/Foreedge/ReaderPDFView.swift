import AppKit
import PDFKit

/// Intercept native PDF links and keyboard navigation before PDFKit moves the viewport.
final class ReaderPDFView: PDFView {
    var onWillNavigate: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onWillResize: () -> Void = {}
    var onDidResize: () -> Void = {}

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        if changed { onWillResize() }
        super.setFrameSize(newSize)
        if changed { onDidResize() }
    }

    override func layout() {
        super.layout()
        hideScrollbars()
    }
    override func layoutDocumentView() {
        super.layoutDocumentView()
        hideScrollbars()
    }
    func hideScrollbars() {
        // PDFKit creates/replaces this scroll view while assigning and laying out documents.
        // Keep native scrolling, but reserve no space for scroller chrome.
        if let scroll = documentView?.enclosingScrollView {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        }
    }
    private var navigationDepth = 0
    private func navigating(_ body: () -> Void) {
        if navigationDepth == 0 { onWillNavigate() }
        navigationDepth += 1
        defer { navigationDepth -= 1 }
        body()
    }
    override func go(to destination: PDFDestination) { navigating { super.go(to: destination) } }
    override func go(to page: PDFPage) { navigating { super.go(to: page) } }
    override func go(to selection: PDFSelection) { navigating { super.go(to: selection) } }
    override func go(to rect: CGRect, on page: PDFPage) { navigating { super.go(to: rect, on: page) } }
    override func keyDown(with event: NSEvent) { if !onKey(event) { super.keyDown(with: event) } }
}
