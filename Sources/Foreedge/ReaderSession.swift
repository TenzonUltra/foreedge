import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import os.signpost

struct ReaderBook {
    let id = UUID() // One rendering lifetime; persistent identity is stored separately.
    let document: PDFDocument
    let source: PDFSource
    let name: String
    let pageCount: Int
    let openMilliseconds: Double
    var textureKey: String = UUID().uuidString
}

enum ReaderPanel: String, Identifiable { case references, linkReference, commands, appearance, contents, find, marks, page, diagnostics, quickOpen, catalogue, collections, workspaces; var id: String { rawValue } }

@MainActor
final class ReaderSession: ObservableObject {
    @Published private(set) var book: ReaderBook?
    @Published private(set) var isOpening = false
    @Published var errorMessage: String?
    @Published var pageNumber = 1
    @Published var assignmentMilliseconds: Double = 0
    @Published private(set) var lastOpenUsedCache = false
    let context: LibraryContext
    let paneID: UUID
    weak var workspace: WorkspaceSession?
    var onStateChange: (() -> Void)?
    private var contextObservation: AnyCancellable?
    var documentPool: DocumentPool { context.documentPool }
    var isScanning: Bool { context.isScanning }
    var scanMessage: String { context.scanMessage }
    @Published private(set) var backHistory: [BookLocation] = []
    @Published private(set) var forwardHistory: [BookLocation] = []
    @Published var panel: ReaderPanel? { didSet { prefix = nil } }
    @Published var notice: String?
    @Published var referenceDraft: ReferenceDraft?
    var pendingPassage: PassageReference?
    @Published var compareSmooth = false
    var displayedAppearance: PaperAppearance {
        var result = appearance
        if compareSmooth && result.mode == .paper { result.mode = .warm }
        return result
    }
    var appearance: PaperAppearance {
        get { context.library.appearance }
        set { context.library.appearance = newValue; context.persist() }
    }
    var vimEnabled: Bool {
        get { context.library.vimEnabled }
        set { context.library.vimEnabled = newValue; context.persist() }
    }
    private(set) var library: LibraryState {
        get { context.library }
        set { context.library = newValue }
    }
    weak var pdfView: PDFView?
    private(set) var recordID: UUID?
    private var openTask: Task<Void, Never>?
    private var openRequest = UUID()
    private var saveTask: Task<Void, Never>?
    private var reattachmentLocation: BookLocation?
    private var pendingLocation: BookLocation?
    private var resizeLocation: BookLocation?
    private var resizeTask: Task<Void, Never>?
    private var suppressNavigation = false
    private var fitMode = "auto"
    private var prefix: Character?
    private var prefixDate = Date.distantPast
    let search: BookSearch
    var searchScope = BookSearchScope.book
    private var searchWarmTask: Task<Void, Never>?

    // Tests use the default in-memory session. Only the application opts into persistence.
    convenience init(store: LibraryStore? = nil, restore: Bool = false) {
        self.init(context: LibraryContext(store: store), paneID: UUID())
        backHistory = library.back; forwardHistory = library.forward
        if restore, let record = library.books.first(where: { $0.id == library.lastBookID }) { open(record.resolvedURL(), recordHistory: false) }
    }
    init(context: LibraryContext, paneID: UUID) {
        self.context = context; self.paneID = paneID
        search = BookSearch(index: context.searchIndex)
        errorMessage = context.errorMessage
        contextObservation = context.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var currentRecord: BookRecord? { library.books.first { $0.id == recordID } }
    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }
    var visibleMarks: [ReadingMark] { library.marks.filter { $0.location.bookID == recordID || $0.symbol == $0.symbol.uppercased() }.sorted { $0.symbol < $1.symbol } }

