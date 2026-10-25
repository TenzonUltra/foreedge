import Foundation

@MainActor
final class BookSearch: ObservableObject {
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var isSearching = false
    @Published private(set) var message = ""
    private let index: SearchIndex
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(index: SearchIndex = SearchIndex()) { self.index = index }

    func cancel() { task?.cancel(); task = nil; generation = UUID(); isSearching = false; hits = []; message = "" }

    func start(_ query: String, source: PDFSource) {
        start(query, documents: [SearchDocument(source: source, title: "This book")])
    }
    func start(_ query: String, documents: [SearchDocument]) {
        cancel()
        guard !SearchText.tokens(query).isEmpty else { return }
        guard !documents.isEmpty else { message = "No books in this scope."; return }
        isSearching = true
        let request = generation, index = index
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 90_000_000)
                var descriptors: [SearchDocumentKey] = [], unavailable = 0
                for (position, document) in documents.enumerated() {
                    try Task.checkCancellation()
                    do { descriptors.append(try await index.prepare(document, priority: position == 0)) }
                    catch { unavailable += 1 }
                }
                guard !descriptors.isEmpty else {
                    self?.finish(request, message: "Couldn’t read the books in this scope."); return
                }
                while !Task.isCancelled {
                    let response = try await index.search(query, documents: descriptors)
                    guard let self, self.generation == request, !Task.isCancelled else { return }
                    self.hits = response.hits
                    let failures = unavailable + response.errors
                    let failureText = failures > 0 ? " · \(failures) unavailable book(s)" : ""
                    if response.isComplete {
                        let text: String
                        if response.textPages == 0 { text = "No extractable text. OCR is not available yet." }
                        else if response.broader && !response.hits.isEmpty { text = "No match for all words. These broader results match only part of your query." }
                        else if response.hits.isEmpty { text = "No matching passages in the indexed text." }
                        else { text = "Top \(response.hits.count) pages · ⌥← ⌥→ moves between matches on a page" }
                        self.finish(request, message: text + failureText); return
                    }
                    self.message = "Indexing once: \(response.indexedPages)/\(max(response.indexedPages, response.totalPages)) pages · Results update as text becomes available" + failureText
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch is CancellationError { }
            catch { self?.finish(request, message: "Search unavailable: \(error.localizedDescription)") }
        }
    }
    private func finish(_ request: UUID, message: String) { guard generation == request else { return }; isSearching = false; self.message = message }
}

enum BookSearchScope: String, CaseIterable { case book = "This book", collection = "Collection", library = "Library" }

/// Subsequence scoring for small lists; PDF passages use the shared full-text index.
func fuzzyScore(_ query: String, in text: String) -> Int? {
    let query = Array(query.lowercased().filter { !$0.isWhitespace })
    if query.isEmpty { return 0 }
    let text = Array(text.lowercased())
    var cursor = 0, score = 0, previous = -2
    for character in query {
        guard cursor < text.count, let index = text[cursor...].firstIndex(of: character) else { return nil }
        score += index == previous + 1 ? 10 : 1
        if index == 0 || !text[index - 1].isLetter { score += 5 }
        previous = index; cursor = index + 1
    }
    return score
}

extension ReaderSession {
    func searchDocuments(scope: BookSearchScope) -> [SearchDocument] {
        if scope == .book {
            guard let book else { return [] }
            return [SearchDocument(source: book.source, bookID: currentRecord?.id, title: book.name)]
        }
        let records = library.books(in: scope == .library ? "all" : activeScope)
        return records.sorted { ($0.id == recordID ? 1 : 0) > ($1.id == recordID ? 1 : 0) }.map {
            SearchDocument(source: .file($0.resolvedURL()), bookID: $0.id, title: $0.title)
        }
    }
    func openSearchHit(_ hit: SearchHit, occurrence: Int = 0, beside: Bool = false) {
        guard !hit.matches.isEmpty else { return }
        let match = hit.matches[min(max(0, occurrence), hit.matches.count - 1)]
        guard let bookID = hit.bookID ?? currentRecord?.id else {
            // The developer rendering fixture has no durable library identity.
            if let selection = book?.document.page(at: hit.page)?.selection(for: NSRange(location: match.offset, length: match.length)) {
                panel = nil; go(to: selection)
            }
            return
        }
        if beside, let workspace {
            panel = nil
            workspace.focus(paneID)
            if workspace.maximized { workspace.toggleMaximized() }
            if let neighbor = [PaneDirection.right, .left, .down, .up].compactMap({ workspace.neighbor($0) }).first {
                workspace.focus(neighbor, keyboard: true)
            } else { workspace.split(.horizontal) }
            workspace.reader.openSearchHit(hit, occurrence: occurrence)
            return
        }
        let viewport = bookID == currentRecord?.id ? captureLocation() : library.books.first { $0.id == bookID }?.location
        let location = BookLocation(bookID: bookID, revision: hit.revision, page: hit.page, x: 0, y: 1,
            scale: viewport?.scale ?? 1, fit: viewport?.fit ?? "width")
        let passage = PassageReference(location: location, quote: match.snippet, spans: [PassageSpan(page: hit.page, offset: match.offset, length: match.length)])
        panel = nil; pendingPassage = nil
        navigate(location)
        if isOpening { pendingPassage = passage }
        else { revealReference(passage) }
    }
}
