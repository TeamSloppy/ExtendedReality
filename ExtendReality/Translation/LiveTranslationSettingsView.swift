import SwiftUI

struct LiveTranslationSettingsView: View {
    @Bindable var translation: LiveTranslationController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Languages") {
                    Picker("Spoken language", selection: $translation.sourceLanguage) {
                        ForEach(LiveTranslationLanguage.allCases.filter { $0 != translation.targetLanguage }) { language in
                            Text(language.title).tag(language)
                        }
                    }

                    Button("Swap languages", systemImage: "arrow.up.arrow.down") {
                        translation.swapLanguages()
                        ControllerHaptics.selection()
                    }

                    Picker("Subtitle language", selection: $translation.targetLanguage) {
                        ForEach(LiveTranslationLanguage.allCases.filter { $0 != translation.sourceLanguage }) { language in
                            Text(language.title).tag(language)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await translation.toggle() }
                        ControllerHaptics.click()
                    } label: {
                        Label(
                            translation.state.isActive ? "Stop Live Translation" : "Start Live Translation",
                            systemImage: translation.state.isActive ? "stop.circle.fill" : "mic.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(translation.state.isActive ? .red : .cyan)
                } footer: {
                    Text("Audio and translated text stay on this device. The first translation may ask to download Apple’s language models.")
                }

                Section("Status") {
                    Label(translation.statusText, systemImage: statusSystemImage)
                        .foregroundStyle(statusColor)

                    if !translation.sourceText.isEmpty {
                        LabeledContent("Heard") {
                            Text(translation.sourceText)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    if !translation.translatedText.isEmpty {
                        LabeledContent("Subtitles") {
                            Text(translation.translatedText)
                                .fontWeight(.semibold)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle("Live Translation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusSystemImage: String {
        switch translation.state {
        case .idle: "mic.slash"
        case .starting: "hourglass"
        case .listening: "waveform.and.mic"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch translation.state {
        case .idle: .secondary
        case .starting: .orange
        case .listening: .green
        case .failed: .red
        }
    }
}

#if DEBUG
#Preview("Live Translation Settings") {
    let environment = AppEnvironment.preview(windowCount: 0)
    LiveTranslationSettingsView(translation: environment.liveTranslation)
        .previewEnvironment(environment)
}
#endif
