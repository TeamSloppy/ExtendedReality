import SwiftUI

struct PWAStoreView: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var selectedApp: PWAAppManifest?

    private var store: PWAStore { environment.pwaStore }

    var body: some View {
        NavigationStack {
            List {
                safetySection
                installedSection
                catalogSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Web App Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(store.catalogEndpoint == nil || store.catalogState == .loading)
                }
            }
            .task {
                guard store.catalogState == .idle else { return }
                await store.refresh()
            }
            .refreshable {
                await store.refresh()
            }
        }
        .sheet(item: $selectedApp) { app in
            PWAInstallView(manifest: app, environment: environment)
        }
    }

    private var safetySection: some View {
        Section {
            Picker(
                "Declared age",
                selection: Binding(
                    get: { store.declaredAge },
                    set: { store.setDeclaredAge($0) }
                )
            ) {
                Text("Not set").tag(Int?.none)
                ForEach([4, 9, 12, 16, 18], id: \.self) { age in
                    Text("\(age)+").tag(Int?.some(age))
                }
            }
        } header: {
            Text("Safety")
        } footer: {
            Text("Apps above the selected age remain visible but cannot be installed.")
        }
    }

    private var installedSection: some View {
        Section("Installed") {
            if store.installations.isEmpty {
                Label("No web apps installed", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.installations) { installation in
                    NavigationLink {
                        PWAInstalledAppView(installation: installation, environment: environment)
                    } label: {
                        PWAAppRow(manifest: installation.manifest, accessory: .installed)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section {
            switch store.catalogState {
            case .idle, .loading:
                HStack {
                    ProgressView()
                    Text("Loading curated catalog…")
                        .foregroundStyle(.secondary)
                }
            case .notConfigured:
                ContentUnavailableView(
                    "Catalog not configured",
                    systemImage: "shippingbox",
                    description: Text("Set ExtendRealityPWACatalogURL to your HTTPS catalog endpoint.")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Catalog unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
            case .loaded:
                if store.catalog.isEmpty {
                    ContentUnavailableView(
                        "No apps yet",
                        systemImage: "app.dashed",
                        description: Text("Published apps will appear here after catalog review.")
                    )
                } else {
                    ForEach(store.catalog) { app in
                        HStack(spacing: 12) {
                            PWAAppRow(
                                manifest: app,
                                accessory: store.isInstalled(app.id) ? .installed : .age(app.minimumAge)
                            )
                            Spacer(minLength: 8)
                            if store.isInstalled(app.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Installed")
                            } else {
                                Button("Get") { selectedApp = app }
                                    .buttonStyle(.borderedProminent)
                                    .buttonBorderShape(.capsule)
                                    .disabled(!store.isAllowedForDeclaredAge(app))
                                    .accessibilityHint(
                                        store.isAllowedForDeclaredAge(app)
                                            ? "Review permissions and install"
                                            : "Requires declared age \(app.minimumAge) or older"
                                    )
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Curated catalog")
        } footer: {
            Text("Every app is indexed, age-rated, and reviewed before appearing in this build.")
        }
    }
}

private struct PWAInstallView: View {
    let manifest: PWAAppManifest
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var grantedCapabilities: Set<PWACapability> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        PWAAppIcon(manifest: manifest, size: 64)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(manifest.name)
                                .font(.title3.bold())
                            Text(manifest.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(manifest.developer) · \(manifest.minimumAge)+")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    if manifest.requestedCapabilities.isEmpty {
                        Label("This app requests no additional capabilities.", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        ForEach(manifest.requestedCapabilities) { capability in
                            Toggle(
                                isOn: Binding(
                                    get: { grantedCapabilities.contains(capability) },
                                    set: { granted in
                                        if granted { grantedCapabilities.insert(capability) }
                                        else { grantedCapabilities.remove(capability) }
                                    }
                                )
                            ) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(capability.title)
                                        Text(capability.explanation)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: capability.systemImage)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("All capabilities start off. You can change them later for this app.")
                }

                Section("Runs as") {
                    ForEach(manifest.displayModes) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Install App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") { install() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func install() {
        do {
            _ = try environment.installPWA(
                manifest,
                grantedCapabilities: grantedCapabilities
            )
            ControllerHaptics.click()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PWAInstalledAppView: View {
    let installation: PWAInstallation
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false
    @State private var errorMessage: String?

    private var current: PWAInstallation {
        environment.pwaStore.installation(for: installation.id) ?? installation
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PWAAppIcon(manifest: current.manifest, size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.manifest.name)
                            .font(.title3.bold())
                        Text("Version \(current.manifest.version) · \(current.manifest.developer)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Open") {
                ForEach(current.manifest.displayModes) { mode in
                    Button {
                        environment.openPWA(current, displayMode: mode)
                        ControllerHaptics.click()
                        dismiss()
                    } label: {
                        Label("Open as \(mode.title.lowercased())", systemImage: mode.systemImage)
                    }
                }
            }

            Section {
                if current.manifest.requestedCapabilities.isEmpty {
                    Label("No additional capabilities requested", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(current.manifest.requestedCapabilities) { capability in
                        Toggle(
                            capability.title,
                            systemImage: capability.systemImage,
                            isOn: Binding(
                                get: { current.grants(capability) },
                                set: { update(capability, granted: $0) }
                            )
                        )
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Changes apply to existing and future windows for this app.")
            }

            Section {
                LabeledContent("App ID", value: current.id)
                LabeledContent("Origin", value: current.manifest.launchURL.host ?? current.manifest.launchURL.absoluteString)
                LabeledContent("Age rating", value: "\(current.manifest.minimumAge)+")
            } header: {
                Text("Details")
            }

            Section {
                Button("Remove Web App", systemImage: "trash", role: .destructive) {
                    confirmsRemoval = true
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(current.manifest.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(current.manifest.name)?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove App and Data", role: .destructive) {
                Task { await remove() }
            }
        } message: {
            Text("Open windows, permissions, cookies, caches, and local web data will be deleted.")
        }
    }

    private func update(_ capability: PWACapability, granted: Bool) {
        do {
            try environment.pwaStore.setCapability(capability, granted: granted, for: current.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() async {
        do {
            try await environment.uninstallPWA(current.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum PWAAppRowAccessory {
    case installed
    case age(Int)
}

private struct PWAAppRow: View {
    let manifest: PWAAppManifest
    let accessory: PWAAppRowAccessory

    var body: some View {
        HStack(spacing: 12) {
            PWAAppIcon(manifest: manifest, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(manifest.name)
                    .font(.body.weight(.semibold))
                Text(manifest.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                switch accessory {
                case .installed:
                    Text("Installed · \(manifest.version)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .age(let age):
                    Text("\(manifest.developer) · \(age)+")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

private struct PWAAppIcon: View {
    let manifest: PWAAppManifest
    let size: CGFloat

    var body: some View {
        Text(manifest.monogram)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: manifest.accentHex), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(value, radix: 16) ?? 0x2563EB
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

#if DEBUG
#Preview("PWA Store") {
    PWAStoreView(environment: .preview(windowCount: 0))
}
#endif
