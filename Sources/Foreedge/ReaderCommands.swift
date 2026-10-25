import SwiftUI

enum ReaderCommand: String, CaseIterable, Identifiable {
    case findCollection
    case copyReference, linkReference, references, openCopiedReference
    case splitRight, splitBelow, nextPane, previousPane, closePane, maximizePane, newTab, closeTab, nextTab, previousTab, workspaces
    case focusLeft, focusRight, focusUp, focusDown, moveLeft, moveRight, moveUp, moveDown
    case open, quickOpen, catalogue, collections, addFolder, refreshLibrary, palette, appearance, contents, find, page, marks, back, forward, previous, next, fitWidth, vim, compare, baseline, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .findCollection: return "Search Collection"
        case .copyReference: return "Copy Passage Reference"
        case .linkReference: return "Link Copied Passage Here…"
        case .references: return "References & Backlinks"
        case .openCopiedReference: return "Open Copied Reference"
        case .splitRight: return "Split Pane Right"
        case .splitBelow: return "Split Pane Below"
        case .nextPane: return "Focus Next Pane"
        case .previousPane: return "Focus Previous Pane"
        case .closePane: return "Close Pane"
        case .focusLeft: return "Focus Pane Left"
        case .focusRight: return "Focus Pane Right"
        case .focusUp: return "Focus Pane Up"
        case .focusDown: return "Focus Pane Down"
        case .moveLeft: return "Move Pane Left"
        case .moveRight: return "Move Pane Right"
        case .moveUp: return "Move Pane Up"
        case .moveDown: return "Move Pane Down"
        case .maximizePane: return "Maximize / Restore Pane"
        case .newTab: return "New Book Tab"
        case .closeTab: return "Close Book Tab"
        case .nextTab: return "Next Book Tab"
        case .previousTab: return "Previous Book Tab"
        case .workspaces: return "Switch Workspace…"
        case .quickOpen: return "Quick Open Book"
        case .catalogue: return "Browse Library"
        case .collections: return "Switch Collection"
        case .addFolder: return "Add Books Folder…"
        case .refreshLibrary: return "Refresh Library Folders"
        case .open: return "Open PDF…"
        case .palette: return "Command Palette"
        case .appearance: return "Appearance…"
        case .contents: return "Table of Contents"
        case .find: return "Find in Book"
        case .page: return "Go to Page"
        case .marks: return "Reading Marks"
        case .back: return "Go Back"
        case .forward: return "Go Forward"
        case .previous: return "Previous Page"
        case .next: return "Next Page"
        case .fitWidth: return "Fit Width"
        case .vim: return "Toggle Vim Navigation"
        case .compare: return "Compare Smooth Paper"
        case .baseline: return "Developer: Open Rendering Fixture"
        case .diagnostics: return "Developer: Loading Measurements"
        }
    }
    var key: KeyEquivalent? {
        switch self {
        case .copyReference: return "c"
        case .linkReference: return "l"
        case .references, .openCopiedReference: return "r"
        case .focusLeft, .moveLeft: return .leftArrow
        case .focusRight, .moveRight: return .rightArrow
        case .focusUp, .moveUp: return .upArrow
        case .focusDown, .moveDown: return .downArrow
        case .splitRight, .splitBelow: return "\\"
        case .nextPane, .previousPane: return .tab
        case .closePane, .closeTab: return "w"
        case .workspaces: return "p"
        case .maximizePane: return "m"
        case .newTab: return "t"
        case .nextTab: return "]"
        case .previousTab: return "["
        case .quickOpen, .collections: return "p"
        case .catalogue: return "o"
        case .open: return "o"
        case .palette: return "p"
        case .appearance: return ","
        case .contents: return "t"
        case .find, .findCollection: return "f"
        case .page: return "l"
        case .marks: return "m"
        case .back: return "["
        case .forward: return "]"
        case .previous: return .upArrow
        case .next: return .downArrow
        case .fitWidth: return "0"
        case .compare: return "b"
        default: return nil
        }
    }
    var direction: PaneDirection? {
        switch self {
        case .focusLeft, .moveLeft: return .left
        case .focusRight, .moveRight: return .right
        case .focusUp, .moveUp: return .up
        case .focusDown, .moveDown: return .down
        default: return nil
        }
    }
    var movesPane: Bool { [.moveLeft, .moveRight, .moveUp, .moveDown].contains(self) }
    var modifiers: EventModifiers {
        if [.findCollection, .copyReference, .linkReference, .references].contains(self) { return [.command, .shift] }
        if self == .openCopiedReference { return [.command, .option] }
        if direction != nil { return movesPane ? [.control, .option, .shift] : [.control, .option] }
        if self == .closeTab { return [.command, .shift] }
        if self == .splitBelow { return [.command, .shift] }
        if self == .nextPane { return [.control] }
        if self == .previousPane { return [.control, .shift] }
        if [.closePane, .maximizePane, .workspaces].contains(self) { return [.command, .control] }
        if self == .nextTab || self == .previousTab { return [.command, .shift] }
        if self == .collections { return [.command, .option] }
        return [.palette, .contents, .marks, .catalogue].contains(self) ? [.command, .shift] : [.command]
    }
    var shortcut: String {
        switch self {
        case .copyReference: return "⇧⌘C"
        case .linkReference: return "⇧⌘L"
        case .references: return "⇧⌘R"
        case .openCopiedReference: return "⌥⌘R"
        case .focusLeft: return "⌃⌥←"
        case .focusRight: return "⌃⌥→"
        case .focusUp: return "⌃⌥↑"
        case .focusDown: return "⌃⌥↓"
        case .moveLeft: return "⌃⌥⇧←"
        case .moveRight: return "⌃⌥⇧→"
        case .moveUp: return "⌃⌥⇧↑"
        case .moveDown: return "⌃⌥⇧↓"
        case .splitRight: return "⌘\\"
        case .splitBelow: return "⇧⌘\\"
        case .nextPane: return "⌃Tab"
        case .previousPane: return "⌃⇧Tab"
        case .closePane: return "⌃⌘W"
        case .maximizePane: return "⌃⌘M"
        case .newTab: return "⌘T"
        case .closeTab: return "⇧⌘W"
        case .nextTab: return "⇧⌘]"
        case .previousTab: return "⇧⌘["
        case .workspaces: return "⌃⌘P"
        case .quickOpen: return "⌘P"
        case .catalogue: return "⇧⌘O"
        case .collections: return "⌥⌘P"
        case .open: return "⌘O"
        case .palette: return "⇧⌘P"
        case .appearance: return "⌘,"
        case .contents: return "⇧⌘T"
        case .findCollection: return "⇧⌘F"
        case .find: return "⌘F"
        case .page: return "⌘L"
        case .marks: return "⇧⌘M"
        case .back: return "⌘["
        case .forward: return "⌘]"
        case .previous: return "⌘↑"
        case .next: return "⌘↓"
        case .fitWidth: return "⌘0"
        case .compare: return "⌘B"
        default: return ""
        }
    }
    @MainActor func enabled(in session: ReaderSession) -> Bool {
        if direction != nil { return (session.workspace?.panes.count ?? 0) > 1 }
        switch self {
        case .splitRight, .splitBelow: return (session.workspace?.panes.count ?? 4) < WorkspaceSession.paneLimit
        case .nextPane, .previousPane, .closePane, .maximizePane: return (session.workspace?.panes.count ?? 0) > 1
        case .newTab, .workspaces: return session.workspace != nil
        case .closeTab, .nextTab, .previousTab: return (session.workspace?.activePane.tabs.count ?? 0) > 1
        case .findCollection, .references, .openCopiedReference, .open, .quickOpen, .catalogue, .collections, .addFolder, .refreshLibrary, .palette, .appearance, .vim, .baseline: return true
        case .compare: return session.book != nil && session.appearance.mode == .paper
        case .back: return session.canGoBack && !session.isOpening
        case .forward: return session.canGoForward && !session.isOpening
        default: return session.book != nil && !session.isOpening
        }
    }
    @MainActor func run(in session: ReaderSession) {
        guard enabled(in: session) else { return }
        if let direction {
            session.panel = nil
            if movesPane { session.workspace?.movePane(direction) } else { session.workspace?.focusPane(direction) }
            return
        }
        switch self {
        case .copyReference: session.panel = nil; session.copyReference()
        case .linkReference: session.beginReferenceLink()
        case .references: session.panel = .references
        case .openCopiedReference:
            session.panel = nil
            if let reference = session.copiedReference() { session.followReference(reference.id) }
            else { session.notice = "Copy a passage reference first with ⇧⌘C." }
        case .splitRight: session.panel = nil; session.workspace?.split(.horizontal)
        case .splitBelow: session.panel = nil; session.workspace?.split(.vertical)
        case .nextPane: session.panel = nil; session.workspace?.cycleFocus()
        case .previousPane: session.panel = nil; session.workspace?.cycleFocus(-1)
        case .closePane: session.panel = nil; session.workspace?.closePane()
        case .maximizePane: session.panel = nil; session.workspace?.toggleMaximized()
        case .newTab: session.panel = nil; session.workspace?.activePane.newTab()
        case .closeTab: session.panel = nil; session.workspace?.activePane.closeTab()
        case .nextTab, .previousTab:
            session.panel = nil
            if let pane = session.workspace?.activePane, let index = pane.tabs.firstIndex(where: { $0.id == pane.activeTabID }) {
                pane.selectTab(pane.tabs[(index + (self == .nextTab ? 1 : -1) + pane.tabs.count) % pane.tabs.count].id)
            }
        case .workspaces: session.panel = .workspaces
        case .quickOpen: session.panel = .quickOpen
        case .catalogue: session.panel = .catalogue
        case .collections: session.panel = .collections
        case .palette: session.panel = .commands
        case .appearance: session.panel = .appearance
        case .contents: session.panel = .contents
        case .find: session.searchScope = .book; session.panel = .find
        case .findCollection: session.searchScope = .collection; session.panel = .find
        case .page: session.panel = .page
        case .marks: session.panel = .marks
        case .diagnostics: session.panel = .diagnostics
        default:
            session.panel = nil
            switch self {
            case .addFolder: session.chooseFolder()
            case .refreshLibrary: session.refreshLibrary()
            case .open: session.choosePDF()
            case .back: session.back()
            case .forward: session.forward()
            case .previous: session.previousPage()
            case .next: session.nextPage()
            case .fitWidth: session.fitWidth()
            case .vim: session.vimEnabled.toggle()
            case .compare: session.compareSmooth.toggle()
            case .baseline: session.showBaseline()
            default: break
            }
        }
    }
}

struct ReaderCommandButton: View {
    @ObservedObject var session: ReaderSession
    let command: ReaderCommand
    var body: some View {
        if let key = command.key { button.keyboardShortcut(key, modifiers: command.modifiers) }
        else { button }
    }
    private var button: some View {
        Button(command.title) { command.run(in: session) }.disabled(!command.enabled(in: session))
    }
}