    func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open PDF"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ inputURL: URL, recordHistory: Bool = true, destination: BookLocation? = nil, historyCommit: (() -> Void)? = nil) {
        pendingPassage = nil
        searchWarmTask?.cancel()
        let url = inputURL.resolvingSymlinksInPath().standardizedFileURL
        captureAndSave()
        let departure = captureLocation()
        openTask?.cancel()
        let request = UUID()
        openRequest = request
        isOpening = true
        errorMessage = nil
        openTask = Task { [weak self] in
            let result: Result<LoadedBook, Error>
            var usedCache = false
            do {
                let started = ProcessInfo.processInfo.systemUptime
                let metadata = try await PDFLoader.shared.inspect(url)
                try Task.checkCancellation()
                if let cached = self?.documentPool.lookup(metadata) {
                    usedCache = true
                    result = .success(LoadedBook(book: ReaderBook(document: cached.document, source: .file(metadata.url),
                        name: cached.name, pageCount: cached.pageCount, openMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000, textureKey: cached.textureKey),
                        metadata: metadata))
                } else {
                    guard let pool = self?.documentPool else { throw CancellationError() }
                    let loaded = try await pool.load(metadata)
                    result = .success(LoadedBook(book: ReaderBook(document: loaded.document, source: loaded.source,
                        name: loaded.name, pageCount: loaded.pageCount, openMilliseconds: loaded.openMilliseconds, textureKey: loaded.textureKey), metadata: metadata))
                }
            }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.openRequest == request else { return }
            self.isOpening = false
            switch result {
            case .success(let loaded):
                if let destination, destination.revision != loaded.metadata.revision {
                    self.pendingPassage = nil
                    self.errorMessage = "This PDF has changed since that location was saved. Open the book normally to choose a new location."
                    return
                }
                self.lastOpenUsedCache = usedCache
                self.documentPool.insert(loaded.book, metadata: loaded.metadata)
                self.documentPool.retain(loaded.book, metadata: loaded.metadata, owner: self.paneID)
                if loaded.book.document === self.book?.document, destination == nil, historyCommit == nil { return }
                self.search.cancel()
                if recordHistory, let departure { self.appendBack(departure); self.forwardHistory.removeAll() }
                historyCommit?()
                let existing = self.library.books.firstIndex {
                    $0.path == url.standardizedFileURL.path ||
                    (loaded.metadata.resourceID != nil && $0.resourceID == loaded.metadata.resourceID) ||
                    $0.resolvedURL().standardizedFileURL == url.standardizedFileURL
                }
                var record = existing.map { self.library.books[$0] } ?? BookRecord(id: UUID(), path: url.path, revision: loaded.metadata.revision, title: loaded.book.name, lastOpened: Date())
                if record.revision != loaded.metadata.revision {
                    record.location = nil
                    self.notice = "The PDF changed; the old reading position was not restored."
                }
                record.path = url.standardizedFileURL.path
                record.bookmark = loaded.metadata.bookmark
                record.resourceID = loaded.metadata.resourceID
                record.revision = loaded.metadata.revision
                record.lastOpened = Date()
                record.title = loaded.book.name
                record.fileSize = loaded.metadata.size
                record.pageCount = loaded.book.pageCount
                record.author = loaded.book.document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
                record.missing = false
                if let existing { self.library.books[existing] = record } else { self.library.books.append(record) }
                self.recordID = record.id
                self.library.lastBookID = record.id
                self.resizeTask?.cancel(); self.resizeLocation = nil
                self.reattachmentLocation = nil
                self.pendingLocation = destination ?? record.location
                self.pageNumber = 1
                self.fitMode = self.pendingLocation?.fit ?? "auto"
                self.assignmentMilliseconds = 0
                self.book = loaded.book
                self.searchWarmTask?.cancel()
                let index = self.context.searchIndex
                let searchable = SearchDocument(source: loaded.book.source, bookID: record.id, title: record.title)
                self.searchWarmTask = Task(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    _ = try? await index.prepare(searchable, priority: true)
                }
                self.persist()
                NSLog("PDF prepared: %d pages, %.2f ms open/parse (not first-frame latency)", loaded.book.pageCount, loaded.book.openMilliseconds)
            case .failure(let error): self.pendingPassage = nil; self.errorMessage = error.localizedDescription
            }
        }
    }

    func showBaseline() {
        captureAndSave()
        openTask?.cancel(); openRequest = UUID(); isOpening = false
        search.cancel(); documentPool.release(owner: paneID)
        do {
            let document = try BaselineDocument.make()
            guard let data = document.dataRepresentation() else { throw OpenError.invalid }
            recordID = nil; pendingLocation = nil; pageNumber = 1
            book = ReaderBook(document: document, source: .data(data), name: "Paper study", pageCount: 1, openMilliseconds: 0)
        } catch { errorMessage = error.localizedDescription }
    }

    func viewDidAssign() {
        guard let view = pdfView, view.document === book?.document else { return }
        // SwiftUI can assign the document before the split tree has its final frames.
        view.window?.contentView?.layoutSubtreeIfNeeded()
        if let pendingLocation { restore(pendingLocation); self.pendingLocation = nil }
        if let passage = pendingPassage { pendingPassage = nil; revealReference(passage) }
        captureAndSave()
        if workspace?.activePaneID == paneID, panel == nil { view.window?.makeFirstResponder(view) }
    }

    func captureLocation() -> BookLocation? {
        if let resizeLocation { return resizeLocation }
        guard let record = currentRecord, let view = pdfView, view.document === book?.document,
              let page = view.page(for: CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 1), nearest: true),
              let document = view.document else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let point = view.convert(CGPoint(x: view.bounds.minX, y: view.bounds.maxY), to: page)
        let mode = view.autoScales ? "auto" : (fitMode == "width" && abs(view.scaleFactor - widthScale(view, page)) < 0.02 ? "width" : "manual")
        return BookLocation(bookID: record.id, revision: record.revision, page: document.index(for: page),
                            x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height,
                            scale: view.scaleFactor, fit: mode)
    }

    func viewportChanged() {
        guard pendingLocation == nil, resizeLocation == nil, !suppressNavigation else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.captureAndSave()
        }
    }

    func captureAndSave() {
        guard pendingLocation == nil, resizeLocation == nil, let location = captureLocation(), let index = library.books.firstIndex(where: { $0.id == location.bookID }) else { return }
        library.books[index].location = location
        persist()
    }

    func flush() { saveTask?.cancel(); captureAndSave(); context.flush() }

    private func persist() {
        // Retain the legacy single-reader resume state for standalone tools and migration.
        if workspace == nil { library.back = backHistory; library.forward = forwardHistory }
        context.persist()
        onStateChange?()
    }

    func snapshot(id: UUID) -> ReadingTabState {
        ReadingTabState(id: id, bookID: recordID, location: pendingLocation ?? (pdfView?.window != nil ? captureLocation() : nil) ?? reattachmentLocation, back: backHistory, forward: forwardHistory)
    }
    func restoreTab(_ tab: ReadingTabState) {
        suspend()
        backHistory = tab.back; forwardHistory = tab.forward
        guard let id = tab.bookID, let record = library.books.first(where: { $0.id == id }) else { return }
        open(record.resolvedURL(), recordHistory: false, destination: tab.location)
    }
    func prepareForReattachment() {
        if pdfView?.window != nil, let location = captureLocation() { reattachmentLocation = location }
        else { reattachmentLocation = pendingLocation ?? reattachmentLocation }
    }
    func attachView(_ view: PDFView) {
        if pdfView !== view {
            pendingLocation = pendingLocation ?? resizeLocation
            resizeTask?.cancel(); resizeLocation = nil
        }
        pendingLocation = pendingLocation ?? reattachmentLocation; reattachmentLocation = nil
        pdfView = view
        if let reader = view as? ReaderPDFView {
            reader.onWillResize = { [weak self, weak view] in
                guard let self, let view, self.pdfView === view, self.pendingLocation == nil,
                      self.resizeLocation == nil, view.bounds.width > 0, view.bounds.height > 0 else { return }
                self.resizeLocation = self.captureLocation()
                self.saveTask?.cancel()
            }
            reader.onDidResize = { [weak self, weak view] in
                guard let self, let view, self.pdfView === view, self.resizeLocation != nil else { return }
                // Coalesce frame changes from one layout pass before refitting. Keep the
                // pre-resize anchor available to persistence until the final frame is ready.
                self.resizeTask?.cancel()
                self.resizeTask = Task { @MainActor [weak self, weak view] in
                    guard !Task.isCancelled, let self, let view, self.pdfView === view else { return }
                    view.window?.contentView?.layoutSubtreeIfNeeded()
                    guard !Task.isCancelled, let location = self.resizeLocation else { return }
                    self.restore(location)
                    self.resizeLocation = nil
                    self.viewportChanged()
                }
            }
        }
    }
    func detachView(_ view: PDFView) {
        guard pdfView === view else { return }
        reattachmentLocation = reattachmentLocation ?? pendingLocation ?? captureLocation()
        resizeTask?.cancel(); resizeLocation = nil
        pdfView = nil
    }
    func suspend() {
        searchWarmTask?.cancel()
        pendingPassage = nil
        resizeTask?.cancel(); resizeLocation = nil
        saveTask?.cancel(); openTask?.cancel(); openRequest = UUID(); search.cancel()
        documentPool.release(owner: paneID)
        reattachmentLocation = nil; pdfView = nil; book = nil; recordID = nil; pendingLocation = nil; isOpening = false
        backHistory = []; forwardHistory = []; panel = nil
    }

    func recordDeparture() {
        guard !suppressNavigation, let location = captureLocation() else { return }
        appendBack(location)
        forwardHistory.removeAll()
        persist()
    }

    private func appendBack(_ location: BookLocation) {
        if backHistory.last != location { backHistory.append(location) }
        if backHistory.count > 200 { backHistory.removeFirst(backHistory.count - 200) }
    }

    func back() { travelHistory(backward: true) }
    func forward() { travelHistory(backward: false) }
    private func travelHistory(backward: Bool) {
        guard !isOpening, let target = backward ? backHistory.last : forwardHistory.last else { return }
        let current = captureLocation()
        navigate(target, recordHistory: false) { [weak self] in
            guard let self else { return }
            if backward {
                self.backHistory.removeLast()
                if let current { self.forwardHistory.append(current) }
            } else {
                self.forwardHistory.removeLast()
                if let current { self.appendBack(current) }
            }
            self.persist()
        }
    }

    func navigate(_ target: BookLocation, recordHistory: Bool = true, completion: (() -> Void)? = nil) {
        guard let record = library.books.first(where: { $0.id == target.bookID }) else { return }
        if target.bookID == recordID {
            guard target.revision == currentRecord?.revision else { errorMessage = "This saved location belongs to an older version of the PDF."; return }
            if recordHistory { recordDeparture() }
            completion?()
            restore(target)
            viewportChanged()
        } else { open(record.resolvedURL(), recordHistory: recordHistory, destination: target, historyCommit: completion) }
    }

    private func restore(_ location: BookLocation) {
        guard let view = pdfView, let page = view.document?.page(at: location.page) else { return }
        suppressNavigation = true
        defer { suppressNavigation = false }
        fitMode = location.fit
        if location.fit == "auto" { view.autoScales = true }
        else {
            view.autoScales = false
            view.scaleFactor = location.fit == "width" ? widthScale(view, page) : min(view.maxScaleFactor, max(view.minScaleFactor, location.scale))
        }
        view.layoutDocumentView()
        let bounds = page.bounds(for: .mediaBox)
        view.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX + location.x * bounds.width, y: bounds.minY + location.y * bounds.height)))
    }

    func go(to number: Int) {
        guard let book, let view = pdfView, let page = book.document.page(at: min(max(number - 1, 0), book.pageCount - 1)) else { return }
        jump { view.go(to: page) }
    }

    func go(to destination: PDFDestination) { guard let view = pdfView else { return }; jump { view.go(to: destination) } }
    func go(to selection: PDFSelection) {
        guard let view = pdfView else { return }
        jump { view.setCurrentSelection(selection, animate: false); view.go(to: selection) }
    }
    private func jump(_ action: () -> Void) {
        recordDeparture(); suppressNavigation = true; action(); suppressNavigation = false; viewportChanged()
    }

    func go(toLabel input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document = book?.document else { return }
        if value.hasPrefix("#"), let number = Int(value.dropFirst()) { go(to: number); return }
        for index in 0..<document.pageCount where document.page(at: index)?.label?.lowercased() == value.lowercased() { go(to: index + 1); return }
        if let number = Int(value) { go(to: number) }
        else { notice = "No page labeled ‘\(value)’. Use #12 for PDF page 12." }
    }

    func nextPage() { if pageNumber < (book?.pageCount ?? 0) { go(to: pageNumber + 1) } }
    func previousPage() { if pageNumber > 1 { go(to: pageNumber - 1) } }
    func fitWidth() {
        guard let view = pdfView, let page = view.currentPage else { return }
        // Refit around the current reading position, not PDFKit's zoom center.
        if var location = captureLocation() {
            location.fit = "width"
            restore(location)
        } else {
            fitMode = "width"; view.autoScales = false; view.scaleFactor = widthScale(view, page)
        }
        viewportChanged()
    }
    private func widthScale(_ view: PDFView, _ page: PDFPage) -> Double {
        let bounds = page.bounds(for: view.displayBox)
        let width = page.rotation % 180 == 0 ? bounds.width : bounds.height
        return max(view.minScaleFactor, min(view.maxScaleFactor, (view.bounds.width - 32) / max(1, width)))
    }

    func setMark(_ symbol: String) {
        guard symbol.count == 1, symbol.range(of: "^[a-zA-Z]$", options: .regularExpression) != nil, let location = captureLocation() else { return }
        let id = symbol == symbol.uppercased() ? symbol : "\(location.bookID):\(symbol)"
        library.marks.removeAll { $0.id == id }
        library.marks.append(ReadingMark(id: id, symbol: symbol, location: location))
        notice = "Set mark \(symbol)"; persist()
    }
    func jumpMark(_ symbol: String) {
        let id = symbol == symbol.uppercased() ? symbol : "\(recordID?.uuidString ?? ""):\(symbol)"
        guard let mark = library.marks.first(where: { $0.id == id }) else { notice = "No mark \(symbol)"; return }
        navigate(mark.location)
    }
    func deleteMark(_ id: String) { library.marks.removeAll { $0.id == id }; persist() }

    func handleKey(_ event: NSEvent) -> Bool {
        guard vimEnabled, panel == nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        guard let key = event.characters?.first else { return false }
        if event.keyCode == 53 { prefix = nil; notice = nil; return true }
        if let pending = prefix, Date().timeIntervalSince(prefixDate) < 3 {
            prefix = nil
            if key.isASCII && key.isLetter { if pending == "m" { setMark(String(key)) } else { jumpMark(String(key)) }; return true }
        }
        prefix = nil
        switch key {
        case "m", "`": prefix = key; prefixDate = Date(); notice = key == "m" ? "Set mark: a–z local, A–Z global · Esc cancels" : "Jump to mark…"; return true
        case "j": pdfView?.scrollLineDown(nil); return true
        case "k": pdfView?.scrollLineUp(nil); return true
        case "/": panel = .find; return true
        default: return false
        }
    }

    enum OpenError: LocalizedError {
        case invalid, locked, empty
        var errorDescription: String? {
            switch self {
            case .invalid: return "This file couldn’t be opened as a PDF."
            case .locked: return "This PDF is password protected. Please open an unlocked copy."
            case .empty: return "This PDF doesn’t contain any pages."
            }
        }
    }
}

