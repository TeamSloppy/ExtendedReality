import SwiftUI

struct ContentView: View {
    let store: MacStreamingStore

    var body: some View {
        NavigationSplitView {
            SourceSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            StreamDetailView(store: store)
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            if store.displays.isEmpty {
                await store.refreshDisplays()
            }
        }
    }
}
