/**
 
 # App Entry Point
 
 Achraf Kassioui
 Created 19 Oct 2026
 Updated 20 Oct 2026
 
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
    
    /// Quit the app when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
}
