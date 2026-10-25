import Foundation

struct BookCollection: Codable, Identifiable {
    var id = UUID()
    var name: String
    var bookIDs: Set<UUID> = []
}

struct LibraryFolder: Codable, Identifiable {
    var id = UUID()
    var path: String
    var bookmark: Data?
    var bookIDs: Set<UUID> = []
    var lastScan: Date?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    func resolvedURL() -> URL { resolveFileBookmark(bookmark, fallback: path) }
}

func resolveFileBookmark(_ bookmark: Data?, fallback: String) -> URL {
    if let bookmark {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
           FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return URL(fileURLWithPath: fallback)
}

struct LibraryScope: Identifiable {
    var id: String
    var name: String
    var icon: String
}

struct DiscoveredFile: Sendable {
    var url: URL
    var bookmark: Data?
    var resourceID: String?
    var revision: String
    var size: Int

    static func read(_ input: URL) throws -> DiscoveredFile {
        let url = input.resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        // The identifier returned by URL is opaque on some SDKs; device/inode is a local fallback.
        let resourceID = (values.fileResourceIdentifier as? Data)?.base64EncodedString() ??
            (attributes[.systemNumber].flatMap { device in attributes[.systemFileNumber].map { "\(device):\($0)" } })
        return DiscoveredFile(url: url,
                              bookmark: try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil),
                              resourceID: resourceID,
                              revision: "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)",
                              size: values.fileSize ?? 0)
    }
}

struct FolderDiscovery: Sendable {
    var files: [DiscoveredFile]
    var resolvedBooks: [UUID: String]
    var missingBooks: Set<UUID>
    var warnings: Int
    var folderURL: URL
}

enum CatalogueScanner {
    /// Metadata-only discovery; no PDF documents, images, or text are loaded here.
    static func scan(_ folder: LibraryFolder, knownBooks: [BookRecord]) async throws -> FolderDiscovery {
        let task = Task.detached(priority: .utility) {
            let url = folder.resolvedURL().resolvingSymlinksInPath().standardizedFileURL
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
            var warnings = 0
            guard let enumerator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in warnings += 1; return true }) else {
                throw CocoaError(.fileReadNoPermission)
            }
            var files: [DiscoveredFile] = []
            var paths: Set<String> = []
            for case let entry as URL in enumerator {
                try Task.checkCancellation()
                // Do not follow symlink folders or silently scan outside the chosen root.
                if (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                guard entry.pathExtension.lowercased() == "pdf" else { continue }
                do {
                    let file = try DiscoveredFile.read(entry)
                    if paths.insert(file.url.path).inserted { files.append(file) }
                } catch { warnings += 1 }
            }
            var resolved: [UUID: String] = [:]
            var missing: Set<UUID> = []
            for record in knownBooks {
                try Task.checkCancellation()
                let resolvedURL = record.resolvedURL().resolvingSymlinksInPath().standardizedFileURL
                resolved[record.id] = resolvedURL.path
                if !FileManager.default.fileExists(atPath: resolvedURL.path) { missing.insert(record.id) }
            }
            return FolderDiscovery(files: files, resolvedBooks: resolved, missingBooks: missing, warnings: warnings, folderURL: url)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

extension LibraryState {
    var scopes: [LibraryScope] {
        [LibraryScope(id: "all", name: "All Books", icon: "books.vertical"), LibraryScope(id: "recent", name: "Recent", icon: "clock")] +
        collections.map { LibraryScope(id: "collection:\($0.id)", name: $0.name, icon: "square.stack") } +
        folders.map { LibraryScope(id: "folder:\($0.id)", name: $0.name, icon: "folder") }
    }

    func books(in scope: String, matching query: String = "") -> [BookRecord] {
        let candidates: [BookRecord]
        if scope == "recent" { candidates = books.filter { $0.lastOpened > .distantPast } }
        else if let collection = collections.first(where: { "collection:\($0.id)" == scope }) { candidates = books.filter { collection.bookIDs.contains($0.id) } }
        else if let folder = folders.first(where: { "folder:\($0.id)" == scope }) { candidates = books.filter { folder.bookIDs.contains($0.id) } }
        else { candidates = books }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return candidates.compactMap { record -> (BookRecord, Int)? in
            let title = record.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let filename = URL(fileURLWithPath: record.path).lastPathComponent
            guard var score = fuzzyScore(term, in: title + " " + filename + " " + (record.author ?? "")) else { return nil }
            if !term.isEmpty {
                if title == term { score += 1000 }
                else if title.hasPrefix(term) { score += 500 }
                else if title.contains(term) { score += 200 }
            }
            return (record, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.lastOpened != $1.0.lastOpened { return $0.0.lastOpened > $1.0.lastOpened }
            let comparison = $0.0.title.localizedStandardCompare($1.0.title)
            return comparison == .orderedSame ? $0.0.id.uuidString < $1.0.id.uuidString : comparison == .orderedAscending
        }.map(\.0)
    }
}
