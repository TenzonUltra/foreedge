import AppKit
import PDFKit

/// Durable anchors are independent of panes and links. Text ranges are valid only for this revision.
struct PassageSpan: Codable, Equatable {
    var page: Int
    var offset: Int
    var length: Int
}
struct PassageReference: Codable, Identifiable, Equatable {
    var id = UUID()
    var location: BookLocation
    var quote: String
    var spans: [PassageSpan]
    var created = Date()
    var url: URL { URL(string: "foreedge://reference/\(id.uuidString)")! }

    static func id(from url: URL) -> UUID? {
        guard ["foreedge", "paperman"].contains(url.scheme?.lowercased() ?? ""),
              url.host == "reference", url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    func covers(page: Int) -> Bool { location.page == page || spans.contains { $0.page == page } }
}
struct ReadingReferenceLink: Codable, Identifiable {
    var id = UUID()
    var sourceID: UUID
    var targetID: UUID
    var note: String
    var created = Date()
    // Keep personal assertions separate from any future inferred relationships.
    var provenance = "user"
}
struct ReferenceDraft {
    var sourceID: UUID
    var target: PassageReference
}
struct ReferenceRow: Identifiable {
    var link: ReadingReferenceLink
    var endpoint: PassageReference
    var incoming: Bool
    var id: String { "\(link.id):\(incoming)" }
}
enum ReferenceScope: String, CaseIterable { case page = "This page", book = "This book", all = "All links" }

extension LibraryState {
    func reference(_ id: UUID) -> PassageReference? { references.first { $0.id == id } }
    func referenceTitle(_ reference: PassageReference) -> String {
        let title = books.first { $0.id == reference.location.bookID }?.title ?? "Unavailable book"
        return "\(title) · PDF page \(reference.location.page + 1)"
    }
    func referenceRows(bookID: UUID?, page: Int?, scope: ReferenceScope) -> [ReferenceRow] {
        let anchors = Dictionary(references.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func matches(_ ref: PassageReference) -> Bool {
            ref.location.bookID == bookID && (scope == .book || page.map { ref.covers(page: $0) } == true)
        }
        return referenceLinks.sorted { $0.created > $1.created }.flatMap { link -> [ReferenceRow] in
            guard let source = anchors[link.sourceID], let target = anchors[link.targetID] else { return [] }
            var rows: [ReferenceRow] = []
            if scope == .all || matches(source) { rows.append(ReferenceRow(link: link, endpoint: target, incoming: false)) }
            if scope != .all && matches(target) { rows.append(ReferenceRow(link: link, endpoint: source, incoming: true)) }
            return rows
        }
    }
}

extension LibraryContext {
    @discardableResult func retainReference(_ candidate: PassageReference) -> PassageReference {
        if let existing = library.references.first(where: {
            $0.location.bookID == candidate.location.bookID && $0.location.revision == candidate.location.revision &&
            $0.spans == candidate.spans && $0.location.page == candidate.location.page &&
            (!candidate.spans.isEmpty || (abs($0.location.x - candidate.location.x) < 0.002 && abs($0.location.y - candidate.location.y) < 0.002))
        }) { return existing }
        library.references.append(candidate); persist(); return candidate
    }
    @discardableResult func saveReferenceLink(_ draft: ReferenceDraft, note: String) -> ReadingReferenceLink? {
        guard library.reference(draft.sourceID) != nil else { return nil }
        let target = retainReference(draft.target)
        guard target.id != draft.sourceID else { return nil }
        let note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        if let index = library.referenceLinks.firstIndex(where: { $0.sourceID == draft.sourceID && $0.targetID == target.id }) {
            library.referenceLinks[index].note = note; persist(); return library.referenceLinks[index]
        }
        let link = ReadingReferenceLink(sourceID: draft.sourceID, targetID: target.id, note: note)
        library.referenceLinks.append(link); persist(); return link
    }
    func updateReferenceNote(_ id: UUID, note: String) {
        guard let index = library.referenceLinks.firstIndex(where: { $0.id == id }) else { return }
        library.referenceLinks[index].note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000)); persist()
    }
    func deleteReferenceLink(_ id: UUID) {
        library.referenceLinks.removeAll { $0.id == id }; persist()
    }
}

extension ReaderSession {
    static let referencePasteboardType = NSPasteboard.PasteboardType("io.github.tenzonultra.foreedge.reference")
    static let legacyReferencePasteboardType = NSPasteboard.PasteboardType("dev.local.paperman.reference")

