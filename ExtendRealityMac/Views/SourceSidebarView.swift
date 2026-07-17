import SwiftUI

struct SourceSidebarView: View {
    let store: MacStreamingStore

    var body: some View {
        List {
            Section("Layout") {
                ForEach(StreamLayout.allCases) { layout in
                    Button {
                        store.layout = layout
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layout.title)
                                Text(layout.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: layout.systemImage)
                                .frame(width: 18)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(store.layout == layout ? Color.accentColor.opacity(0.16) : nil)
                }
            }

            Section("Displays") {
                if store.displays.isEmpty {
                    Text("No displays found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.displays) { display in
                        Button {
                            store.select(display.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: store.selectedDisplayIDs.contains(display.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.selectedDisplayIDs.contains(display.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                        .lineLimit(1)
                                    Text(display.resolutionDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Label(store.state.title, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Spacer()
                Button {
                    Task { await store.refreshDisplays() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh displays")
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var statusSymbol: String {
        switch store.state {
        case .idle, .ready: "circle"
        case .loading: "arrow.trianglehead.2.clockwise.rotate.90"
        case .capturing: "dot.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch store.state {
        case .capturing: .green
        case .failed: .orange
        default: .secondary
        }
    }
}
