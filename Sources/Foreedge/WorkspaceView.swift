import SwiftUI
import AppKit

@MainActor
struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceSession
    var body: some View {
        GeometryReader { geometry in
            Group {
                if workspace.maximized { WorkspacePaneView(pane: workspace.activePane, workspace: workspace) }
                else { PaneTreeView(node: workspace.layout, workspace: workspace) }
            }
            .onChange(of: geometry.size, initial: true) { _, size in workspace.layoutSize = size }
        }
    }
}

@MainActor
private struct PaneTreeView: View {
    let node: PaneLayout
    @ObservedObject var workspace: WorkspaceSession
    var body: some View {
        switch node {
        case .pane(let id):
            if let pane = workspace.panes.first(where: { $0.id == id }) { WorkspacePaneView(pane: pane, workspace: workspace) }
        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { geometry in
                let horizontal = axis == .horizontal
                let length = max(0, (horizontal ? geometry.size.width : geometry.size.height) - PaneLayout.gap)
                let firstLength = PaneLayout.firstLength(total: length + PaneLayout.gap, axis: axis, ratio: ratio)
                if horizontal {
                    HStack(spacing: 0) {
                        PaneTreeView(node: first, workspace: workspace).frame(width: firstLength)
                        divider(id, axis: axis, length: length, firstLength: firstLength)
                        PaneTreeView(node: second, workspace: workspace)
                    }
                } else {
                    VStack(spacing: 0) {
                        PaneTreeView(node: first, workspace: workspace).frame(height: firstLength)
                        divider(id, axis: axis, length: length, firstLength: firstLength)
                        PaneTreeView(node: second, workspace: workspace)
                    }
                }
            }
        }
    }
    private func divider(_ id: UUID, axis: SplitAxis, length: Double, firstLength: Double) -> some View {
        SplitDivider(axis: axis, ratio: firstLength / max(1, length)) { delta in
            workspace.resize(id, ratio: delta)
        }.frame(width: axis == .horizontal ? PaneLayout.gap : nil, height: axis == .vertical ? PaneLayout.gap : nil)
            .environment(\.splitLength, length)
    }
}
private struct SplitLengthKey: EnvironmentKey { static let defaultValue = 1.0 }
private extension EnvironmentValues {
    var splitLength: Double { get { self[SplitLengthKey.self] } set { self[SplitLengthKey.self] = newValue } }
}
private struct SplitDivider: View {
    let axis: SplitAxis
    let ratio: Double
    let resize: (Double) -> Void
    @Environment(\.splitLength) private var length
    @State private var initial: Double?
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5))
            .contentShape(Rectangle().inset(by: -3))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if initial == nil { initial = ratio }
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                resize((initial ?? ratio) + delta / max(1, length))
            }.onEnded { _ in initial = nil })
            .onHover { inside in
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .accessibilityLabel("Resize panes").accessibilityValue("\(Int(ratio * 100)) percent")
            .accessibilityAdjustableAction { direction in resize(ratio + (direction == .increment ? 0.05 : -0.05)) }
    }
}

@MainActor
private struct WorkspacePaneView: View {
    @ObservedObject var pane: ReadingPane
    @ObservedObject var workspace: WorkspaceSession
    var body: some View {
        ReadingStudy(session: pane.reader, pane: pane)
        .background(PaneFocusObserver { workspace.focus(pane.id) })
        .overlay(alignment: .top) {
            if workspace.panes.count > 1 {
                Rectangle().fill(workspace.activePaneID == pane.id ? Color.accentColor : Color.clear).frame(height: 1).allowsHitTesting(false)
            }
        }
        .clipped()
    }
}

@MainActor
struct ReadingTabStrip: View {
    @ObservedObject var pane: ReadingPane
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(pane.tabs) { tab in
                    Button { pane.selectTab(tab.id) } label: {
                        Text(title(tab)).font(.caption).lineLimit(1).frame(maxWidth: 180)
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(tab.id == pane.activeTabID ? Color.primary.opacity(0.06) : Color.clear)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.frame(height: 30)
    }
    private func title(_ tab: ReadingTabState) -> String {
        if tab.id == pane.activeTabID, let book = pane.reader.book { return book.name }
        return pane.reader.library.books.first { $0.id == tab.bookID }?.title ?? "New book"
    }
}

/// Observe focus before PDFKit's private subviews handle clicks/scrolls; never consume events.
private struct PaneFocusObserver: NSViewRepresentable {
    let activate: () -> Void
    func makeNSView(context: Context) -> FocusView { let view = FocusView(); view.activate = activate; return view }
    func updateNSView(_ view: FocusView, context: Context) { view.activate = activate }
    final class FocusView: NSView {
        var activate: () -> Void = {}
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.activate(); return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

@MainActor
struct WorkspacePicker: View {
    @ObservedObject var workspace: WorkspaceSession
    @State private var name = ""
    @State private var error = false
    @State private var renameID: UUID?
    @State private var deleting: StudyWorkspace?
    var body: some View {
        VStack(spacing: 12) {
            Text("Each workspace remembers its collection, panes, tabs, and reading positions. Changes save automatically.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(workspace.context.library.workspaces) { state in
                        HStack {
                            Button { workspace.reader.panel = nil; workspace.switchWorkspace(state.id) } label: {
                                Label(state.name, systemImage: state.id == workspace.activeWorkspaceID ? "checkmark" : "rectangle.split.2x2")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button("Rename") { renameID = state.id; name = state.name; error = false }
                            Button { deleting = state } label: { Image(systemName: "trash") }
                                .disabled(workspace.context.library.workspaces.count < 2).help("Delete saved workspace")
                        }
                    }
                }
            }.frame(height: 200)
            HStack {
                TextField(renameID == nil ? "New workspace name" : "Workspace name", text: $name).onSubmit(save)
                Button(renameID == nil ? "Create" : "Rename", action: save)
                if renameID != nil { Button("Cancel") { renameID = nil; name = ""; error = false } }
            }
            if error { Text("Choose a nonempty, unique name.").foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(width: 520)
            .confirmationDialog("Delete ‘\(deleting?.name ?? "")’? Books, collections, and marks are kept.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete Workspace", role: .destructive) { if let deleting { workspace.deleteWorkspace(deleting.id) }; deleting = nil }
            }
    }
    private func save() {
        let success = renameID.map { workspace.renameWorkspace($0, to: name) } ?? workspace.createWorkspace(name)
        error = !success
        if success { renameID = nil; name = "" }
    }
}
