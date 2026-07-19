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
                Button {
                    model.chooseProjectDirectory()
                } label: {
                    Label(
                        model.projectDirectory == nil ? "Choose project directory" : "Change project directory",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(.plain)

                if let projectDirectory = model.projectDirectory,
                   model.selectedPreset == .custom {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(projectDirectory.lastPathComponent)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(projectDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    if !model.packageScripts.isEmpty {
                        Picker("Package script", selection: Binding(
                            get: { model.selectedPackageScriptName },
                            set: { model.selectPackageScript($0) }
                        )) {
                            Text("Custom command").tag(String?.none)
                            ForEach(model.packageScripts) { script in
                                Text(script.name).tag(String?.some(script.name))
                            }
                        }
                    }

                    TextField("Launch command", text: Binding(
                        get: { model.launchCommand },
                        set: { model.setLaunchCommand($0) }
                    ), axis: .vertical)
                    .font(.caption.monospaced())
                    .lineLimit(2 ... 4)

                    Button {
                        model.openProjectInTerminal()
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Copies the full command and opens Terminal in the project directory. Paste it to run.")

                    Button(role: .destructive) {
                        model.forgetProjectDirectory()
                    } label: {
                        Label("Forget directory", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                } else if let command = model.serverCommand {
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

                if let issue = model.projectIssue {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        if let reason = issue.reason {
                            Text(reason)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let recoverySuggestion = issue.recoverySuggestion {
                            Text(recoverySuggestion)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        DisclosureGroup("Technical details") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(issue.diagnostics)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button("Copy diagnostics") {
                                    model.copyProjectDiagnostics()
                                }
                                .buttonStyle(.link)
                            }
                            .padding(.top, 4)
                        }

                        if model.projectDirectory == nil {
                            Button("Clear saved directory access", role: .destructive) {
                                model.forgetProjectDirectory()
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }

                Label(
                    model.selectedPreset == .custom ? "External server workflow" : "Vite HMR enabled",
                    systemImage: model.selectedPreset == .custom ? "server.rack" : "bolt.horizontal.circle.fill"
                )
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
