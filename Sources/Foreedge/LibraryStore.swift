import Foundation
import CSQLite

struct BookLocation: Codable, Equatable {
    var bookID: UUID
    var revision: String
    var page: Int
    var x: Double
    var y: Double
    var scale: Double
    var fit: String
}

struct BookRecord: Codable, Identifiable {
    var id: UUID
    var path: String
    var bookmark: Data?
    var resourceID: String?
    var revision: String
    var title: String
    var lastOpened: Date
    var location: BookLocation?
    var fileSize: Int?
    var pageCount: Int?
    var author: String?
    var missing: Bool?

    func resolvedURL() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: path)
    }
}

struct ReadingMark: Codable, Identifiable {
    var id: String
    var symbol: String
    var location: BookLocation
}

struct LibraryState: Codable {
    var version = 4
    var books: [BookRecord] = []
    var lastBookID: UUID?
    var appearance = PaperAppearance()
    var vimEnabled = false
    var marks: [ReadingMark] = []
    var back: [BookLocation] = []
    var forward: [BookLocation] = []
    var collections: [BookCollection] = []
    var folders: [LibraryFolder] = []
    var activeScope = "all"
    var didOfferDefaultFolder = false
    var workspaces: [StudyWorkspace] = []
    var activeWorkspaceID: UUID?
    var references: [PassageReference] = []
    var referenceLinks: [ReadingReferenceLink] = []

    init() {}
    enum CodingKeys: String, CodingKey {
        case references, referenceLinks
        case version, books, lastBookID, appearance, vimEnabled, marks, back, forward
        case collections, folders, activeScope, didOfferDefaultFolder, workspaces, activeWorkspaceID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        references = try c.decodeIfPresent([PassageReference].self, forKey: .references) ?? []
        referenceLinks = try c.decodeIfPresent([ReadingReferenceLink].self, forKey: .referenceLinks) ?? []
        version = try c.decode(Int.self, forKey: .version)
        books = try c.decode([BookRecord].self, forKey: .books)
        lastBookID = try c.decodeIfPresent(UUID.self, forKey: .lastBookID)
        appearance = try c.decode(PaperAppearance.self, forKey: .appearance)
        vimEnabled = try c.decode(Bool.self, forKey: .vimEnabled)
        marks = try c.decode([ReadingMark].self, forKey: .marks)
        back = try c.decode([BookLocation].self, forKey: .back)
        forward = try c.decode([BookLocation].self, forKey: .forward)
        collections = try c.decodeIfPresent([BookCollection].self, forKey: .collections) ?? []
        folders = try c.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? []
        activeScope = try c.decodeIfPresent(String.self, forKey: .activeScope) ?? "all"
        workspaces = try c.decodeIfPresent([StudyWorkspace].self, forKey: .workspaces) ?? []
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
        didOfferDefaultFolder = try c.decodeIfPresent(Bool.self, forKey: .didOfferDefaultFolder) ?? false
    }
}

/// Small versioned snapshots, atomically committed on a serial I/O queue. PDF content stays in place.
/// A schema boundary lets later catalogues/search use normalized tables without exposing SQL to views.
final class LibraryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "foreedge.library", qos: .utility)
    private var database: OpaquePointer?
    private let url: URL

    var searchIndexURL: URL { url.deletingPathExtension().appendingPathExtension("search-v1.sqlite") }

    static func preparedDefaultURL() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacyDirectory = support.appendingPathComponent("Paperman", isDirectory: true)
        let currentDirectory = support.appendingPathComponent("Foreedge", isDirectory: true)
        try migrateLegacyData(from: legacyDirectory, to: currentDirectory)
        return currentDirectory.appendingPathComponent("Library.sqlite")
    }

    /// Copy the old databases through SQLite so a live WAL is handled safely. The legacy files
    /// remain untouched and become a rollback copy after the renamed app launches successfully.
    static func migrateLegacyData(from legacyDirectory: URL, to currentDirectory: URL) throws {
        try migrateDatabaseIfNeeded(
            from: legacyDirectory.appendingPathComponent("Library.sqlite"),
            to: currentDirectory.appendingPathComponent("Library.sqlite")
        )
        try migrateDatabaseIfNeeded(
            from: legacyDirectory.appendingPathComponent("Library.search-v1.sqlite"),
            to: currentDirectory.appendingPathComponent("Library.search-v1.sqlite")
        )
    }

    init(url: URL? = nil) throws {
        let resolvedURL = try url ?? Self.preparedDefaultURL()
        self.url = resolvedURL
        try FileManager.default.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(resolvedURL.path, &database) == SQLITE_OK else { throw failure() }
        try execute("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);")
    }

    deinit { if let database { sqlite3_close(database) } }

    func load() throws -> LibraryState {
        try queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT payload FROM state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return LibraryState() }
            guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            var state = try JSONDecoder().decode(LibraryState.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            guard (1...4).contains(state.version) else {
                throw NSError(domain: "Foreedge", code: 1, userInfo: [NSLocalizedDescriptionKey: "This library was created by a newer version. Its data has been left unchanged."])
            }
            if state.version < 4 {
                // Preserve each older snapshot before the first reference-aware save.
                try execute("CREATE TABLE IF NOT EXISTS migration_backup (version INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT OR IGNORE INTO migration_backup(version,payload) SELECT \(state.version),payload FROM state WHERE id=1;")
                state.version = 4
            }
            return state
        }
    }

    func save(_ state: LibraryState, completion: @escaping @Sendable (String?) -> Void = { _ in }) {
        queue.async { [self] in
            do {
                let data = try JSONEncoder().encode(state)
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO state(id,payload) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(statement) }
                let result = data.withUnsafeBytes { buffer -> Int32 in
                    sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }

    func flush() { queue.sync {} }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> Error {
        NSError(domain: "Foreedge.Library", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: "Couldn’t save or read the reading library: \(String(cString: sqlite3_errmsg(database)))"])
    }

    private static func migrateDatabaseIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: destinationURL.path), files.fileExists(atPath: sourceURL.path) else { return }
        try files.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var source: OpaquePointer?
        var destination: OpaquePointer?
        var message = "Couldn’t migrate the existing reading library."
        var succeeded = false

        if sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
           sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
           let backup = sqlite3_backup_init(destination, "main", source, "main") {
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            succeeded = step == SQLITE_DONE && finish == SQLITE_OK
            if !succeeded, let destination { message = String(cString: sqlite3_errmsg(destination)) }
        } else if let database = destination ?? source {
            message = String(cString: sqlite3_errmsg(database))
        }

        if let destination { sqlite3_close(destination) }
        if let source { sqlite3_close(source) }
        guard succeeded else {
            for suffix in ["", "-wal", "-shm"] { try? files.removeItem(atPath: destinationURL.path + suffix) }
            throw NSError(domain: "Foreedge.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
