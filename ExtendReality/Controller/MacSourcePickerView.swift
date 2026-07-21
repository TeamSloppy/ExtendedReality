import SwiftUI

struct MacSourcePickerView: View {
    let environment: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var startingApplicationID: String?
    @State private var isStartingDisplays = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        start(applicationID: nil)
                    } label: {
                        sourceRow(
                            title: "Mac displays",
                            detail: selectedDisplayLayout.detail,
                            systemImage: selectedDisplayLayout.systemImage,
                            isLoading: isStartingDisplays
                        )
                    }
                    .disabled(isSourceSelectionDisabled)
                    .accessibilityIdentifier("macSource.displays")
                } header: {
                    Text("Displays")
                } footer: {
                    Text("Uses the display layout selected in Settings.")
                }

                Section("Applications") {
                    if environment.macStreamClient.shareableApplications.isEmpty {
                        if environment.macStreamClient.isLoadingApplications {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Loading applications from Mac…")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ContentUnavailableView(
                                "No shareable applications",
                                systemImage: "macwindow.badge.exclamationmark",
                                description: Text("Open an application window on the Mac, then refresh the list.")
                            )
                        }
                    } else {
                        ForEach(environment.macStreamClient.shareableApplications) { application in
                            Button {
                                start(applicationID: application.id)
                            } label: {
                                sourceRow(
                                    title: application.name,
                                    detail: application.bundleIdentifier,
                                    systemImage: "macwindow",
                                    isLoading: startingApplicationID == application.id
                                )
                            }
                            .disabled(isSourceSelectionDisabled)
                            .accessibilityIdentifier("macSource.application.\(application.id)")
                        }
                    }
                }
            }
            .navigationTitle("Share from Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await environment.macStreamClient.refreshApplications() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(
                        environment.macStreamClient.isLoadingApplications
                            || environment.macStreamClient.isBusy
                            || isStarting
                    )
                }
            }
            .task {
                await environment.macStreamClient.refreshApplications()
            }
        }
        .alert("Mac connection failed", isPresented: connectionErrorPresented) {
            Button("OK") {
                environment.macStreamClient.dismissError()
            }
        } message: {
            if let message = environment.macStreamClient.applicationCatalogError {
                Text(message)
            } else if case .failed(let message) = environment.macStreamClient.state {
                Text(message)
            }
        }
    }

    private var selectedDisplayLayout: RemoteDisplayLayout {
        UserDefaults.standard.string(forKey: RemoteDisplayLayout.defaultsKey)
            .flatMap(RemoteDisplayLayout.init(rawValue:)) ?? .single
    }

    private var isStarting: Bool {
        isStartingDisplays || startingApplicationID != nil
    }

    private var isSourceSelectionDisabled: Bool {
        isStarting
            || environment.macStreamClient.isBusy
            || environment.macStreamClient.isLoadingApplications
    }

    private func start(applicationID: String?) {
        if let applicationID {
            startingApplicationID = applicationID
        } else {
            isStartingDisplays = true
        }
        ControllerHaptics.click()
        Task { @MainActor in
            await environment.openMacStream(applicationID: applicationID)
            isStartingDisplays = false
            startingApplicationID = nil
            if environment.macStreamClient.isConnected {
                dismiss()
            }
        }
    }

    private func sourceRow(
        title: String,
        detail: String,
        systemImage: String,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(.cyan)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionErrorPresented: Binding<Bool> {
        Binding(
            get: {
                if environment.macStreamClient.applicationCatalogError != nil { return true }
                if case .failed = environment.macStreamClient.state { return true }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    environment.macStreamClient.dismissApplicationCatalogError()
                    environment.macStreamClient.dismissError()
                }
            }
        )
    }
}

#if DEBUG
#Preview("Mac source picker") {
    MacSourcePickerView(environment: .preview(windowCount: 0))
}
#endif
