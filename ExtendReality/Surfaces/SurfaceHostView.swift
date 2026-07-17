import SwiftUI

struct SurfaceHostView: View {
    let window: WorkspaceWindow
    let environment: AppEnvironment

    var body: some View {
        switch window.source {
        case .browser(let url):
            BrowserSurfaceView(session: environment.surfaces.browser(for: window.id, initialURL: url))
        case .pwa(let installation, let displayMode):
            BrowserSurfaceView(
                session: environment.surfaces.pwa(
                    for: window.id,
                    installation: installation,
                    displayMode: displayMode
                )
            )
        case .gallery:
            MediaSurfaceView(session: environment.surfaces.mediaSession(for: window.id))
        case .youtube(let videoID):
            YouTubeSurfaceView(
                session: environment.surfaces.youtubeSession(for: window.id, initialVideoID: videoID)
            )
        case .remoteDesktop(let host):
            RemoteDesktopSurfaceView(
                session: environment.surfaces.remoteDesktop(for: window.id, initialHost: host)
            )
        }
    }
}

#if DEBUG
#Preview("Surface Host — Gallery") {
    let environment = AppEnvironment.preview()
    SurfaceHostView(
        window: environment.workspace.activeWindow!,
        environment: environment
    )
    .previewEnvironment(environment)
    .frame(width: 960, height: 540)
    .preferredColorScheme(.dark)
}
#endif
