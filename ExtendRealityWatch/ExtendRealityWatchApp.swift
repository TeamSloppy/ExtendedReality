import SwiftUI

@main
struct ExtendRealityWatchApp: App {
    @State private var controller = WatchControlModel()

    var body: some Scene {
        WindowGroup {
            WatchControlView(controller: controller)
        }
    }
}
