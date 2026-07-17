import SwiftUI

struct RemoteDisplayLayoutSettingsSection: View {
    @Binding var selection: RemoteDisplayLayout

    var body: some View {
        Section {
            ForEach(RemoteDisplayLayout.allCases) { layout in
                Button {
                    selection = layout
                    ControllerHaptics.selection()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: layout.systemImage)
                            .font(.title3)
                            .foregroundStyle(selection == layout ? Color.accentColor : Color.primary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(layout.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(layout.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if selection == layout {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selection == layout ? .isSelected : [])
                .accessibilityIdentifier("remoteDisplayLayout.\(layout.rawValue)")
            }
        } header: {
            Text("Mac Stream Layout")
        } footer: {
            Text("This preference is used for ExtendReality Mac streams. Multiple desktops and ultrawide use the displays selected on your Mac.")
        }
    }
}

#if DEBUG
#Preview("Display Layout Settings") {
    @Previewable @State var selection = RemoteDisplayLayout.ultrawide

    Form {
        RemoteDisplayLayoutSettingsSection(selection: $selection)
    }
}
#endif
