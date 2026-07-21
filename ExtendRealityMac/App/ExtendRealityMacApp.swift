import AppKit
import SwiftUI

@main
struct ExtendRealityMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var model = MacAppModel()

    var body: some Scene {
        WindowGroup("ExtendReality Mac", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Displays") {
                    Task {
                        if model.mode == .sharing { await model.sharing.refreshDisplays() }
                        else { await model.direct.refresh() }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Direct Mode") {
                Button(model.direct.isPointerCaptured ? "Release Spatial Pointer" : "Capture Spatial Pointer") {
                    model.direct.togglePointerCapture()
                }
                .keyboardShortcut(.space, modifiers: [.control, .option])
                .disabled(model.direct.state != .running)

                Button("Recenter") { model.direct.recenter() }
                    .keyboardShortcut("r", modifiers: [.control, .option])
                    .disabled(model.direct.state != .running)
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
