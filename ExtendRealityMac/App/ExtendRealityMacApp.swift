import AppKit
import SwiftUI

@main
struct ExtendRealityMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var store = MacStreamingStore()

    var body: some Scene {
        WindowGroup("ExtendReality Mac", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Displays") {
                    Task { await store.refreshDisplays() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
