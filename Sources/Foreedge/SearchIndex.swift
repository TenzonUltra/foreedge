import Foundation
import PDFKit
import CSQLite
import CryptoKit

struct SearchDocument: Sendable {
    var source: PDFSource
    var bookID: UUID?
    var title: String
}
struct SearchDocumentKey: Sendable {
    var key: String
    var revision: String
    var bookID: UUID?
    var title: String
}
struct SearchMatch: Sendable {
    var offset: Int
    var length: Int
    var snippet: String
}
enum SearchMatchKind: String, Sendable { case phrase = "Phrase", terms = "All words", broader = "Broader match" }
struct SearchHit: Identifiable, Sendable {
    var id: String { "\(key):\(page)" }
    var key: String = ""
    var revision: String = ""
    var bookID: UUID? = nil
    var title: String = ""
    var page: Int
    var label: String = ""
    var section: String = ""
    var matches: [SearchMatch]
    var matchCount: Int
    var kind: SearchMatchKind
    var score: Double
    var matchedWords: String = ""
    var offset: Int { matches.first?.offset ?? 0 }
    var length: Int { matches.first?.length ?? 0 }
    var snippet: String { matches.first?.snippet ?? "" }
}
struct SearchResponse: Sendable {
    var hits: [SearchHit]
    var indexedPages: Int
    var totalPages: Int
    var isComplete: Bool
    var errors: Int
    var textPages: Int
    var broader: Bool
}