struct LoadedBook {
    var book: ReaderBook
    var metadata: DiscoveredFile
}

actor PDFLoader {
    static let shared = PDFLoader()
    func inspect(_ url: URL) throws -> DiscoveredFile { try Task.checkCancellation(); return try DiscoveredFile.read(url) }
    func load(_ url: URL, metadata: DiscoveredFile) throws -> LoadedBook {
        try Task.checkCancellation()
        let start = ProcessInfo.processInfo.systemUptime
        let log = OSLog(subsystem: "io.github.tenzonultra.foreedge", category: .pointsOfInterest)
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Open PDF", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Open PDF", signpostID: signpost) }
        guard let document = PDFDocument(url: url) else { throw ReaderSession.OpenError.invalid }
        guard !document.isLocked else { throw ReaderSession.OpenError.locked }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ReaderSession.OpenError.empty }
        try Task.checkCancellation()
        return LoadedBook(book: ReaderBook(document: document, source: .file(url), name: url.lastPathComponent, pageCount: pageCount,
                                           openMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, textureKey: "\(metadata.resourceID ?? url.path):\(metadata.revision)"), metadata: metadata)
    }
}


extension ReaderSession {
    var activeScope: String { context.activeScope }
    var activeScopeName: String { context.activeScopeName }
    func selectScope(_ id: String) { context.selectScope(id) }
    func openBook(_ id: UUID) {
        guard let record = library.books.first(where: { $0.id == id }) else { return }
        panel = nil
        open(record.resolvedURL())
    }
    @discardableResult func createCollection(_ name: String) -> UUID? { context.createCollection(name) }
    func renameCollection(_ id: UUID, to name: String) { context.renameCollection(id, to: name) }
    func deleteCollection(_ id: UUID) { context.deleteCollection(id) }
    func setMembership(_ ids: Set<UUID>, collectionID: UUID, included: Bool) { context.setMembership(ids, collectionID: collectionID, included: included) }
    func chooseFolder() { context.chooseFolder() }
    func registerFolder(_ url: URL) { context.registerFolder(url) }
    func removeFolder(_ id: UUID) { context.removeFolder(id) }
    func startCatalogue(defaultFolder: URL? = nil) { context.startCatalogue(defaultFolder: defaultFolder) }
    func cancelScan() { context.cancelScan() }
    func refreshLibrary() { context.refreshLibrary() }
}
