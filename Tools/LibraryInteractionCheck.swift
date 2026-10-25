import AppKit
import SwiftUI

/// Runs a real AppKit event loop: table mouse tracking requires queued mouse-up events.
@main
enum LibraryInteractionCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.regular)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Foreedge-clicks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("Library.sqlite"))
        var state = LibraryState()
        for index in 0..<3 {
            let url = directory.appendingPathComponent("Book\(index).pdf")
            check(try BaselineDocument.make().write(to: url), "Create fixture")
            state.books.append(BookRecord(id: UUID(), path: url.path, revision: "fixture", title: "Book \(index)", lastOpened: .distantPast))
        }
        state.collections = [BookCollection(name: "Test collection")]
        state.folders = [LibraryFolder(path: directory.path, bookIDs: Set(state.books.map(\.id)))]
        state.activeScope = "all"
        store.save(state); store.flush()
        let session = ReaderSession(store: store)
        let host = NSHostingView(rootView: ReadingStudy(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 960)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        try await settle()
        // Hit the corner of the padded toolbar control, well outside the icon itself.
        await click(window, point: NSPoint(x: 20, y: host.bounds.height - 8))
        check(await wait { window.attachedSheet != nil && session.panel == .catalogue }, "Toolbar icon padding opens library")
        try await settle()
        let sidebar = descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSScrollView }.first!
        let sidebarPoint = sidebar.convert(NSPoint(x: sidebar.bounds.maxX - 12,
            y: sidebar.isFlipped ? 57 : sidebar.bounds.height - 57), to: nil)
        await click(window.attachedSheet!, point: sidebarPoint)
        check(session.activeScope == "recent", "Blank trailing area of sidebar row selects Recent")
        // Change scope while the sheet is open, as the sidebar does.
        session.selectScope("folder:\(state.folders[0].id)")
        try await settle()
        let sheet = window.attachedSheet!
        guard let table = descendants(sheet.contentView!).compactMap({ $0 as? NSTableView }).first,
              let collections = descendants(sheet.contentView!).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.title == "Collections" }) else {
            fatalError("Expected native library table and Collections menu")
        }
        check(table.numberOfRows == 3 && table.selectedRowIndexes.isEmpty && !collections.isEnabled, "Folder begins without a selection")
        await click(table, row: 0)
        check(table.selectedRowIndexes == IndexSet(integer: 0) && collections.isEnabled, "Single click selects and enables Collections")
        check(session.panel == .catalogue && session.book == nil, "Single click keeps library open")
        applyCollection(collections)
        try await settle()
        check(session.library.collections[0].bookIDs == [state.books[0].id], "Collections menu adds the clicked book")

        await click(table, row: 2, modifiers: .command)
        check(table.selectedRowIndexes == IndexSet([0, 2]), "Command-click adds a book to selection")
        applyCollection(collections)
        try await settle()
        check(session.library.collections[0].bookIDs == [state.books[0].id, state.books[2].id], "Collections menu applies to all selected books")
        applyCollection(collections)
        try await settle()
        check(session.library.collections[0].bookIDs.isEmpty, "Checked collection action removes selected membership")
        await click(table, row: 0)
        await click(table, row: 2, modifiers: .shift)
        check(table.selectedRowIndexes == IndexSet(0...2), "Shift-click selects a range")
        applyCollection(collections)
        try await settle()
        check(session.library.collections[0].bookIDs == Set(state.books.map(\.id)), "Range selection reaches the menu binding")

        session.selectScope("collection:\(state.collections[0].id)")
        try await settle()
        check(table.selectedRowIndexes.isEmpty && !collections.isEnabled, "Changing scope clears stale selection")
        await click(table, row: 1)
        await click(table, row: 1, count: 2)
        check(await wait { session.recordID == state.books[1].id && !session.isOpening && window.attachedSheet == nil }, "Double-click opens the clicked book and dismisses library")
        session.flush()
        let saved = try store.load()
        check(saved.collections[0].bookIDs == Set(state.books.map(\.id)), "Mouse-driven membership persists")
        print("Library interaction checks passed: toolbar padding, sidebar and book-row whitespace, folder scope, single-click selection, Collections menu add/remove, Command/Shift multi-selection, scope reset, double-click opening, and persistence.")
    }

    @MainActor static func applyCollection(_ button: NSPopUpButton) {
        // SwiftUI builds popup items lazily when the native button opens its menu.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.menu,
                      let index = menu.items.firstIndex(where: { $0.title == "Test collection" }) else {
                    fatalError("Missing collection action")
                }
                menu.cancelTracking()
                menu.performActionForItem(at: index)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        button.performClick(nil)

    }
    @MainActor static func click(_ table: NSTableView, row: Int, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) async {
        let window = table.window!
        let rect = table.rect(ofRow: row)
        // Click empty trailing space rather than relying on title text hit testing.
        let point = table.convert(NSPoint(x: rect.maxX - 18, y: rect.midY), to: nil)
        await click(window, point: point, modifiers: modifiers, count: count)
    }
    @MainActor static func click(_ window: NSWindow, point: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) async {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers, timestamp: timestamp + 0.05, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0)!
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1)!)
        window.sendEvent(up)
        try? await settle()
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
    @MainActor static func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() { if Date() > deadline { return false }; try? await settle() }
        return true
    }
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
