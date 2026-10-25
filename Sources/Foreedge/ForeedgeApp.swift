import AppKit
import SwiftUI

@main
@MainActor
struct ForeedgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace: WorkspaceSession

    init() {
        let arguments = CommandLine.arguments
        let explicitPDF = arguments.firstIndex(of: "--pdf").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let context: LibraryContext
        do { context = LibraryContext(store: try LibraryStore()) }
        catch { context = LibraryContext(); context.errorMessage = error.localizedDescription }
        let workspace = WorkspaceSession(context: context, restore: explicitPDF == nil)
        _workspace = StateObject(wrappedValue: workspace)
        if let explicitPDF { workspace.reader.open(URL(fileURLWithPath: explicitPDF), recordHistory: false) }
    }

    var body: some Scene {
        Window("Foreedge", id: "reader") {
            WorkspaceView(workspace: workspace).frame(minWidth: 640, minHeight: 480)
                .onOpenURL { workspace.reader.openReferenceURL($0) }
                .onAppear {
                    appDelegate.workspace = workspace
                    workspace.context.startCatalogue(defaultFolder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/PDFs"))
                }
        }
        .defaultSize(width: 900, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) { ReaderCommandButton(session: workspace.reader, command: .open) }
            CommandGroup(replacing: .printItem) { ReaderCommandButton(session: workspace.reader, command: .quickOpen) }
            CommandGroup(replacing: .appSettings) { ReaderCommandButton(session: workspace.reader, command: .appearance) }
            CommandMenu("Reading") {
                ForEach(ReaderCommand.allCases.filter { $0 != .open && $0 != .appearance && $0 != .quickOpen }) { command in
                    ReaderCommandButton(session: workspace.reader, command: command)
                }
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceSession?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { workspace?.flush() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
