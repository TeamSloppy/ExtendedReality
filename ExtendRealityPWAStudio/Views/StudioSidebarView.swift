import SwiftUI

struct StudioSidebarView: View {
    let model: StudioAppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedPreset },
            set: { model.selectPreset($0) }
        )) {
            Section("Preview") {
                ForEach(StudioPreset.allCases) { preset in
                    HStack(spacing: 10) {
                        Image(systemName: preset.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .lineLimit(1)
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(preset)
                }
            }

            Section("Development") {
                if let command = model.serverCommand {
                    Button {
                        model.copyServerCommand()
                    } label: {
                        Label("Copy server command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)

                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Label("Vite HMR enabled", systemImage: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PWA Studio")
        .safeAreaInset(edge: .bottom) {
            Text(model.serverHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }
}
