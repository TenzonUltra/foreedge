import AppKit
import Combine

/// One owner for library metadata, discovery, preferences, and shared document resources.
@MainActor
final class LibraryContext: ObservableObject {
    @Published var library = LibraryState()
    @Published var isScanning = false
    @Published var scanMessage = ""
    @Published var notice: String?
    @Published var errorMessage: String?
    let documentPool = DocumentPool()
    let searchIndex: SearchIndex
    private var store: LibraryStore?
    private var scanTask: Task<Void, Never>?
    private var scanRequest = UUID()
    private var catalogueStarted = false
    var onChange: (() -> Void)?

    init(store: LibraryStore? = nil) {
        searchIndex = SearchIndex(url: store?.searchIndexURL)
        do {
            if let store { library = try store.load(); self.store = store }
        } catch { errorMessage = error.localizedDescription }
    }
    func persist() { save(); onChange?() }
    func save() {
        store?.save(library) { [weak self] error in
            if let error { Task { @MainActor [weak self] in self?.errorMessage = error } }
        }
    }
    func flush() { store?.flush() }
}

extension LibraryContext {
    var activeScope: String { library.scopes.contains { $0.id == library.activeScope } ? library.activeScope : "all" }
    var activeScopeName: String { library.scopes.first { $0.id == activeScope }?.name ?? "All Books" }
    func selectScope(_ id: String) {
        guard library.activeScope != id, library.scopes.contains(where: { $0.id == id }) else { return }
        library.activeScope = id; persist()
    }
    @discardableResult
    func createCollection(_ name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !library.collections.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            notice = "A collection named ‘\(name)’ already exists."; return nil
        }
        let collection = BookCollection(name: name)
        library.collections.append(collection)
        library.activeScope = "collection:\(collection.id)"
        persist(); return collection.id
    }
    func renameCollection(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = library.collections.firstIndex(where: { $0.id == id }) else { return }
        guard !library.collections.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            notice = "That collection name is already in use."; return
        }
        library.collections[index].name = name; persist()
    }
    func deleteCollection(_ id: UUID) {
        library.collections.removeAll { $0.id == id }
        if library.activeScope == "collection:\(id)" { library.activeScope = "all" }
        persist()
    }
    func setMembership(_ bookIDs: Set<UUID>, collectionID: UUID, included: Bool) {
        guard let index = library.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        let known = bookIDs.intersection(Set(library.books.map(\.id)))
        if included { library.collections[index].bookIDs.formUnion(known) }
        else { library.collections[index].bookIDs.subtract(known) }
        persist()
    }
    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.prompt = "Add Folder"
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            Task { @MainActor in self?.registerFolder(url) }
        }
    }
    func registerFolder(_ input: URL) {
        let url = input.resolvingSymlinksInPath().standardizedFileURL
        if let folder = library.folders.first(where: { $0.resolvedURL().resolvingSymlinksInPath().standardizedFileURL == url }) {
            selectScope("folder:\(folder.id)"); refreshLibrary(); return
        }
        // Directory bookmark creation can block in getxattr/TCC before a window is visible.
        // Register the path immediately; file-level identity is discovered off the main actor.
        let folder = LibraryFolder(path: url.path)
        library.folders.append(folder)
        library.activeScope = "folder:\(folder.id)"
        persist(); refreshLibrary()
    }
    func removeFolder(_ id: UUID) {
        cancelScan()
        library.folders.removeAll { $0.id == id }
        if library.activeScope == "folder:\(id)" { library.activeScope = "all" }
        persist()
    }
    func startCatalogue(defaultFolder: URL? = nil) {
        guard !catalogueStarted else { return }
        catalogueStarted = true
        if !library.didOfferDefaultFolder {
            library.didOfferDefaultFolder = true
            if library.folders.isEmpty, let defaultFolder, FileManager.default.fileExists(atPath: defaultFolder.path) {
                registerFolder(defaultFolder); return
            }
            persist()
        }
        if !library.folders.isEmpty { refreshLibrary() }
    }
    func cancelScan() {
        scanTask?.cancel(); scanTask = nil; scanRequest = UUID(); isScanning = false
        scanMessage = "Scan stopped. Existing books and collections are retained."
    }
    func refreshLibrary() {
        scanTask?.cancel()
        let request = UUID(); scanRequest = request
        let folders = library.folders
        guard !folders.isEmpty else { scanMessage = "Add a folder to discover books."; return }
        isScanning = true; scanMessage = "Looking for PDFs…"
        scanTask = Task { [weak self] in
            var warnings = 0, failed = 0
            for folder in folders {
                guard !Task.isCancelled, let self else { return }
                do {
                    let discovery = try await CatalogueScanner.scan(folder, knownBooks: self.library.books)
                    guard !Task.isCancelled, self.scanRequest == request else { return }
                    warnings += discovery.warnings
                    self.mergeDiscovery(discovery, folderID: folder.id)
                } catch {
                    guard !Task.isCancelled, self.scanRequest == request else { return }
                    failed += 1
                }
            }
            guard let self, !Task.isCancelled, self.scanRequest == request else { return }
            self.isScanning = false
            self.scanMessage = failed > 0 ? "\(failed) folder(s) unavailable; their books were retained." :
                (warnings > 0 ? "Discovery finished; \(warnings) unreadable entries were skipped." : "\(self.library.books.count) books in your library.")
        }
    }
    private func mergeDiscovery(_ result: FolderDiscovery, folderID: UUID) {
        guard let folderIndex = library.folders.firstIndex(where: { $0.id == folderID }) else { return }
        var state = library
        var byPath: [String: Int] = [:], byResource: [String: Int] = [:]
        for index in state.books.indices {
            let record = state.books[index]
            byPath[record.path] = index
            if let resolved = result.resolvedBooks[record.id] { byPath[resolved] = index }
            if let resource = record.resourceID { byResource[resource] = index }
            if result.resolvedBooks[record.id] != nil { state.books[index].missing = result.missingBooks.contains(record.id) }
        }
        var members: Set<UUID> = []
        for file in result.files {
            let existing = byPath[file.url.path] ?? file.resourceID.flatMap { byResource[$0] }
            var record = existing.map { state.books[$0] } ?? BookRecord(id: UUID(), path: file.url.path,
                revision: file.revision, title: file.url.lastPathComponent, lastOpened: .distantPast)
            // Discovery never rebases positions or marks onto a revision that has not been opened.
            if record.title == URL(fileURLWithPath: record.path).lastPathComponent { record.title = file.url.lastPathComponent }
            record.path = file.url.path; record.bookmark = file.bookmark; record.resourceID = file.resourceID
            record.fileSize = file.size; record.missing = false
            if record.lastOpened == .distantPast { record.title = file.url.lastPathComponent }
            let index = existing ?? state.books.count
            if let existing { state.books[existing] = record } else { state.books.append(record) }
            byPath[file.url.path] = index
            if let resource = file.resourceID { byResource[resource] = index }
            members.insert(record.id)
        }
        state.folders[folderIndex].path = result.folderURL.path
        if result.warnings > 0 { state.folders[folderIndex].bookIDs.formUnion(members) }
        else { state.folders[folderIndex].bookIDs = members }
        state.folders[folderIndex].lastScan = Date()
        library = state; persist()
    }
}
