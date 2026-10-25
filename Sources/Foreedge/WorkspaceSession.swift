import AppKit
import Combine

@MainActor
final class ReadingPane: ObservableObject, Identifiable {
    let id: UUID
    let reader: ReaderSession
    @Published var tabs: [ReadingTabState]
    @Published var activeTabID: UUID

    init(_ state: ReadingPaneState, context: LibraryContext) {
        id = state.id
        let restoredTabs = state.tabs.isEmpty ? [ReadingTabState()] : state.tabs
        tabs = restoredTabs
        activeTabID = state.activeTabID.flatMap { id in restoredTabs.contains { $0.id == id } ? id : nil } ?? restoredTabs[0].id
        reader = ReaderSession(context: context, paneID: id)
    }
    func capture() {
        guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        // Preserve an unavailable book or an in-flight restore instead of replacing it with an empty tab.
        if reader.recordID != nil { tabs[index] = reader.snapshot(id: activeTabID) }
    }
    var state: ReadingPaneState {
        capture()
        return ReadingPaneState(id: id, tabs: tabs, activeTabID: activeTabID)
    }
    func restoreActive() { if let tab = tabs.first(where: { $0.id == activeTabID }) { reader.restoreTab(tab) } }
    func selectTab(_ id: UUID) {
        guard activeTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        capture(); activeTabID = id; restoreActive(); reader.onStateChange?()
    }
    func newTab() {
        capture()
        let tab = ReadingTabState(); tabs.append(tab); activeTabID = tab.id
        reader.restoreTab(tab); reader.panel = .quickOpen; reader.onStateChange?()
    }
    func closeTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        reader.suspend(); tabs.remove(at: index)
        activeTabID = tabs[min(index, tabs.count - 1)].id; restoreActive(); reader.onStateChange?()
    }
}

/// Owns one active split tree. Inactive workspaces/tabs hold locations, never PDF views.
@MainActor
final class WorkspaceSession: ObservableObject {
    let context: LibraryContext
    @Published private(set) var panes: [ReadingPane] = []
    @Published private(set) var layout: PaneLayout
    @Published private(set) var activePaneID: UUID
    @Published private(set) var activeWorkspaceID: UUID
    @Published var maximized = false
    private var observation: AnyCancellable?
    private var saveTask: Task<Void, Never>?
    private var restoring = false
    static let paneLimit = 4
    var layoutSize = CGSize(width: 900, height: 960)

    var activePane: ReadingPane { panes.first { $0.id == activePaneID } ?? panes[0] }
    var reader: ReaderSession { activePane.reader }
    var name: String { context.library.workspaces.first { $0.id == activeWorkspaceID }?.name ?? "Reading desk" }

    init(context: LibraryContext, restore: Bool = true) {
        self.context = context
        let saved = context.library.workspaces.first { $0.id == context.library.activeWorkspaceID } ?? context.library.workspaces.first
        var initial = saved ?? StudyWorkspace(name: "Reading desk", scope: context.activeScope)
        if saved == nil {
            let record = context.library.books.first { $0.id == context.library.lastBookID }
            initial.panes[0].tabs = [ReadingTabState(bookID: record?.id, location: record?.location,
                back: context.library.back, forward: context.library.forward)]
            context.library.workspaces.append(initial)
        }
        layout = initial.layout; activePaneID = initial.activePaneID; activeWorkspaceID = initial.id
        observation = context.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        context.onChange = { [weak self] in self?.scheduleSave() }
        load(initial, openBooks: restore)
    }