    func captureReference() -> PassageReference? {
        guard !isOpening, var location = captureLocation(), let document = book?.document else { return nil }
        var spans: [PassageSpan] = []
        var quote = ""
        if let selection = pdfView?.currentSelection {
            // Bound explicit capture work even if the user selected an entire book.
            for page in selection.pages.prefix(16) {
                let index = document.index(for: page)
                guard index != NSNotFound else { continue }
                for rangeIndex in 0..<min(selection.numberOfTextRanges(on: page), 64 - spans.count) {
                    let range = selection.range(at: rangeIndex, on: page)
                    if range.location != NSNotFound, range.length > 0 {
                        spans.append(PassageSpan(page: index, offset: range.location, length: range.length))
                    }
                }
                if spans.count == 64 { break }
            }
            if let first = spans.first, let page = document.page(at: first.page) {
                let box = page.bounds(for: .mediaBox), selected = selection.bounds(for: page)
                location.page = first.page
                location.x = 0
                location.y = (selected.maxY - box.minY + 16) / box.height
                // Extract only a bounded preview rather than materializing a whole-book selection.
                quote = spans.prefix(8).compactMap { span in
                    document.page(at: span.page)?.selection(for: NSRange(location: span.offset, length: min(span.length, 500)))?.string
                }.joined(separator: " ")
                quote = String(quote.prefix(2000))
            }
        }
        return PassageReference(location: location, quote: quote, spans: spans)
    }
    @discardableResult func copyReference(to pasteboard: NSPasteboard = .general) -> PassageReference? {
        guard let captured = captureReference() else { return nil }
        let ref = context.retainReference(captured)
        pasteboard.clearContents()
        pasteboard.setString(ref.id.uuidString, forType: Self.referencePasteboardType)
        let quote = ref.quote.isEmpty ? "" : "\n\(ref.quote)"
        pasteboard.setString("\(library.referenceTitle(ref))\(quote)\n\(ref.url.absoluteString)", forType: .string)
        notice = "Reference copied · Go to its destination and press ⇧⌘L"
        return ref
    }
    func copiedReference(from pasteboard: NSPasteboard = .general) -> PassageReference? {
        for type in [Self.referencePasteboardType, Self.legacyReferencePasteboardType] {
            if let value = pasteboard.string(forType: type), let id = UUID(uuidString: value) { return library.reference(id) }
        }
        guard let text = pasteboard.string(forType: .string), let line = text.split(separator: "\n").last,
              let url = URL(string: String(line)), let id = PassageReference.id(from: url) else { return nil }
        return library.reference(id)
    }
    func beginReferenceLink(from pasteboard: NSPasteboard = .general) {
        guard let source = copiedReference(from: pasteboard) else { notice = "Copy a passage reference first with ⇧⌘C."; return }
        guard let target = captureReference() else { return }
        referenceDraft = ReferenceDraft(sourceID: source.id, target: target)
        panel = .linkReference
    }
    @discardableResult func commitReferenceLink(note: String) -> Bool {
        guard let referenceDraft else { return false }
        guard context.saveReferenceLink(referenceDraft, note: note) != nil else {
            notice = "Choose a different passage for the other end of the link."; return false
        }
        self.referenceDraft = nil; panel = nil; notice = "Passages linked · ⇧⌘R shows references and backlinks"; return true
    }
    func openReferenceURL(_ url: URL) {
        guard let id = PassageReference.id(from: url) else { notice = "This is not a Foreedge passage reference."; return }
        followReference(id)
    }
    func followReference(_ id: UUID, beside: Bool = false) {
        guard let reference = library.reference(id), library.books.contains(where: { $0.id == reference.location.bookID }) else {
            notice = "This passage reference is not in this library."; return
        }
        if beside, let workspace {
            panel = nil
            workspace.openReferenceBeside(id, from: paneID)
            return
        }
        panel = nil
        pendingPassage = nil
        navigate(reference.location)
        if isOpening { pendingPassage = reference }
        else if currentRecord?.id == reference.location.bookID, currentRecord?.revision == reference.location.revision {
            revealReference(reference)
        }
    }
    func revealReference(_ reference: PassageReference) {
        guard let view = pdfView, let document = book?.document,
              currentRecord?.id == reference.location.bookID, currentRecord?.revision == reference.location.revision else { return }
        let selection = PDFSelection(document: document)
        for span in reference.spans {
            guard let page = document.page(at: span.page), span.offset >= 0, span.length > 0,
                  span.offset <= page.numberOfCharacters, span.length <= page.numberOfCharacters - span.offset,
                  let part = page.selection(for: NSRange(location: span.offset, length: span.length)) else { continue }
            selection.add(part)
        }
        // The jump itself has already recorded history; highlighting is part of that same jump.
        if let native = view as? ReaderPDFView {
            let callback = native.onWillNavigate; native.onWillNavigate = {}
            defer { native.onWillNavigate = callback }
            view.setCurrentSelection(selection.pages.isEmpty ? nil : selection, animate: false)
            if !selection.pages.isEmpty { view.go(to: selection) }
        }
        viewportChanged()
    }
}

extension WorkspaceSession {
    func openReferenceBeside(_ id: UUID, from sourcePaneID: UUID) {
        focus(sourcePaneID)
        if maximized { toggleMaximized() }
        if let neighbor = [PaneDirection.right, .left, .down, .up].compactMap({ neighbor($0) }).first {
            focus(neighbor, keyboard: true)
        } else { split(.horizontal) }
        reader.followReference(id)
    }
}
