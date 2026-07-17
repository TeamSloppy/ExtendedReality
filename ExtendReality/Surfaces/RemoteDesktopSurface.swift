import SwiftUI

struct RemoteDesktopSurfaceView: View {
    let session: RoyalVNCSession

    var body: some View {
        ZStack {
            Color.black
            if let framebuffer = session.framebuffer {
                Image(decorative: framebuffer, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                VStack(spacing: 14) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 44))
                    Text(statusTitle)
                        .font(.headline)
                    if case .failed(let message) = session.connectionState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Configure macOS Screen Sharing on the iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
    }

    private var statusTitle: String {
        switch session.connectionState {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .failed: "Connection failed"
        }
    }

    private var statusIcon: String {
        switch session.connectionState {
        case .connected: "desktopcomputer"
        case .connecting, .disconnecting: "network"
        case .disconnected: "display"
        case .failed: "exclamationmark.triangle"
        }
    }
}

#if DEBUG
#Preview("Remote Desktop Surface — Disconnected") {
    let environment = AppEnvironment.preview(windowCount: 0)
    let session = environment.surfaces.remoteDesktop(
        for: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        initialHost: "Mac-Studio.local"
    )
    RemoteDesktopSurfaceView(session: session)
        .previewEnvironment(environment)
        .frame(width: 960, height: 540)
        .preferredColorScheme(.dark)
}
#endif
