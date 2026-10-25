import CoreGraphics
import Foundation
import os.signpost

/// One serial executor for PDF raster analysis. Shared keys deduplicate work across panes.
actor PaperWorker {
    static let shared = PaperWorker()
    private var base: PaperTexture?
    private var documents: [String: CGPDFDocument] = [:]
    private var documentRecency: [String] = []
    private struct PageKey: Hashable { var document: String; var page: Int }
    private var pages: [PageKey: PaperTexture] = [:]
    private var pageRecency: [PageKey] = []
    private var clients: [UUID: String] = [:]
    private let log = OSLog(subsystem: "io.github.tenzonultra.foreedge", category: .pointsOfInterest)
    static let documentLimit = 4
    static let pageLimit = 12
    var cachedDocumentCount: Int { documents.count }
    var cachedPageCount: Int { pages.count }
    private(set) var generatedPageCount = 0

    func baseTexture() throws -> PaperTexture {
        if let base { return base }
        try Task.checkCancellation()
        let generated = try PaperTexture.generateBase()
        base = generated
        NSLog("Shared paper preparation: %.2f ms, %d CPU image bytes", generated.generationMilliseconds, generated.byteCount)
        return generated
    }

    func adaptive(source: PDFSource, documentID: UUID, pageIndex: Int, resourceKey: String? = nil) throws -> PaperTexture {
        try Task.checkCancellation()
        let key = resourceKey ?? documentID.uuidString
        clients[documentID] = key
        let pageKey = PageKey(document: key, page: pageIndex)
        if let cached = pages[pageKey] {
            pageRecency.removeAll { $0 == pageKey }; pageRecency.append(pageKey)
            return cached
        }
        let base = try baseTexture()
        if documents[key] == nil {
            let loaded: CGPDFDocument?
            switch source {
            case .data(let data): loaded = CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }
            case .file(let url): loaded = CGPDFDocument(url as CFURL)
            }
            guard let loaded, !loaded.isEncrypted || loaded.isUnlocked else { throw PaperTexture.GenerationError.invalidPDF }
            documents[key] = loaded
        }
        documentRecency.removeAll { $0 == key }; documentRecency.append(key)
        while documents.count > Self.documentLimit, let oldest = documentRecency.first {
            documents.removeValue(forKey: oldest); documentRecency.removeFirst()
        }
        guard let document = documents[key] else { throw PaperTexture.GenerationError.invalidPDF }
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Adaptive page", signpostID: signpost, "page=%d", pageIndex + 1)
        defer { os_signpost(.end, log: log, name: "Adaptive page", signpostID: signpost) }
        let texture = try base.adapting(to: document, pageIndex: pageIndex)
        try Task.checkCancellation()
        generatedPageCount += 1
        pages[pageKey] = texture; pageRecency.append(pageKey)
        while pages.count > Self.pageLimit, let oldest = pageRecency.first {
            pages.removeValue(forKey: oldest); pageRecency.removeFirst()
        }
        return texture
    }

    func releaseDocument(_ id: UUID) {
        guard let key = clients.removeValue(forKey: id), !clients.values.contains(key) else { return }
        documents.removeValue(forKey: key); documentRecency.removeAll { $0 == key }
        pages = pages.filter { $0.key.document != key }; pageRecency.removeAll { $0.document == key }
    }
}
