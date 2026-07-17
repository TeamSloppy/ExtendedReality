import SwiftUI

struct StreamDetailView: View {
    let store: MacStreamingStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            preview
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.state == .capturing {
                    Button("Stop", systemImage: "stop.fill") {
                        Task { await store.stop() }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Start", systemImage: "play.fill") {
                        Task { await store.start() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canStart)
                }
            }
        }
        .alert("Capture failed", isPresented: failurePresented) {
            Button("Try again") {
                Task { await store.refreshDisplays() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .failed(let message) = store.state {
                Text(message)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: store.layout.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(store.layout.title)
                    .font(.title2.weight(.semibold))
                Text(store.layout.detail)
                    .foregroundStyle(.secondary)
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let address = store.streamAddress {
                VStack(alignment: .trailing, spacing: 4) {
                    Link(destination: address) {
                        Label("Open stream", systemImage: "network")
                    }
                    .font(.callout.weight(.medium))
                    Text(address.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(viewerSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var preview: some View {
        if store.layout == .ultrawide, let image = store.compositeFrame {
            PreviewImage(image: image, title: "Ultrawide canvas")
                .padding(24)
        } else if !store.frames.isEmpty {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(store.selectedDisplays) { display in
                        if let image = store.frames[display.id] {
                            PreviewImage(image: image, title: display.name)
                        }
                    }
                }
                .padding(24)
            }
        } else {
            ContentUnavailableView {
                Label("Preview is paused", systemImage: "display")
            } description: {
                Text("Select displays and start capture. macOS will ask for Screen Recording permission the first time.")
            } actions: {
                Button("Start capture") {
                    Task { await store.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStart)
            }
        }
    }

    private var gridColumns: [GridItem] {
        store.layout == .single
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 360), spacing: 16)]
    }

    private var selectionSummary: String {
        let count = store.selectedDisplayIDs.count
        return count == 1 ? "1 display selected" : "\(count) displays selected"
    }

    private var viewerSummary: String {
        let count = store.connectedViewerCount
        return count == 1 ? "1 viewer" : "\(count) viewers"
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: {
                if case .failed = store.state { return true }
                return false
            },
            set: { _ in }
        )
    }
}

private struct PreviewImage: View {
    let image: CGImage
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.low)
                .scaledToFit()
                .background(.black)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
