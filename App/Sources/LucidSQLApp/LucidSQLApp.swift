import SwiftUI
import AppKit
import LucidSQL

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    let workspaceModel = WorkspaceModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenuBar()

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

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About LucidSQL", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsSheet), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LucidSQL", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit Menu (enables standard copy/paste/select-all in NSTextView and TextFields)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsSheet() {
        workspaceModel.isShowingSettingsSheet = true
    }

    private func confirmLifecycleExit(title: String, actionVerb: String, primaryButtonTitle: String) -> Bool {
        let summary = workspaceModel.lifecycleSummary
        guard !summary.isEmpty else {
            workspaceModel.sqlWorkspace.flushDrafts()
            return true
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = workspaceModel.formattedLifecycleWarning(actionVerb: actionVerb)
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let summary = workspaceModel.lifecycleSummary
        guard !summary.isEmpty else {
            workspaceModel.sqlWorkspace.flushDrafts()
            return true
        }

        let confirmed = confirmLifecycleExit(
            title: "Close LucidSQL?",
            actionVerb: "close the window",
            primaryButtonTitle: "Clean Up, Discard & Close"
        )
        if confirmed {
            Task { @MainActor in
                await workspaceModel.performConfirmedDisconnect()
                sender.delegate = nil
                sender.close()
            }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let summary = workspaceModel.lifecycleSummary
        guard !summary.isEmpty else {
            workspaceModel.sqlWorkspace.flushDrafts()
            return .terminateNow
        }

        let confirmed = confirmLifecycleExit(
            title: "Quit LucidSQL?",
            actionVerb: "quit",
            primaryButtonTitle: "Clean Up, Discard & Quit"
        )
        guard confirmed else {
            return .terminateCancel
        }

        Task { @MainActor in
            await workspaceModel.performBoundedTeardown(timeoutSeconds: 2.5)
            workspaceModel.tableViewModel.discardChanges()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
