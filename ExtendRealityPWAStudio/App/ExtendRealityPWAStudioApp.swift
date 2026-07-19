import AppKit
import SwiftUI

@main
struct ExtendRealityPWAStudioApp: App {
    @NSApplicationDelegateAdaptor(PWAStudioAppDelegate.self) private var appDelegate
    @State private var model = StudioAppModel()

    var body: some Scene {
        WindowGroup("ExtendReality PWA Studio", id: "main") {
            StudioRootView(model: model)
        }
        .defaultSize(width: 1_420, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open PWA Project Directory…") {
                    model.chooseProjectDirectory()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open Project in Terminal") {
                    model.openProjectInTerminal()
                }
                .disabled(model.projectDirectory == nil)
            }

            CommandMenu("PWA") {
                Button("Launch") { model.launch() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Reload All Panels") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("Window Mode") { model.setDisplayMode(.window) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Widget Mode") { model.setDisplayMode(.widget) }
                    .keyboardShortcut("2", modifiers: [.command])

                Divider()

                Button("Focus Next Panel") { model.focusNextPanel() }
                    .keyboardShortcut(.tab, modifiers: [.control])
                Button("Recenter Spatial Window") { model.resetTransform() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("Make Spatial Window Larger") { model.adjustScale(by: 1.08) }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Make Spatial Window Smaller") { model.adjustScale(by: 1 / 1.08) }
                    .keyboardShortcut("-", modifiers: [.command])
            }

            CommandGroup(after: .sidebar) {
                Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                    model.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

final class PWAStudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
