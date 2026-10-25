import PDFKit
import SwiftUI

@MainActor
struct ReaderPanelView: View {
    @ObservedObject var session: ReaderSession
    let panel: ReaderPanel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { session.panel = nil }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            Group {
                switch panel {
                case .references: ReferencesPanel(session: session)
                case .linkReference: LinkReferencePanel(session: session)
                case .workspaces: if let workspace = session.workspace { WorkspacePicker(workspace: workspace) }
                case .quickOpen: QuickOpenPanel(session: session)
                case .catalogue: CataloguePanel(session: session)
                case .collections:
                    KeyboardPicker(prompt: "Switch collection or folder…", rows: session.library.scopes.map {
                        PickerRow(id: $0.id, title: $0.name)
                    }, empty: "No collections") { id in session.selectScope(id); session.panel = .quickOpen }
                case .commands: CommandPicker(session: session)
                case .appearance: AppearancePanel(session: session)
                case .contents: ContentsPanel(session: session)
                case .find: FindPanel(session: session, search: session.search)
                case .marks: MarksPanel(session: session)
                case .page: PagePanel(session: session)
                case .diagnostics:
                    VStack(alignment: .leading, spacing: 10) {
                        Text(session.lastOpenUsedCache ? "Reused a recently opened document" : "Opened from file")
                        Text(String(format: "Open / parse: %.1f ms", session.book?.openMilliseconds ?? 0))
                        Text(String(format: "Assign to PDF view: %.1f ms", session.assignmentMilliseconds))
                        Text("CPU intervals only. These do not measure the first visible frame, GPU cost, or scroll smoothness.").foregroundStyle(.secondary)
                    }.padding(20)
                }
            }.id(panel)
        }.frame(width: panel == .catalogue ? 740 : 560)
    }
    private var title: String {
        switch panel {
        case .references: return "References & Backlinks"
        case .linkReference: return "Link Passages"
        case .workspaces: return "Workspaces"
        case .quickOpen: return "Open Book"
        case .catalogue: return "Library"
        case .collections: return "Switch Collection"
        case .commands: return "Commands"
        case .appearance: return "Appearance & Keyboard"
        case .contents: return "Contents"
        case .find: return "Find in Book"
        case .marks: return "Reading Marks"
        case .page: return "Go to Page"
        case .diagnostics: return "Loading Measurements"
        }
    }
}

private struct PickerRow: Identifiable {
    let id: String
    let title: String
    var detail = ""
    var trailing = ""
}

/// Common arrow/Return behavior for command, outline, and mark pickers.
private struct KeyboardPicker: View {
    let prompt: String
    let rows: [PickerRow]
    let empty: String
    let choose: (String) -> Void
    var remove: ((String) -> Void)? = nil
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var focused: Bool
    private var filtered: [PickerRow] {
        rows.compactMap { row in fuzzyScore(query, in: row.title + " " + row.detail).map { (row, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }
    var body: some View {
        VStack(spacing: 0) {
            TextField(prompt, text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let id = selected ?? filtered.first?.id { choose(id) } }.padding(16)
            if filtered.isEmpty { Text(empty).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, minHeight: 280) }
            else {
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        ForEach(filtered) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title)
                                    if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer()
                                Text(row.trailing).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).contentShape(Rectangle()).tag(row.id).id(row.id)
                                .onTapGesture { selected = row.id; choose(row.id) }
                                .contextMenu { if let remove { Button("Delete", role: .destructive) { remove(row.id) } } }
                        }
                    }.frame(height: 310)
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .onAppear { focused = true; selected = filtered.first?.id }
        .onChange(of: query) { _, _ in selected = filtered.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { if let id = selected ?? filtered.first?.id { choose(id) }; return .handled }
    }
    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : 1)
        selected = filtered[min(filtered.count - 1, max(0, index + delta))].id
    }
}

private struct CommandPicker: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        KeyboardPicker(prompt: "Type a command…", rows: ReaderCommand.allCases.filter { $0 != .palette && $0.enabled(in: session) }.map {
            PickerRow(id: $0.id, title: $0.title, trailing: $0.shortcut)
        }, empty: "No matching commands") { id in ReaderCommand(rawValue: id)?.run(in: session) }
    }
}

