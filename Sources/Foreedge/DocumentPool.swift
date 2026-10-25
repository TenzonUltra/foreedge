import Foundation
import PDFKit

/// UI-owned PDFDocument handles only. Background workers must open their own documents.
@MainActor
final class DocumentPool {
    private struct Entry {
        var book: ReaderBook
        var revision: String
        var size: Int
    }
    private struct Pending {
        let id: UUID
        let task: Task<ReaderBook, Error>
        var waiters: Set<UUID>
    }
    private var pending: [String: Pending] = [:]
    private var active: [UUID: (path: String, entry: Entry)] = [:]
    var activeCount: Int { active.count }
    private var entries: [String: Entry] = [:]
    private var recency: [String] = []
    let capacity: Int
    let byteBudget: Int
    var count: Int { entries.count }
    var sourceBytes: Int { entries.values.reduce(0) { $0 + $1.size } }

    init(capacity: Int = 3, byteBudget: Int = 64 * 1024 * 1024) {
        self.capacity = capacity
        self.byteBudget = byteBudget
    }
    func lookup(_ metadata: DiscoveredFile) -> ReaderBook? {
        let path = metadata.url.path
        if let live = active.values.first(where: { $0.path == path && $0.entry.revision == metadata.revision }) { return live.entry.book }
        guard let entry = entries[path] else { return nil }
        guard entry.revision == metadata.revision else { remove(path); return nil }
        recency.removeAll { $0 == path }; recency.append(path)
        return entry.book
    }
    func load(_ metadata: DiscoveredFile) async throws -> ReaderBook {
        try Task.checkCancellation()
        if let cached = lookup(metadata) { return cached }
        let key = "\(metadata.url.path):\(metadata.revision)", waiter = UUID()
        if pending[key] == nil {
            pending[key] = Pending(id: UUID(), task: Task {
                try await PDFLoader.shared.load(metadata.url, metadata: metadata).book
            }, waiters: [])
        }
        pending[key]!.waiters.insert(waiter)
        let request = pending[key]!
        return try await withTaskCancellationHandler {
            do {
                let book = try await request.task.value
                try Task.checkCancellation()
                if pending[key]?.id == request.id { pending.removeValue(forKey: key); insert(book, metadata: metadata) }
                return book
            } catch {
                cancelLoad(key, request: request.id, waiter: waiter)
                throw error
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelLoad(key, request: request.id, waiter: waiter) }
        }
    }
    private func cancelLoad(_ key: String, request: UUID, waiter: UUID) {
        guard pending[key]?.id == request else { return }
        pending[key]?.waiters.remove(waiter)
        if pending[key]?.waiters.isEmpty == true { pending.removeValue(forKey: key)?.task.cancel() }
    }
    func insert(_ book: ReaderBook, metadata: DiscoveredFile) {
        let path = metadata.url.path
        remove(path)
        guard metadata.size <= byteBudget, capacity > 0 else { return }
        entries[path] = Entry(book: book, revision: metadata.revision, size: metadata.size)
        recency.append(path)
        while count > capacity || sourceBytes > byteBudget {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
    }
    func retain(_ book: ReaderBook, metadata: DiscoveredFile, owner: UUID) {
        active[owner] = (metadata.url.path, Entry(book: book, revision: metadata.revision, size: metadata.size))
    }
    func release(owner: UUID) { active.removeValue(forKey: owner) }
    func removeAll() { entries.removeAll(); recency.removeAll() }
    private func remove(_ path: String) { entries.removeValue(forKey: path); recency.removeAll { $0 == path } }
}
