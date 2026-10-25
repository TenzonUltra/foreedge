import SwiftUI

@MainActor
struct QuickOpenPanel: View {
    @ObservedObject var session: ReaderSession
    @State private var query = ""
    @State private var selected: UUID?
    @FocusState private var focused: Bool
    private var books: [BookRecord] { session.library.books(in: session.activeScope, matching: query) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Find a book…", text: $query).textFieldStyle(.roundedBorder).focused($focused).onSubmit(open)
                Picker("Collection", selection: Binding(get: { session.activeScope }, set: session.selectScope)) {
                    ForEach(session.library.scopes) { scope in Text(scope.name).tag(scope.id) }
                }.labelsHidden().frame(width: 155).help("Choose a collection or folder")
            }.padding(16)
            if books.isEmpty {
                VStack(spacing: 12) {
                    Text(query.isEmpty ? "No books in this collection yet." : "No matching books here.").foregroundStyle(.secondary)
                    if session.activeScope != "all" { Button("Search All Books") { session.selectScope("all") } }
                    Button("Browse Library…") { session.panel = .catalogue }
                }.frame(maxWidth: .infinity, minHeight: 290)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        ForEach(books) { record in
                            BookRow(record: record, current: record.id == session.recordID)
                                .contentShape(Rectangle()).tag(record.id).id(record.id)
                                .onTapGesture { selected = record.id; open() }
                        }
                    }.frame(height: 320)
                        .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            HStack {
                Text("↑ ↓ select · Return opens · Esc cancels").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Library…") { session.panel = .catalogue }.buttonStyle(ReaderButtonStyle())
            }.padding(12)
        }
        .onAppear { focused = true; selected = books.first?.id }
        .onChange(of: query) { _, _ in selected = books.first?.id }
        .onChange(of: session.activeScope) { _, _ in selected = books.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { open(); return .handled }
    }
    private func move(_ delta: Int) {
        guard !books.isEmpty else { return }
        let index = books.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : 1)
        selected = books[min(books.count - 1, max(0, index + delta))].id
    }
    private func open() { if let id = selected, books.contains(where: { $0.id == id }) { session.openBook(id) } else if let id = books.first?.id { session.openBook(id) } }
}

private struct BookRow: View {
    let record: BookRecord
    var current = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.missing == true ? "doc.badge.ellipsis" : "book.closed").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if record.missing == true { Text("File unavailable") }
                    else if let location = record.location { Text("PDF page \(location.page + 1)") }
                    else { Text("Not read yet") }
                    if let pages = record.pageCount { Text("\(pages) pages") }
                    if let size = record.fileSize { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if current { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.secondary).help("Currently open") }
        }.padding(.vertical, 5).help(record.path)
    }
}

