/**
 
 # App Entry Point
 
 Achraf Kassioui
 Created 19 Oct 2026
 Updated 30 Oct 2026
 
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
        }
    }
}

// MARK: App Lifeycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    /// Offer New Window when the app icon is clicked in the Dock.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let command = NSMenuItem(title: "New Window", action: #selector(newWindowFromDock(_:)), keyEquivalent: "")
        command.target = self
        menu.addItem(command)
        return menu
    }
    
    /// Run the same command as File → New Window.
    @objc private func newWindowFromDock(_ sender: Any?) {
        let commands = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        guard let command = commands.first(where: {
            $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command
        }), let action = command.action else { return }
        NSApp.activate()
        NSApp.sendAction(action, to: command.target, from: command)
    }
    
    /// Quit the app when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
}