/// A disposable, shared FTS5 index. Only this actor touches SQLite or its worker-owned PDFDocument.
/// Extraction yields between pages; searches reuse committed batches while a book is still indexing.
actor SearchIndex {
    private var db: OpaquePointer?
    private let url: URL?
    private var jobs: [(SearchDocumentKey, PDFSource)] = []
    private var active: SearchDocumentKey?
    private var worker: Task<Void, Never>?
    private(set) var extractedPages = 0
    private var identityCache: [String: String] = [:]
    init(url: URL? = nil) { self.url = url }
    deinit { worker?.cancel(); if let db { sqlite3_close(db) } }

    func prepare(_ document: SearchDocument, priority: Bool = false) throws -> SearchDocumentKey {
        try open()
        let key: String, revision: String
        switch document.source {
        case .file(let url):
            key = url.standardizedFileURL.path
            revision = try fileRevision(url)
        case .data(let data):
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            key = "data:\(hash)"; revision = hash
        }
        let descriptor = SearchDocumentKey(key: key, revision: revision, bookID: document.bookID, title: document.title)
        if identityCache[key] == revision { return descriptor }
        let check = try statement("SELECT revision, complete FROM books WHERE key=?")
        bind(key, to: check, at: 1)
        let ready = sqlite3_step(check) == SQLITE_ROW && string(check, 0) == revision && sqlite3_column_int(check, 1) == 1
        sqlite3_finalize(check)
        if ready { identityCache[key] = revision; return descriptor }
        if active?.key == key && active?.revision == revision { return descriptor }
        if let queued = jobs.firstIndex(where: { $0.0.key == key && $0.0.revision == revision }) {
            if priority { let job = jobs.remove(at: queued); jobs.insert(job, at: 0) }
            return descriptor
        }
        jobs.removeAll { $0.0.key == key }
        if priority { jobs.insert((descriptor, document.source), at: 0) } else { jobs.append((descriptor, document.source)) }
        startNext()
        return descriptor
    }
    private func fileRevision(_ url: URL) throws -> String {
        // URL resource values can cache an earlier file size/date on reused URL instances.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\((attributes[.size] as? NSNumber)?.intValue ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    private func open() throws {
        guard db == nil else { return }
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open(url?.path ?? ":memory:", &db) == SQLITE_OK else { throw failure() }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-8192; PRAGMA busy_timeout=2000;")
        // This is generated data; changing extraction/tokenization gets a separate cache version.
        try exec("CREATE TABLE IF NOT EXISTS books(key TEXT PRIMARY KEY, revision TEXT, pages INTEGER, total INTEGER, complete INTEGER, error TEXT, textPages INTEGER);")
        try exec("CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(body, key UNINDEXED, page UNINDEXED, raw UNINDEXED, label UNINDEXED, section UNINDEXED, tokenize='porter unicode61 remove_diacritics 2');")
    }
    private func startNext() {
        guard worker == nil, !jobs.isEmpty else { return }
        let (descriptor, source) = jobs.removeFirst(); active = descriptor
        worker = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.build(descriptor, source: source)
            await self.finished()
        }
    }
    private func finished() { worker = nil; active = nil; startNext() }
    private func build(_ descriptor: SearchDocumentKey, source: PDFSource) async {
        do {
            let document: PDFDocument?
            switch source { case .file(let url): document = PDFDocument(url: url); case .data(let data): document = PDFDocument(data: data) }
            guard let document, !document.isLocked, document.pageCount > 0 else { throw SearchFailure(message: "No readable pages") }
            let outlines = outlinePages(document)
            try exec("BEGIN IMMEDIATE")
            let remove = try statement("DELETE FROM passages WHERE key=?"); bind(descriptor.key, to: remove, at: 1); try step(remove); sqlite3_finalize(remove)
            let book = try statement("INSERT OR REPLACE INTO books VALUES(?,?,0,?,0,'',0)")
            bind(descriptor.key, to: book, at: 1); bind(descriptor.revision, to: book, at: 2); sqlite3_bind_int(book, 3, Int32(document.pageCount)); try step(book); sqlite3_finalize(book)
            try exec("COMMIT")
            var textPages = 0, section = "", outlineIndex = 0
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                while outlineIndex < outlines.count && outlines[outlineIndex].0 <= pageIndex {
                    section = outlines[outlineIndex].1; outlineIndex += 1
                }
                try autoreleasepool {
                    let page = document.page(at: pageIndex)
                    let raw = page?.string ?? ""
                    if !raw.isEmpty {
                        textPages += 1
                        let insert = try statement("INSERT INTO passages(body,key,page,raw,label,section) VALUES(?,?,?,?,?,?)")
                        defer { sqlite3_finalize(insert) }
                        bind(SearchText.normalize(raw).text, to: insert, at: 1); bind(descriptor.key, to: insert, at: 2)
                        sqlite3_bind_int(insert, 3, Int32(pageIndex)); bind(raw, to: insert, at: 4)
                        bind(page?.label ?? String(pageIndex + 1), to: insert, at: 5); bind(section, to: insert, at: 6); try step(insert)
                    }
                    let update = try statement("UPDATE books SET pages=?, textPages=? WHERE key=?")
                    defer { sqlite3_finalize(update) }
                    sqlite3_bind_int(update, 1, Int32(pageIndex + 1)); sqlite3_bind_int(update, 2, Int32(textPages)); bind(descriptor.key, to: update, at: 3); try step(update)
                    extractedPages += 1
                }
                // One extraction worker, no display-owned PDF objects and no retained page-text array.
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if case .file(let url) = source {
                guard descriptor.revision == (try fileRevision(url)) else { throw SearchFailure(message: "PDF changed during indexing") }
            }
            let finish = try statement("UPDATE books SET complete=1 WHERE key=?"); defer { sqlite3_finalize(finish) }
            bind(descriptor.key, to: finish, at: 1); try step(finish); identityCache[descriptor.key] = descriptor.revision
        } catch {
            try? exec("ROLLBACK")
            if let stmt = try? statement("INSERT OR REPLACE INTO books VALUES(?,?,0,0,1,?,0)") {
                bind(descriptor.key, to: stmt, at: 1); bind(descriptor.revision, to: stmt, at: 2)
                bind(error.localizedDescription, to: stmt, at: 3); _ = sqlite3_step(stmt); sqlite3_finalize(stmt)
            }
        }
    }

    func search(_ query: String, documents: [SearchDocumentKey], limit: Int = 80) throws -> SearchResponse {
        try open()
        var indexed = 0, total = 0, textPages = 0, complete = true, errors = 0
        var usable: [SearchDocumentKey] = []
        for descriptor in documents {
            let stmt = try statement("SELECT revision,pages,total,complete,error,textPages FROM books WHERE key=?")
            bind(descriptor.key, to: stmt, at: 1)
            if sqlite3_step(stmt) == SQLITE_ROW, string(stmt, 0) == descriptor.revision {
                indexed += Int(sqlite3_column_int(stmt, 1)); total += Int(sqlite3_column_int(stmt, 2))
                complete = complete && sqlite3_column_int(stmt, 3) == 1
                textPages += Int(sqlite3_column_int(stmt, 5))
                if string(stmt, 4).isEmpty { usable.append(descriptor) } else { errors += 1 }
            } else { complete = false }
            sqlite3_finalize(stmt)
        }
        let tokens = SearchText.tokens(query)
        guard !tokens.isEmpty, !usable.isEmpty else {
            return SearchResponse(hits: [], indexedPages: indexed, totalPages: total, isComplete: complete, errors: errors, textPages: textPages, broader: false)
        }
        let quoted = tokens.map { "\"\($0)\"" }
        let phrase = "\"" + tokens.joined(separator: " ") + "\""
        var hits = try lookup(phrase, kind: .phrase, documents: usable, tokens: tokens, cap: 400)
        if tokens.count > 1 {
            let existing = Set(hits.map(\.id))
            hits += try lookup(quoted.joined(separator: " AND "), kind: .terms, documents: usable, tokens: tokens, cap: 200).filter { !existing.contains($0.id) }
        }
        var broader = false
        if hits.isEmpty && complete && tokens.count > 1 {
            broader = true
            hits = try lookup(quoted.joined(separator: " OR "), kind: .broader, documents: usable, tokens: tokens, cap: 200)
        }
        // Spread neighboring pages while preserving phrase > all-words > broader ordering.
        var ranked: [SearchHit] = []
        var penalties: [String: Int] = [:]
        let previews = try statement("SELECT raw,highlight(passages,0,char(57344),char(57345)) FROM passages WHERE rowid=? AND passages MATCH ?")
        defer { sqlite3_finalize(previews) }
        func score(_ candidate: Candidate) -> Double {
            (candidate.kind == .phrase ? 1000 : candidate.kind == .terms ? 100 : 0) + candidate.score / (1 + Double(penalties[candidate.id] ?? 0) * 0.6)
        }
        while !hits.isEmpty && ranked.count < limit {
            let best = hits.indices.max { score(hits[$0]) < score(hits[$1]) }!
            let candidate = hits.remove(at: best)
            if let hit = try materialize(candidate, statement: previews) { ranked.append(hit) }
            for page in (candidate.page-2)...(candidate.page+2) { penalties["\(candidate.descriptor.key):\(page)", default: 0] += 1 }
        }
        return SearchResponse(hits: ranked, indexedPages: indexed, totalPages: total, isComplete: complete, errors: errors, textPages: textPages, broader: broader)
    }
    private struct Candidate {
        var row: Int64
        var descriptor: SearchDocumentKey
        var page: Int
        var label: String
        var section: String
        var kind: SearchMatchKind
        var score: Double
        var expression: String
        var id: String { "\(descriptor.key):\(page)" }
    }
    private func lookup(_ expression: String, kind: SearchMatchKind, documents: [SearchDocumentKey], tokens: [String], cap: Int) throws -> [Candidate] {
        let descriptors = Dictionary(documents.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // Rank cheap metadata first. Text, offsets, and previews are loaded only for displayed pages.
        try exec("CREATE TEMP TABLE IF NOT EXISTS scope_keys(key TEXT PRIMARY KEY); DELETE FROM scope_keys;")
        for key in descriptors.keys {
            let stmt = try statement("INSERT OR IGNORE INTO scope_keys VALUES(?)"); bind(key, to: stmt, at: 1); try step(stmt); sqlite3_finalize(stmt)
        }
        let stmt = try statement("SELECT rowid,key,page,label,section,bm25(passages) FROM passages WHERE passages MATCH ? AND key IN (SELECT key FROM scope_keys) ORDER BY bm25(passages) LIMIT ?")
        defer { sqlite3_finalize(stmt) }
        bind(expression, to: stmt, at: 1); sqlite3_bind_int(stmt, 2, Int32(cap))
        var hits: [Candidate] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if let descriptor = descriptors[string(stmt, 1)] {
                let section = string(stmt, 4)
                let headingMatch = tokens.allSatisfy { section.localizedCaseInsensitiveContains($0) }
                let score = abs(sqlite3_column_double(stmt, 5)) * (headingMatch ? 1.4 : 1)
                hits.append(Candidate(row: sqlite3_column_int64(stmt, 0), descriptor: descriptor, page: Int(sqlite3_column_int(stmt, 2)),
                    label: string(stmt, 3), section: section, kind: kind, score: score, expression: expression))
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return hits
    }
    private func materialize(_ candidate: Candidate, statement stmt: OpaquePointer) throws -> SearchHit? {
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, candidate.row); bind(candidate.expression, to: stmt, at: 2)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let raw = string(stmt, 0), marked = string(stmt, 1)
        let matches = SearchText.matches(marked: marked, raw: raw)
        guard !matches.isEmpty else { return nil }
        let words = candidate.kind == .broader ? SearchText.markedWords(marked).prefix(4).joined(separator: ", ") : ""
        return SearchHit(key: candidate.descriptor.key, revision: candidate.descriptor.revision, bookID: candidate.descriptor.bookID,
            title: candidate.descriptor.title, page: candidate.page, label: candidate.label, section: candidate.section,
            matches: Array(matches.prefix(100)), matchCount: matches.count, kind: candidate.kind, score: candidate.score, matchedWords: words)
    }
    private func outlinePages(_ document: PDFDocument) -> [(Int, String)] {
        var result: [(Int, String)] = []
        func walk(_ node: PDFOutline, depth: Int) {
            guard depth < 20 else { return }
            if let page = node.destination?.page, let label = node.label {
                let index = document.index(for: page); if index != NSNotFound { result.append((index, label)) }
            }
            for index in 0..<node.numberOfChildren { if let child = node.child(at: index) { walk(child, depth: depth + 1) } }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return result.sorted { $0.0 < $1.0 }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }; return stmt
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() } }
    private func step(_ stmt: OpaquePointer) throws { guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() } }
    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
    private func failure() -> Error { SearchFailure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Couldn’t open the search cache") }
}
struct SearchFailure: LocalizedError { var message: String; var errorDescription: String? { message } }

