import SwiftUI
import AppKit
import LucidSQL

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    let workspaceModel = WorkspaceModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let contentView = WorkspaceView(model: workspaceModel)
            .frame(minWidth: 960, minHeight: 640)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)

        window.title = "LucidSQL"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let hasActiveSql = workspaceModel.sqlWorkspace.hasActiveWorkOrTransactions
        let hasPendingTable = workspaceModel.tableViewModel.hasPendingChanges

        guard hasActiveSql || hasPendingTable else {
            workspaceModel.sqlWorkspace.flushDrafts()
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Close LucidSQL?"
        var reasons: [String] = []
        if hasActiveSql {
            let names = workspaceModel.sqlWorkspace.tabsWithActiveWork.map(\.title).joined(separator: ", ")
            reasons.append("SQL tabs (\(names)) have running queries or uncommitted transactions that will be cancelled and rolled back.")
        }
        if hasPendingTable {
            reasons.append("The Table Data grid has unsaved edits that will be discarded.")
        }
        alert.informativeText = reasons.joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rollback, Discard & Close")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            workspaceModel.sqlWorkspace.flushDrafts()
            Task { @MainActor in
                await workspaceModel.performConfirmedDisconnect()
                sender.delegate = nil
                sender.close()
            }
            return false
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceModel.sqlWorkspace.flushDrafts()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
enum LucidSQLMain {
    @MainActor
    static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        self.delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