    private func load(_ state: StudyWorkspace, openBooks: Bool = true) {
        restoring = true
        defer { restoring = false }
        panes.forEach { $0.reader.suspend() }
        maximized = false
        var seen: Set<UUID> = []
        let valid = state.layout.paneIDs.compactMap { id -> ReadingPaneState? in
            guard seen.insert(id).inserted else { return nil }
            return state.panes.first { $0.id == id }
        }
        // Recover a malformed or future oversized layout into a usable single pane.
        let states = valid.isEmpty || valid.count > Self.paneLimit || valid.count != state.layout.paneIDs.count
            ? [state.panes.first ?? ReadingPaneState()] : valid
        layout = states.count == valid.count && valid.count == state.layout.paneIDs.count ? state.layout : .pane(states[0].id)
        panes = states.map { ReadingPane($0, context: context) }
        activePaneID = panes.contains { $0.id == state.activePaneID } ? state.activePaneID : panes[0].id
        activeWorkspaceID = state.id
        context.library.activeWorkspaceID = state.id
        context.library.activeScope = context.library.scopes.contains { $0.id == state.scope } ? state.scope : "all"
        for pane in panes {
            connect(pane)
            if openBooks { pane.restoreActive() }
        }
    }
    private func connect(_ pane: ReadingPane) {
        pane.reader.workspace = self
        pane.reader.onStateChange = { [weak self] in self?.scheduleSave() }
    }
    func focus(_ id: UUID, keyboard: Bool = false) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        if activePaneID != id {
            if maximized { prepareLayoutChange() }
            activePaneID = id; scheduleSave()
        }
        if keyboard, let view = pane.reader.pdfView { view.window?.makeFirstResponder(view) }
    }
    func cycleFocus(_ delta: Int = 1) {
        let ids = layout.paneIDs
        guard let index = ids.firstIndex(of: activePaneID) else { return }
        focus(ids[(index + delta + ids.count) % ids.count], keyboard: true)
    }
    func split(_ axis: SplitAxis) {
        guard panes.count < Self.paneLimit else { reader.notice = "This version supports up to four panes."; return }
        prepareLayoutChange()
        var tab = activePane.state.tabs.first { $0.id == activePane.activeTabID } ?? ReadingTabState()
        tab.id = UUID()
        let state = ReadingPaneState(tabs: [tab], activeTabID: tab.id)
        let pane = ReadingPane(state, context: context); connect(pane)
        layout = layout.replacing(activePaneID, with: .split(id: UUID(), axis: axis, ratio: 0.5, first: .pane(activePaneID), second: .pane(pane.id)))
        panes.append(pane); activePaneID = pane.id; maximized = false
        pane.restoreActive(); scheduleSave()
    }
    func closePane() {
        guard panes.count > 1, let reduced = layout.removing(activePaneID) else { return }
        prepareLayoutChange()
        let closing = activePaneID
        panes.first { $0.id == closing }?.reader.suspend()
        panes.removeAll { $0.id == closing }; layout = reduced; activePaneID = reduced.paneIDs[0]
        maximized = false; scheduleSave()
    }
    func neighbor(_ direction: PaneDirection) -> UUID? {
        layout.neighbor(of: activePaneID, toward: direction, in: CGRect(origin: .zero, size: layoutSize))
    }
    func focusPane(_ direction: PaneDirection) {
        if let id = neighbor(direction) { focus(id, keyboard: true) }
    }
    func movePane(_ direction: PaneDirection) {
        guard let other = neighbor(direction) else { return }
        prepareLayoutChange()
        let temporary = UUID()
        layout = layout.replacing(activePaneID, with: .pane(temporary)).replacing(other, with: .pane(activePaneID)).replacing(temporary, with: .pane(other))
        scheduleSave()
    }
    func toggleMaximized() { prepareLayoutChange(); maximized.toggle() }
    func resize(_ id: UUID, ratio: Double) {
        layout = layout.settingRatio(id, to: ratio); scheduleSave()
    }
    private func prepareLayoutChange() {
        panes.forEach { $0.capture(); $0.reader.prepareForReattachment() }
    }
    func scheduleSave() {
        guard !restoring else { return }
        objectWillChange.send()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func save() {
        guard !restoring, let index = context.library.workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }
        var state = context.library.workspaces[index]
        state.layout = layout; state.activePaneID = activePaneID; state.scope = context.activeScope
        state.panes = panes.map(\.state)
        context.library.workspaces[index] = state
        context.library.activeWorkspaceID = activeWorkspaceID
        context.save()
    }
    func flush() {
        saveTask?.cancel()
        panes.forEach { $0.reader.captureAndSave() }
        saveTask?.cancel(); save(); context.flush()
    }
    func switchWorkspace(_ id: UUID) {
        guard id != activeWorkspaceID, let state = context.library.workspaces.first(where: { $0.id == id }) else { return }
        saveTask?.cancel(); save(); load(state); save()
    }
    @discardableResult func createWorkspace(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name) else { return false }
        save()
        let state = StudyWorkspace(name: name, scope: context.activeScope)
        context.library.workspaces.append(state)
        load(state); save(); return true
    }
    @discardableResult func renameWorkspace(_ id: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name, excluding: id), let index = context.library.workspaces.firstIndex(where: { $0.id == id }) else { return false }
        context.library.workspaces[index].name = name; context.save(); return true
    }
    func deleteWorkspace(_ id: UUID) {
        guard context.library.workspaces.count > 1 else { return }
        if id == activeWorkspaceID, let next = context.library.workspaces.first(where: { $0.id != id }) { switchWorkspace(next.id) }
        context.library.workspaces.removeAll { $0.id == id }; context.save()
    }
    private func validName(_ name: String, excluding: UUID? = nil) -> Bool {
        !name.isEmpty && !context.library.workspaces.contains { $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}
