import SwiftUI

struct StudioRootView: View {
    let model: StudioAppModel
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        NavigationSplitView {
            StudioSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            GlassesViewport(model: model)
                .inspector(isPresented: Binding(
                    get: { model.isInspectorPresented },
                    set: { model.isInspectorPresented = $0 }
                )) {
                    RuntimeInspectorView(model: model)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            model.launch()
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                        }
                        .help("Load the selected PWA (Command-Return)")

                        Button {
                            model.reload()
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .help("Reload every panel (Command-R)")
                    }

                    ToolbarItem(placement: .principal) {
                        TextField("PWA address", text: Binding(
                            get: { model.address },
                            set: { model.address = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 320, idealWidth: 460, maxWidth: 620)
                        .focused($isAddressFocused)
                        .onSubmit { model.launch() }
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        Picker("Display mode", selection: Binding(
                            get: { model.displayMode },
                            set: { model.setDisplayMode($0) }
                        )) {
                            Label("Window", systemImage: "macwindow").tag(PWADisplayMode.window)
                            Label("Widget", systemImage: "rectangle.3.group").tag(PWADisplayMode.widget)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)

                        Button {
                            model.toggleInspector()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Toggle runtime inspector (Command-Option-I)")
                    }
                }
        }
        .frame(minWidth: 1_060, minHeight: 680)
        .task {
            if model.primarySession.currentURL == nil {
                model.launch()
            }
        }
        .onKeyPress("l", phases: .down) { event in
            guard event.modifiers.contains(.command) else { return .ignored }
            isAddressFocused = true
            return .handled
        }
    }
}
