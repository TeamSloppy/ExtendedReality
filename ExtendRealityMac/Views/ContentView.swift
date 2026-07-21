import SwiftUI

struct ContentView: View {
    let model: MacAppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Mode", selection: Bindable(model).mode) {
                    ForEach(MacRuntimeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                if model.mode == .sharing {
                    SourceSidebarView(store: model.sharing)
                } else {
                    DirectSourceSidebarView(store: model.direct)
                }
            }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if model.mode == .sharing {
                StreamDetailView(store: model.sharing)
            } else {
                DirectModeDetailView(store: model.direct)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            if model.mode == .sharing, model.sharing.displays.isEmpty {
                await model.sharing.refreshDisplays()
            } else if model.mode == .direct, model.direct.sources.isEmpty {
                await model.direct.refresh()
            }
        }
    }
}
