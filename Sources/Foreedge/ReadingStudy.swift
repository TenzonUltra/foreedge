import PDFKit
import SwiftUI

/// Keep quiet controls easy to hit, including the space surrounding their glyphs.
struct ReaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .frame(minWidth: 30, minHeight: 30)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

@MainActor
struct ReadingStudy: View {
    @ObservedObject var session: ReaderSession
    var pane: ReadingPane? = nil
    @State private var texture: PaperTexture?
    @State private var textureFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if let pane {
                if pane.tabs.count > 1 {
                    ReadingTabStrip(pane: pane)
                        .padding(.horizontal, 10)
                        .background(Color(nsColor: .windowBackgroundColor))
                    Divider()
                }
            } else {
            HStack(spacing: 4) {
                Button { ReaderCommand.catalogue.run(in: session) } label: { Image(systemName: "books.vertical") }
                    .help("Library · ⇧⌘O · Quick open with ⌘P").accessibilityLabel("Library")
                Button { session.back() } label: { Image(systemName: "arrow.left") }
                    .disabled(!session.canGoBack || session.isOpening).help("Back · ⌘[").accessibilityLabel("Go back")
                Button { session.forward() } label: { Image(systemName: "arrow.right") }
                    .disabled(!session.canGoForward || session.isOpening).help("Forward · ⌘]").accessibilityLabel("Go forward")
                Text(session.book?.name.replacingOccurrences(of: ".pdf", with: "") ?? "Foreedge")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                if session.isOpening { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                if let book = session.book {
                    Button { session.panel = .page } label: {
                        Text("\(session.pageNumber) / \(book.pageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.help("Go to page · ⌘L")
                    Button { session.panel = .contents } label: { Image(systemName: "list.bullet") }
                        .help("Contents · ⇧⌘T").accessibilityLabel("Table of contents")
                }
                Button { session.panel = .commands } label: { Image(systemName: "command") }
                    .help("Command palette · ⇧⌘P").accessibilityLabel("Command palette")
            }
            .buttonStyle(ReaderButtonStyle()).padding(.horizontal, 18).frame(height: 42)
            .background(.bar)
            Divider()
            }
            if let book = session.book {
                PDFSurface(document: book.document, appearance: session.displayedAppearance, texture: texture,
                           source: book.source, documentID: book.id, textureKey: book.textureKey,
                           ownerID: session.paneID, onViewReleased: session.detachView,
                           onViewReady: session.attachView,
                           onPageChange: { if session.pageNumber != $0 { session.pageNumber = $0 } },
                           onAssignment: { session.assignmentMilliseconds = $0; session.viewDidAssign() },
                           onViewportChange: session.viewportChanged,
                           onNativeNavigation: session.recordDeparture,
                           onKey: session.handleKey)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "book.closed").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text("A place to read").font(.title2)
                    Button("Open a PDF…", action: session.choosePDF)
                    Button("Browse Library…") { session.panel = .catalogue }
                    if !session.library.books.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent books").font(.caption).foregroundStyle(.secondary)
                            ForEach(session.library.books(in: "recent").prefix(6)) { record in
                                Button { session.open(record.resolvedURL()) } label: {
                                    Text(record.title).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.frame(maxWidth: 420).padding(.top, 12)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = session.notice {
                HStack { Text(notice); Button { session.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(ReaderButtonStyle()) }
                    .font(.callout).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
                    .task(id: notice) { try? await Task.sleep(nanoseconds: 4_000_000_000); if !Task.isCancelled, session.notice == notice { session.notice = nil } }
            }
        }
        .sheet(item: $session.panel, onDismiss: {
            session.search.cancel()
            if let view = session.pdfView { view.window?.makeFirstResponder(view) }
        }) { panel in ReaderPanelView(session: session, panel: panel) }
        .task {
            guard texture == nil, !textureFailed else { return }
            do { texture = try await PaperWorker.shared.baseTexture() }
            catch { textureFailed = true; session.notice = "Paper texture is unavailable. The book is still readable." }
        }
        .alert("Foreedge", isPresented: Binding(get: { session.errorMessage != nil || session.context.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil; session.context.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil; session.context.errorMessage = nil }
        } message: { Text(session.errorMessage ?? session.context.errorMessage ?? "") }
    }
}