@MainActor
struct CataloguePanel: View {
    @ObservedObject var session: ReaderSession
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var collectionName = ""
    @State private var deletion: BookCollection?
    @State private var formError: String?
    @FocusState private var focus: Field?
    private enum Field { case search, collection }
    private var books: [BookRecord] { session.library.books(in: session.activeScope, matching: query) }
    private var activeCollection: BookCollection? { session.library.collections.first { "collection:\($0.id)" == session.activeScope } }
    private var selectedBooks: Set<UUID> { selection.intersection(Set(books.map(\.id))) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add Folder…", action: session.chooseFolder)
                Button("New Collection…") { editingID = nil; collectionName = ""; editing = true; focus = .collection }
                Spacer()
                if session.isScanning { ProgressView().controlSize(.small); Button("Stop", action: session.cancelScan) }
                else { Button { session.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh folders") }
                Menu {
                    ForEach(session.library.folders) { folder in
                        Button("Stop scanning \(folder.name)") { session.removeFolder(folder.id) }
                    }
                } label: { Image(systemName: "folder.badge.gearshape") }.fixedSize().disabled(session.library.folders.isEmpty).help("Manage library folders")
            }.padding(12)
            if editing {
                HStack {
                    TextField("Collection name", text: $collectionName).focused($focus, equals: .collection).onSubmit(saveCollection)
                    Button(editingID == nil ? "Create" : "Save", action: saveCollection).disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false; focus = .search }
                }.padding(.horizontal, 12).padding(.bottom, 12)
                if let formError { Text(formError).font(.caption).foregroundStyle(.red).padding(.bottom, 10) }
            }
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        scopeRow(LibraryScope(id: "all", name: "All Books", icon: "books.vertical"))
                        scopeRow(LibraryScope(id: "recent", name: "Recent", icon: "clock"))
                        Text("Collections").font(.caption).foregroundStyle(.secondary).padding(.top, 14).padding(.horizontal, 8)
                        ForEach(session.library.collections) { collection in
                            scopeRow(LibraryScope(id: "collection:\(collection.id)", name: collection.name, icon: "square.stack"))
                                .contextMenu {
                                    Button("Rename…") { editingID = collection.id; collectionName = collection.name; editing = true; focus = .collection }
                                    Button("Delete Collection…", role: .destructive) { deletion = collection }
                                }
                        }
                        Text("Folders").font(.caption).foregroundStyle(.secondary).padding(.top, 14).padding(.horizontal, 8)
                        ForEach(session.library.folders) { folder in scopeRow(LibraryScope(id: "folder:\(folder.id)", name: folder.name, icon: "folder")) }
                    }.padding(8)
                }.frame(width: 170).background(.bar)
                Divider()
                VStack(spacing: 0) {
                    TextField("Find in \(session.activeScopeName)…", text: $query).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .search).onSubmit(openSelected).padding(12)
                    if books.isEmpty {
                        VStack(spacing: 10) {
                            Text(query.isEmpty ? "No books here yet" : "No matching books").font(.headline)
                            Text(activeCollection == nil ? "Add a folder, or choose All Books." : "Choose books in All Books, then use the Collections menu to add them here.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selection) {
                            ForEach(books) { record in
                                BookRow(record: record, current: record.id == session.recordID).tag(record.id).contentShape(Rectangle())
                            }
                        }
                        // A row tap gesture consumes the clicks List needs for native selection.
                        // Its primary action handles double-clicks without intercepting selection.
                        .contextMenu(forSelectionType: UUID.self) { ids in
                            if !ids.isEmpty {
                                Button("Open") { if let id = ids.first { session.openBook(id) } }.disabled(ids.count != 1)
                                Menu("Collections") { membershipItems(ids) }
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(session.library.books.filter { ids.contains($0.id) }.map { $0.resolvedURL() })
                                }
                            }
                        } primaryAction: { ids in
                            if ids.count == 1, let id = ids.first { session.openBook(id) }
                        }
                    }
                    Divider()
                    HStack {
                        Text(selectedBooks.isEmpty ? "\(books.count) books" : "\(selectedBooks.count) selected").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Collections") { membershipItems(selectedBooks) }.fixedSize().disabled(selectedBooks.isEmpty || session.library.collections.isEmpty)
                        if let collection = activeCollection {
                            Button("Remove") { session.setMembership(selectedBooks, collectionID: collection.id, included: false); selection = [] }
                                .disabled(selectedBooks.isEmpty).help("Remove from this collection; keep the book and its marks")
                        }
                        Button("Open", action: openSelected).disabled(selectedBooks.count != 1)
                    }.padding(12)
                }
            }.frame(height: 400)
            Divider()
            HStack {
                Text(session.scanMessage.isEmpty ? "Books open in place. Collections don’t move or copy files." : session.scanMessage)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }.padding(12)
        }
        .onAppear { focus = .search }
        .onChange(of: session.activeScope) { _, _ in selection = []; query = "" }
        .onChange(of: query) { _, _ in selection = [] }
        .onChange(of: collectionName) { _, _ in formError = nil }
        .confirmationDialog("Delete ‘\(deletion?.name ?? "")’? Books and reading marks will be kept.", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Delete Collection", role: .destructive) { if let deletion { session.deleteCollection(deletion.id) }; deletion = nil }
        }
    }
    private func scopeRow(_ scope: LibraryScope) -> some View {
        Button { session.selectScope(scope.id) } label: {
            Label(scope.name, systemImage: scope.icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(session.activeScope == scope.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(scope.name)
    }
    @ViewBuilder private func membershipItems(_ ids: Set<UUID>) -> some View {
        ForEach(session.library.collections) { collection in
            let allIncluded = !ids.isEmpty && ids.isSubset(of: collection.bookIDs)
            Button {
                session.setMembership(ids, collectionID: collection.id, included: !allIncluded)
            } label: {
                if allIncluded { Label(collection.name, systemImage: "checkmark") } else { Text(collection.name) }
            }
        }
    }
    private func openSelected() {
        if selectedBooks.count == 1, let id = selectedBooks.first { session.openBook(id) }
        else if selection.isEmpty, !query.isEmpty, let id = books.first?.id { session.openBook(id) }
    }
    private func saveCollection() {
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.library.collections.contains(where: { $0.id != editingID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            formError = "A collection with that name already exists."; return
        }
        if let editingID { session.renameCollection(editingID, to: collectionName) }
        else if session.createCollection(collectionName) == nil { return }
        editing = false; focus = .search
    }
}
