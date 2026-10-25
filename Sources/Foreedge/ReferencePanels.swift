import SwiftUI

@MainActor
struct LinkReferencePanel: View {
    @ObservedObject var session: ReaderSession
    @State private var note = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let draft = session.referenceDraft, let source = session.library.reference(draft.sourceID) {
                passage(source, heading: "From copied passage")
                passage(draft.target, heading: "To current passage")
                TextField("Optional note, e.g. proof of this theorem", text: $note)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { _ = session.commitReferenceLink(note: note) }
                HStack {
                    Text("The reverse link appears automatically in backlinks.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Link Passages") { _ = session.commitReferenceLink(note: note) }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(20).onAppear { focused = true }
    }
    private func passage(_ reference: PassageReference, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading).font(.caption).foregroundStyle(.secondary)
            Text(session.library.referenceTitle(reference)).font(.callout).lineLimit(2)
            if !reference.quote.isEmpty { Text(reference.quote).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct ReferencesPanel: View {
    @ObservedObject var session: ReaderSession
    @State private var scope = ReferenceScope.page
    @State private var query = ""
    @State private var selected: String?
    @State private var editing: UUID?
    @State private var note = ""
    @FocusState private var focused: Bool
    private var rows: [ReferenceRow] {
        session.library.referenceRows(bookID: session.currentRecord?.id, page: session.captureLocation()?.page, scope: scope)
            .filter { fuzzyScore(query, in: searchText($0)) != nil }
    }
    private var chosen: ReferenceRow? { rows.first { $0.id == selected } ?? rows.first }
    var body: some View {
        VStack(spacing: 12) {
            Picker("Show references", selection: $scope) {
                ForEach(ReferenceScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.top, 16)
            TextField("Find a book, passage, or note…", text: $query).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { follow() }.padding(.horizontal, 16)
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Text("No matching references").font(.headline)
                    Text("Copy a passage with ⇧⌘C, move to another passage, then link them with ⇧⌘L. Broaden to This book or All links to find connections elsewhere.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, minHeight: 280)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.incoming ? "From" : "To") · \(session.library.referenceTitle(row.endpoint))").font(.callout)
                                if scope == .all, let source = session.library.reference(row.link.sourceID) {
                                    Text("From · \(session.library.referenceTitle(source))").font(.caption).foregroundStyle(.secondary)
                                }
                                if !row.link.note.isEmpty { Text(row.link.note).font(.callout).lineLimit(2) }
                                if !row.endpoint.quote.isEmpty { Text(row.endpoint.quote).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                                .contentShape(Rectangle()).tag(row.id).id(row.id)
                        }
                    }.frame(height: 300)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let row = rows.first(where: { ids.contains($0.id) }) {
                            Button("Open") { open(row.endpoint.id) }
                            Button("Open Beside") { open(row.endpoint.id, beside: true) }
                            Button("Edit Note…") { edit(row) }
                            Button("Remove Link", role: .destructive) { session.context.deleteReferenceLink(row.link.id) }
                        }
                    } primaryAction: { ids in
                        if let row = rows.first(where: { ids.contains($0.id) }) { open(row.endpoint.id) }
                    }
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            HStack {
                Button("Open") { follow() }.keyboardShortcut(.return, modifiers: [])
                Button("Open Beside") { follow(beside: true) }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.workspace == nil)
                Button("Other End") {
                    if let row = chosen { open(row.incoming ? row.link.targetID : row.link.sourceID) }
                }.keyboardShortcut(.return, modifiers: .option)
                Spacer()
                Menu {
                    Button("Edit Note…") { if let row = chosen { edit(row) } }
                    Button("Remove Link", role: .destructive) { if let row = chosen { session.context.deleteReferenceLink(row.link.id) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }.disabled(chosen == nil).padding([.horizontal, .bottom], 16)
            Text("Return opens · ⌘Return opens beside · ⌥Return opens the other end").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
        }
        .onAppear { if session.book == nil { scope = .all }; focused = true; selected = rows.first?.id }
        .onChange(of: rows.map(\.id)) { _, ids in if selected == nil || !ids.contains(selected!) { selected = ids.first } }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .alert("Edit link note", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Note", text: $note)
            Button("Save") { if let editing { session.context.updateReferenceNote(editing, note: note) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }
    private func searchText(_ row: ReferenceRow) -> String {
        let source = session.library.reference(row.link.sourceID)
        return session.library.referenceTitle(row.endpoint) + " " + row.endpoint.quote + " " + row.link.note + " " + (source.map { session.library.referenceTitle($0) + " " + $0.quote } ?? "")
    }
    private func follow(beside: Bool = false) { if let row = chosen { open(row.endpoint.id, beside: beside) } }
    private func open(_ id: UUID, beside: Bool = false) { session.followReference(id, beside: beside) }
    private func edit(_ row: ReferenceRow) { note = row.link.note; editing = row.link.id }
    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected } ?? 0
        selected = rows[min(rows.count - 1, max(0, index + delta))].id
    }
}
