import AppKit
import SwiftUI

@MainActor
final class DirectDisplayWindowController {
    var onOutputUnavailable: (() -> Void)?
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var outputDisplayID: CGDirectDisplayID?

    func show(on screen: NSScreen, store: DirectModeStore) {
        close()
        outputDisplayID = DirectCaptureCoordinator.displayID(for: screen)
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .mainMenu + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: DirectSpatialCanvasView(store: store))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.validateOutput() }
        }
    }

    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        outputDisplayID = nil
    }

    private func validateOutput() {
        guard let outputDisplayID else { return }
        guard let screen = NSScreen.screens.first(where: {
            DirectCaptureCoordinator.displayID(for: $0) == outputDisplayID
        }) else {
            close()
            onOutputUnavailable?()
            return
        }
        window?.setFrame(screen.frame, display: true)
    }
}