/// Searchable text retains a mapping back to PDFKit's original UTF-16 character offsets.
enum SearchText {
    static func tokens(_ query: String) -> [String] {
        let text = normalize(query).text.lowercased()
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        return Array(regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).prefix(16).map { (text as NSString).substring(with: $0.range) })
    }
    static func normalize(_ raw: String, mapping: Bool = false) -> (text: String, map: [Int]) {
        let units = Array(raw.utf16)
        var normalized: [UInt16] = [], map: [Int] = []
        normalized.reserveCapacity(units.count)
        if mapping { map.reserveCapacity(units.count) }
        let ligatures: [UInt16: [UInt16]] = [0xfb00: [102,102], 0xfb01: [102,105], 0xfb02: [102,108], 0xfb03: [102,102,105], 0xfb04: [102,102,108], 0xfb05: [115,116], 0xfb06: [115,116]]
        var i = 0
        while i < units.count {
            let unit = units[i]
            if unit == 0x00ad { i += 1; continue }
            if unit == 45 && i > 0 {
                var end = i + 1, newline = false
                while end < units.count && [9,10,13,32].contains(units[end]) { newline = newline || units[end] == 10 || units[end] == 13; end += 1 }
                if newline, end < units.count, let before = UnicodeScalar(Int(units[i-1])), let after = UnicodeScalar(Int(units[end])), CharacterSet.letters.contains(before), CharacterSet.letters.contains(after) {
                    i = end; continue
                }
            }
            if let replacement = ligatures[unit] {
                normalized.append(contentsOf: replacement)
                if mapping { map.append(contentsOf: repeatElement(i, count: replacement.count)) }
            } else {
                normalized.append(unit)
                if mapping { map.append(i) }
            }
            i += 1
        }
        return (String(decoding: normalized, as: UTF16.self), map)
    }
    static func matches(marked: String, raw: String) -> [SearchMatch] {
        let normalized = normalize(raw, mapping: true), original = raw as NSString
        var cursor = 0, start: Int?, ranges: [NSRange] = []
        for unit in marked.utf16 {
            if unit == 0xe000 { start = cursor }
            else if unit == 0xe001 {
                if let start, cursor > start, start < normalized.map.count, cursor - 1 < normalized.map.count {
                    let offset = normalized.map[start], end = normalized.map[cursor-1] + 1
                    ranges.append(NSRange(location: offset, length: end - offset))
                }
                start = nil
            } else { cursor += 1 }
        }
        return ranges.map { range in
            let from = max(0, range.location - 65), end = min(original.length, NSMaxRange(range) + 150)
            let snippet = original.substring(with: NSRange(location: from, length: end - from)).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return SearchMatch(offset: range.location, length: range.length, snippet: snippet)
        }
    }
    static func markedWords(_ marked: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "\u{e000}(.*?)\u{e001}", options: .dotMatchesLineSeparators)
        let text = marked as NSString
        return Array(Set(regex.matches(in: marked, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)).lowercased() })).sorted()
    }
}