private struct AppearancePanel: View {
    @ObservedObject var session: ReaderSession
    var body: some View {
        Form {
            Picker("Treatment", selection: $session.appearance.mode) { ForEach(PaperMode.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Surface", selection: $session.appearance.experiment) { ForEach(PaperExperiment.allCases) { Text($0.rawValue).tag($0) } }
                .disabled(session.appearance.mode != .paper)
            Slider(value: $session.appearance.warmth, in: 0...1) { Text("Warmth") }.disabled(session.appearance.mode == .plain)
            Slider(value: $session.appearance.brightness, in: 0.78...0.94) { Text("Brightness") }
                .disabled(session.appearance.mode == .plain || session.appearance.experiment == .original)
            Slider(value: $session.appearance.grain, in: 0...1) { Text("Grain") }.disabled(session.appearance.mode != .paper)
            Text(session.appearance.experiment.detail).font(.caption).foregroundStyle(.secondary)
            Toggle("Compare smooth paper (⌘B)", isOn: $session.compareSmooth).disabled(session.appearance.mode != .paper)
            Divider()
            Toggle("Vim navigation in the reading pane", isOn: $session.vimEnabled)
            Text("j / k scroll · / finds text · ma sets mark a · `a returns. Lowercase marks belong to this book; uppercase marks work across books. Native shortcuts always work.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

private struct OutlineItem {
    var id: String
    var label: String
    var destination: PDFDestination?
    var depth: Int
}
private struct ContentsPanel: View {
    @ObservedObject var session: ReaderSession
    @State private var items: [OutlineItem] = []
    var body: some View {
        KeyboardPicker(prompt: "Find a chapter or section…", rows: items.filter { $0.destination != nil }.map {
            PickerRow(id: $0.id, title: String(repeating: "  ", count: min($0.depth, 4)) + $0.label, trailing: $0.destination?.page?.label ?? "")
        }, empty: items.isEmpty ? "This PDF has no embedded table of contents. Use Go to Page or Find in Book." : "No matching sections") { id in
            guard let destination = items.first(where: { $0.id == id })?.destination else { return }
            session.go(to: destination); session.panel = nil
        }.onAppear {
            items = []
            if let root = session.book?.document.outlineRoot { visit(root, depth: -1, path: "root") }
        }
    }
    private func visit(_ outline: PDFOutline, depth: Int, path: String) {
        guard depth < 32, items.count < 10_000 else { return }
        if depth >= 0 { items.append(OutlineItem(id: path, label: outline.label ?? "Untitled section", destination: outline.destination, depth: depth)) }
        for index in 0..<outline.numberOfChildren { if let child = outline.child(at: index) { visit(child, depth: depth + 1, path: "\(path).\(index)") } }
    }
}

private struct FindPanel: View {
    @ObservedObject var session: ReaderSession
    @ObservedObject var search: BookSearch
    @State private var query = ""
    @State private var selected: String?
    @State private var scope = BookSearchScope.book
    @State private var occurrences: [String: Int] = [:]
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Find words or a phrase…", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { choose() }.onChange(of: query) { _, _ in start() }
                Picker("Search scope", selection: $scope) {
                    ForEach(BookSearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 125).onChange(of: scope) { _, _ in session.searchScope = scope; start() }
            }
            HStack(alignment: .top) {
                if search.isSearching { ProgressView().controlSize(.small) }
                Text(search.message.isEmpty ? "Ranked passages, one result per page. Return opens; ⌘Return opens beside." : search.message)
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if scope == .collection { Text(session.activeScopeName).font(.caption).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    ForEach(search.hits) { hit in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Page \(hit.label.isEmpty ? String(hit.page + 1) : hit.label)")
                                Spacer()
                                Text(hit.kind == .broader ? "Broader · \(hit.matchedWords)" : hit.kind.rawValue)
                                Text("\((occurrences[hit.id] ?? 0) + 1)/\(hit.matchCount)")
                            }.font(.caption).foregroundStyle(.secondary)
                            if scope != .book { Text(hit.title).font(.caption).bold().lineLimit(1) }
                            if !hit.section.isEmpty { Text(hit.section).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Text(hit.matches[min(occurrences[hit.id] ?? 0, hit.matches.count - 1)].snippet).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4).tag(hit.id).id(hit.id).contentShape(Rectangle())
                    }
                }.frame(height: 360)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let hit = search.hits.first(where: { ids.contains($0.id) }) {
                            Button("Open") { open(hit) }
                            Button("Open Beside") { open(hit, beside: true) }.disabled(session.workspace == nil)
                        }
                    } primaryAction: { ids in if let hit = search.hits.first(where: { ids.contains($0.id) }) { open(hit) } }
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
            }
            HStack {
                Button("Open") { choose() }.keyboardShortcut(.return, modifiers: [])
                Button("Open Beside") { choose(beside: true) }.keyboardShortcut(.return, modifiers: .command).disabled(session.workspace == nil)
                Spacer()
                Button { occurrence(-1) } label: { Image(systemName: "chevron.left") }.help("Previous match on this page · ⌥←").keyboardShortcut(.leftArrow, modifiers: .option)
                Button { occurrence(1) } label: { Image(systemName: "chevron.right") }.help("Next match on this page · ⌥→").keyboardShortcut(.rightArrow, modifiers: .option)
            }.disabled(search.hits.isEmpty)
        }.padding(16).onAppear { scope = session.searchScope; focused = true }
        .onDisappear { search.cancel() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }

    }
    private func start() {
        selected = nil; occurrences = [:]
        search.start(query, documents: session.searchDocuments(scope: scope))
    }
    private func move(_ delta: Int) {
        guard !search.hits.isEmpty else { return }
        let current = search.hits.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : 1)
        selected = search.hits[min(search.hits.count - 1, max(0, current + delta))].id
    }
    private func occurrence(_ delta: Int) {
        guard let hit = search.hits.first(where: { $0.id == selected }) ?? search.hits.first else { return }
        selected = hit.id
        occurrences[hit.id] = ((occurrences[hit.id] ?? 0) + delta + hit.matches.count) % hit.matches.count
    }
    private func choose(beside: Bool = false) {
        if let hit = search.hits.first(where: { $0.id == selected }) ?? search.hits.first { open(hit, beside: beside) }
    }
    private func open(_ hit: SearchHit, beside: Bool = false) { session.openSearchHit(hit, occurrence: occurrences[hit.id] ?? 0, beside: beside) }
}

private struct PagePanel: View {
    @ObservedObject var session: ReaderSession
    @State private var entry = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Page label or #PDF page", text: $entry).textFieldStyle(.roundedBorder).focused($focused).onSubmit(jump)
            Text("Use the printed page label when the PDF supplies it, or #12 for the 12th PDF page. Current PDF page: \(session.pageNumber).")
                .font(.caption).foregroundStyle(.secondary)
            Button("Go", action: jump).keyboardShortcut(.defaultAction)
        }.padding(20).onAppear { focused = true }
    }
    private func jump() { session.go(toLabel: entry); session.panel = nil }
}

private struct MarksPanel: View {
    @ObservedObject var session: ReaderSession
    @State private var symbol = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("a–z / A–Z", text: $symbol).frame(width: 100).onSubmit(set)
                Button("Set at current position", action: set).disabled(symbol.count != 1 || session.currentRecord == nil)
            }.padding(16)
            KeyboardPicker(prompt: "Find a mark…", rows: session.visibleMarks.map { mark in
                PickerRow(id: mark.id, title: "\(mark.symbol) · Page \(mark.location.page + 1)", detail: session.library.books.first(where: { $0.id == mark.location.bookID })?.title ?? "")
            }, empty: "No marks yet. Set a lowercase mark for this book or an uppercase mark for any book.", choose: { id in
                guard let mark = session.library.marks.first(where: { $0.id == id }) else { return }
                session.navigate(mark.location); session.panel = nil
            }, remove: session.deleteMark)
        }
    }
    private func set() { session.setMark(symbol); if symbol.count == 1 { session.panel = nil } }
}
