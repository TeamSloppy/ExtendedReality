import XCTest
@testable import ExtendReality

final class DeviceWorkspacePresentationTests: XCTestCase {
    func testDashboardPresentsDeviceLauncher() {
        let window = WorkspaceWindow(title: "YouTube", source: .youtube(videoID: nil))

        XCTAssertEqual(
            DeviceWorkspacePresentation.resolve(
                isDashboardPresented: true,
                presentationMode: .windows,
                activeWindow: window
            ),
            .launcher
        )
    }

    func testActiveWindowPresentsOnDevice() {
        let window = WorkspaceWindow(title: "YouTube", source: .youtube(videoID: nil))

        XCTAssertEqual(
            DeviceWorkspacePresentation.resolve(
                isDashboardPresented: false,
                presentationMode: .windows,
                activeWindow: window
            ),
            .window(window.id)
        )
    }

    func testMinimizedWindowFallsBackToLauncher() {
        let window = WorkspaceWindow(
            title: "YouTube",
            source: .youtube(videoID: nil),
            isMinimized: true
        )

        XCTAssertEqual(
            DeviceWorkspacePresentation.resolve(
                isDashboardPresented: false,
                presentationMode: .windows,
                activeWindow: window
            ),
            .launcher
        )
    }
}
