import SwiftUI

struct RuntimeInspectorView: View {
    let model: StudioAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                runtimeSection
                permissionsSection
                fixturesSection
                spatialSection
                cameraSection
                consoleSection
            }
            .padding(16)
        }
        .navigationTitle("Runtime")
    }

    private var runtimeSection: some View {
        InspectorGroup(title: "Runtime", systemImage: "bolt.horizontal.fill") {
            LabeledContent("State") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.primarySession.errorMessage == nil ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(model.primarySession.isLoading ? "Loading" : model.primarySession.errorMessage == nil ? "Live" : "Offline")
                }
            }
            LabeledContent("Panels", value: "\(model.layout.panels.count)")
            LabeledContent("Mode", value: model.displayMode.title)

            if let error = model.primarySession.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Launch", systemImage: "play.fill") { model.launch() }
                Button("Reload", systemImage: "arrow.clockwise") { model.reload() }
            }

            if model.serverCommand != nil {
                Button("Copy server command", systemImage: "doc.on.doc") {
                    model.copyServerCommand()
                }
            }

            Button("Clear website data", systemImage: "trash", role: .destructive) {
                Task { await model.clearWebsiteData() }
            }
        }
    }

    private var permissionsSection: some View {
        InspectorGroup(title: "Host permissions", systemImage: "checkmark.shield") {
            ForEach(PWACapability.allCases) { capability in
                Toggle(
                    capability.title,
                    isOn: Binding(
                        get: { model.grantedCapabilities.contains(capability) },
                        set: { model.setCapability(capability, isGranted: $0) }
                    )
                )
                .help(capability.explanation)
            }
        }
    }

    private var fixturesSection: some View {
        InspectorGroup(title: "Fixture data", systemImage: "slider.horizontal.3") {
            LabeledContent("Latitude") {
                TextField("Latitude", value: Binding(
                    get: { model.fixtures.latitude },
                    set: { model.fixtures.latitude = $0 }
                ), format: .number.precision(.fractionLength(4)))
                .frame(width: 100)
            }
            LabeledContent("Longitude") {
                TextField("Longitude", value: Binding(
                    get: { model.fixtures.longitude },
                    set: { model.fixtures.longitude = $0 }
                ), format: .number.precision(.fractionLength(4)))
                .frame(width: 100)
            }
            LabeledContent("Steps") {
                TextField("Steps", value: Binding(
                    get: { model.fixtures.steps },
                    set: { model.fixtures.steps = $0 }
                ), format: .number)
                .frame(width: 100)
            }
            LabeledContent("Heart rate") {
                TextField("Heart rate", value: Binding(
                    get: { model.fixtures.heartRate },
                    set: { model.fixtures.heartRate = $0 }
                ), format: .number)
                .frame(width: 100)
            }
            Toggle("Focus active", isOn: Binding(
                get: { model.fixtures.isFocusActive },
                set: { model.fixtures.isFocusActive = $0 }
            ))
        }
    }

    private var spatialSection: some View {
        InspectorGroup(title: "Spatial window", systemImage: "move.3d") {
            LabeledContent("Yaw", value: model.windowTransform.yaw.formatted(.number.precision(.fractionLength(1))))
            LabeledContent("Pitch", value: model.windowTransform.pitch.formatted(.number.precision(.fractionLength(1))))
            LabeledContent("Distance", value: model.windowTransform.distance.formatted(.number.precision(.fractionLength(2))))
            LabeledContent("Scale", value: model.windowTransform.scale.formatted(.number.precision(.fractionLength(2))))

            HStack {
                Button("Smaller") { model.adjustScale(by: 1 / 1.08) }
                Button("Larger") { model.adjustScale(by: 1.08) }
                Button("Reset") { model.resetTransform() }
            }
        }
    }

    private var cameraSection: some View {
        InspectorGroup(title: "Virtual camera", systemImage: "video") {
            LabeledContent("Yaw") {
                Slider(
                    value: Binding(
                        get: { model.cameraTransform.yaw },
                        set: { model.cameraTransform.yaw = $0 }
                    ),
                    in: -42 ... 42,
                    step: 1
                )
                .frame(width: 130)
            }
            LabeledContent("Pitch") {
                Slider(
                    value: Binding(
                        get: { model.cameraTransform.pitch },
                        set: { model.cameraTransform.pitch = $0 }
                    ),
                    in: -24 ... 24,
                    step: 1
                )
                .frame(width: 130)
            }
            LabeledContent("Direction") {
                Text("\(model.cameraTransform.yaw.formatted(.number.precision(.fractionLength(0))))° yaw · \(model.cameraTransform.pitch.formatted(.number.precision(.fractionLength(0))))° pitch")
                    .monospacedDigit()
            }

            HStack {
                Button("Left") { model.rotateCamera(yaw: -5) }
                Button("Right") { model.rotateCamera(yaw: 5) }
                Button("Up") { model.rotateCamera(pitch: 5) }
                Button("Down") { model.rotateCamera(pitch: -5) }
                Button("Reset") { model.resetCamera() }
            }
        }
    }

    private var consoleSection: some View {
        InspectorGroup(title: "Console", systemImage: "terminal") {
            HStack {
                Text("\(model.logs.count) events")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearLogs() }
                    .buttonStyle(.link)
            }

            if model.logs.isEmpty {
                Text("Browser and host messages appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.logs.suffix(80)) { entry in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: entry.level.symbol)
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.source) · \(entry.date.formatted(date: .omitted, time: .standard))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private func color(for level: StudioLogLevel) -> Color {
        switch level {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}
