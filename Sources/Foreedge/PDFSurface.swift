import PDFKit
import SwiftUI
import os.signpost

/// Retain PDFKit's view/document while controls and page-number labels update.
@MainActor
struct PDFSurface: NSViewRepresentable {
    let document: PDFDocument
    let appearance: PaperAppearance
    let texture: PaperTexture?
    var source: PDFSource? = nil
    var documentID: UUID? = nil
    var textureKey: String? = nil
    var ownerID: UUID? = nil
    var onViewReleased: (PDFView) -> Void = { _ in }
    var onViewReady: (PDFView) -> Void = { _ in }
    var onPageChange: (Int) -> Void = { _ in }
    var onAssignment: (Double) -> Void = { _ in }
    var onViewportChange: () -> Void = {}
    var onNativeNavigation: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(appearance: appearance, texture: texture) }

    func makeNSView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displayBox = .mediaBox
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.pageOverlayViewProvider = context.coordinator
        context.coordinator.attach(view)
        onViewReady(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.ownerID != ownerID {
            coordinator.onViewReleased(view)
            coordinator.ownerID = ownerID
            onViewReady(view)
        }
        coordinator.onViewReleased = onViewReleased
        coordinator.onPageChange = onPageChange
        coordinator.onViewportChange = onViewportChange
        if let reader = view as? ReaderPDFView { reader.onWillNavigate = onNativeNavigation; reader.onKey = onKey }
        let changed = coordinator.setDocument(source: source, id: documentID)
        coordinator.textureKey = textureKey
        coordinator.update(appearance: appearance, texture: texture)
        if view.document !== document || changed {
            onViewReady(view)
            let start = ProcessInfo.processInfo.systemUptime
            let log = OSLog(subsystem: "io.github.tenzonultra.foreedge", category: .pointsOfInterest)
            os_signpost(.begin, log: log, name: "Assign PDFView")
            if let reader = view as? ReaderPDFView { reader.onWillNavigate = {} }
            view.document = document
            view.autoScales = true
            os_signpost(.end, log: log, name: "Assign PDFView")
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            // Publishing SwiftUI state inside updateNSView would create a feedback loop.
            DispatchQueue.main.async { [weak view, weak document, weak coordinator] in
                guard let view, let document, let coordinator, view.document === document,
                      coordinator.ownerID == ownerID, coordinator.documentID == documentID else { return }
                view.layoutDocumentView()
                view.documentView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
                onAssignment(elapsed)
                if let reader = view as? ReaderPDFView { reader.onWillNavigate = onNativeNavigation }
            }
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.onViewReleased(view)
        coordinator.shutdown()
        view.pageOverlayViewProvider = nil
    }

    @MainActor
    final class Coordinator: NSObject, PDFPageOverlayViewProvider {
        static let cacheLimit = 6
        var ownerID: UUID?
        var onViewReleased: (PDFView) -> Void = { _ in }
        private var appearance: PaperAppearance
        private var texture: PaperTexture?
        private var overlays: [Int: NSHashTable<PaperOverlay>] = [:]
        private var cache: [Int: PaperTexture] = [:]
        private var recency: [Int] = []
        private var pending: [Int] = []
        private var failed: Set<Int> = []
        private var runningPage: Int?
        private var preparation: Task<Void, Never>?
        private var refreshScheduled = false
        private var pageObserver: NSObjectProtocol?
        private var viewportObservers: [NSObjectProtocol] = []
        var onViewportChange: () -> Void = {}
        private weak var pdfView: PDFView?
        private var source: PDFSource?
        var textureKey: String?
        private(set) var documentID: UUID?
        var onPageChange: (Int) -> Void = { _ in }
        var cachedPageCount: Int { cache.count }
        var cachedPages: Set<Int> { Set(cache.keys) }
        var pendingPageCount: Int { pending.count }

        init(appearance: PaperAppearance, texture: PaperTexture?) {
            self.appearance = appearance
            self.texture = texture
        }

        func attach(_ view: PDFView) {
            pdfView = view
            viewportObservers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onViewportChange() }
            })
            viewportObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self, weak view] notification in
                MainActor.assumeIsolated {
                    guard let view, let changed = notification.object as? NSClipView, changed.isDescendant(of: view) else { return }
                    self?.onViewportChange()
                }
            })
            pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let view = self.pdfView, let document = view.document,
                          let page = view.currentPage else { return }
                    let index = document.index(for: page)
                    guard index != NSNotFound else { return }
                    self.onPageChange(index + 1)
                    self.onViewportChange()
                    self.schedulePreparation()
                }
            }
        }

        @discardableResult func setDocument(source: PDFSource?, id: UUID?) -> Bool {
            guard documentID != id else { return false }
            if let oldID = documentID { Task { await PaperWorker.shared.releaseDocument(oldID) } }
            preparation?.cancel()
            preparation = nil
            runningPage = nil
            pending.removeAll()
            failed.removeAll()
            cache.removeAll()
            recency.removeAll()
            overlays.removeAll()
            self.source = source
            documentID = id
            return true
        }

        nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
            MainActor.assumeIsolated {
                makeOverlay(view, page: page)
            }
        }

        private func makeOverlay(_ view: PDFView, page: PDFPage) -> NSView? {
            let overlay = PaperOverlay(frame: page.bounds(for: view.displayBox))
            let index = page.document?.index(for: page) ?? 0
            register(overlay, at: index)
            overlay.update(appearance: appearance, texture: textureForPage(index))
            return overlay
        }

        nonisolated func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
            MainActor.assumeIsolated { displayOverlay(overlayView, page: page) }
        }

        private func displayOverlay(_ overlayView: NSView, page: PDFPage) {
            guard let overlay = overlayView as? PaperOverlay else { return }
            let index = page.document?.index(for: page) ?? 0
            register(overlay, at: index)
            overlay.update(appearance: appearance, texture: textureForPage(index))
            schedulePreparation()
        }

        nonisolated func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
            MainActor.assumeIsolated { endDisplayingOverlay(overlayView, page: page) }
        }

        private func endDisplayingOverlay(_ overlayView: NSView, page: PDFPage) {
            guard let overlay = overlayView as? PaperOverlay else { return }
            let index = page.document?.index(for: page) ?? 0
            overlays[index]?.remove(overlay)
            if overlays[index]?.allObjects.isEmpty == true { overlays.removeValue(forKey: index) }
            // PDFKit can retain offscreen views. Do not let them pin adaptive page images.
            overlay.update(appearance: appearance, texture: texture)
            schedulePreparation()
        }

        func update(appearance: PaperAppearance, texture: PaperTexture?) {
            guard self.appearance != appearance || self.texture?.image !== texture?.image else { return }
            self.appearance = appearance
            self.texture = texture
            for (index, views) in overlays {
                for overlay in views.allObjects {
                    overlay.update(appearance: appearance, texture: textureForPage(index))
                }
            }
            if appearance.mode != .paper || appearance.experiment != .adaptive {
                preparation?.cancel()
                preparation = nil
                runningPage = nil
                pending.removeAll()
            } else { schedulePreparation() }
        }

        func shutdown() {
            viewportObservers.forEach { NotificationCenter.default.removeObserver($0) }
            viewportObservers.removeAll()
            preparation?.cancel()
            preparation = nil
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
            if let id = documentID { Task { await PaperWorker.shared.releaseDocument(id) } }
            pdfView = nil
            overlays.removeAll()
            cache.removeAll()
        }

        private func register(_ overlay: PaperOverlay, at index: Int) {
            overlays = overlays.filter { !$0.value.allObjects.isEmpty }
            if overlays[index] == nil { overlays[index] = .weakObjects() }
            overlays[index]?.add(overlay)
        }

        private func textureForPage(_ index: Int) -> PaperTexture? {
            appearance.experiment == .adaptive ? cache[index] ?? texture : texture
        }

        private func schedulePreparation() {
            guard appearance.mode == .paper, appearance.experiment == .adaptive,
                  texture != nil, source != nil, documentID != nil else { return }
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshRequests()
            }
        }

        private func refreshRequests() {
            guard appearance.mode == .paper, appearance.experiment == .adaptive, texture != nil,
                  source != nil, documentID != nil, let view = pdfView, let document = view.document else { return }
            let current = view.currentPage.map { document.index(for: $0) } ?? 0
            let visible = Array(view.visiblePages.map { document.index(for: $0) }
                .filter { $0 != NSNotFound }.sorted { abs($0 - current) < abs($1 - current) }.prefix(4))
            failed.formIntersection(visible)
            for index in visible where cache[index] != nil { touch(index) }
            // Replace stale queued work on every visible-page change. Only one worker job runs.
            pending = visible.filter { cache[$0] == nil && !failed.contains($0) && $0 != runningPage }
            startNext()
        }

        private func touch(_ index: Int) {
            recency.removeAll { $0 == index }
            recency.append(index)
        }

        private func startNext() {
            guard preparation == nil, !pending.isEmpty, let source, let id = documentID else { return }
            let index = pending.removeFirst()
            runningPage = index
            let key = textureKey
            preparation = Task { [weak self] in
                let result: Result<PaperTexture, Error>
                do { result = .success(try await PaperWorker.shared.adaptive(source: source, documentID: id, pageIndex: index, resourceKey: key)) }
                catch { result = .failure(error) }
                guard !Task.isCancelled, let self, self.documentID == id else { return }
                self.preparation = nil
                self.runningPage = nil
                switch result {
                case .success(let prepared):
                    self.cache[index] = prepared
                    self.touch(index)
                    while self.cache.count > Self.cacheLimit, let oldest = self.recency.first {
                        self.recency.removeFirst()
                        self.cache.removeValue(forKey: oldest)
                        for overlay in self.overlays[oldest]?.allObjects ?? [] {
                            overlay.update(appearance: self.appearance, texture: self.texture)
                        }
                    }
                    for overlay in self.overlays[index]?.allObjects ?? [] {
                        overlay.update(appearance: self.appearance, texture: prepared)
                    }
                case .failure:
                    self.failed.insert(index)
                }
                self.refreshRequests()
            }
        }
    }
}
