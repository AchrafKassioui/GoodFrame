/**
 
 # App Entry Point
 
 Achraf Kassioui
 Created 19 Oct 2026
 Updated 31 Oct 2026
 
 */
import SwiftUI

@main
struct GoodFrameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        WindowGroup(id: "cropper", for: UUID.self) { identity in
            EditorView(windowIdentity: identity.wrappedValue)
                .frame(minWidth: 800, minHeight: 480)
                .frame(idealWidth: 1280, idealHeight: 800)
        } defaultValue: {
            UUID()
        }
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CropHistoryCommands()
            CropWindowCommands()
            /// Open the app website from the Help menu.
            CommandGroup(replacing: .help) {
                Link("Good Frame Website", destination: URL(string: "https://www.achrafkassioui.com/good-frame")!)
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

// MARK: App Lifeycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    /// Offer New Window when the app icon is clicked in the Dock.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let command = NSMenuItem(title: String(localized: "New Window"), action: #selector(newWindowFromDock(_:)), keyEquivalent: "")
        command.target = self
        menu.addItem(command)
        return menu
    }
    
    @MainActor @objc private func newWindowFromDock(_ sender: Any?) {
        NSApp.activate()
        CropWindowRegistry.shared.openNewWindow?()
    }
    
    /// Ask before quitting while an export is in progress.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !CropWindowRegistry.shared.exportingWindows.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Cancel Export and Quit?")
        alert.informativeText = String(localized: "The unfinished export will be discarded.")
        alert.addButton(withTitle: String(localized: "Keep Exporting"))
        alert.addButton(withTitle: String(localized: "Cancel Export and Quit")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    
    /// Quit the app when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
}
