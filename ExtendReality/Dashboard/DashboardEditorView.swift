import SwiftUI

private enum DashboardEditorSheet: String, Identifiable {
    case bookmark

    var id: String { rawValue }
}

struct DashboardEditorView: View {
    @Bindable var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var presentedSheet: DashboardEditorSheet?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(dashboard.items) { item in
                        DashboardEditorRow(item: item)
                    }
                    .onDelete(perform: dashboard.remove)
                    .onMove(perform: dashboard.move)
                } header: {
                    Text("Dashboard items")
                } footer: {
                    Text("Drag items into any order. Shortcuts and widgets automatically continue onto additional pages.")
                }

                Section("Add") {
                    Menu("Application", systemImage: "app.dashed") {
                        ForEach(WindowKind.allCases) { kind in
                            Button(kind.title, systemImage: kind.systemImage) {
                                dashboard.addApp(kind)
                            }
                        }
                    }

                    Button("Browser Bookmark", systemImage: "bookmark.fill") {
                        presentedSheet = .bookmark
                    }

                    Menu("Widget", systemImage: "rectangle.3.group") {
                        ForEach(DashboardWidgetKind.allCases) { kind in
                            Button(kind.title, systemImage: kind.systemImage) {
                                dashboard.addWidget(kind)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .bookmark:
                BookmarkEditorView(dashboard: dashboard)
            }
        }
    }
}

private struct DashboardEditorRow: View {
    let item: DashboardItem

    var body: some View {
        HStack(spacing: 14) {
            icon
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.content {
        case .app(let kind):
            Image(systemName: kind.systemImage)
                .foregroundStyle(accent)
        case .bookmark(let bookmark):
            Text(bookmark.monogram)
                .font(.callout.weight(.bold))
                .foregroundStyle(accent)
        case .widget(let kind):
            Image(systemName: kind.systemImage)
                .foregroundStyle(accent)
        }
    }

    private var title: String {
        switch item.content {
        case .app(let kind): kind.title
        case .bookmark(let bookmark): bookmark.title
        case .widget(let kind): kind.title
        }
    }

    private var subtitle: String {
        switch item.content {
        case .app: "Application"
        case .bookmark(let bookmark): bookmark.url
        case .widget: "Widget"
        }
    }

    private var accent: Color {
        switch item.content {
        case .app(.gallery): .orange
        case .app(.browser): .cyan
        case .app(.youtube): .red
        case .app(.remoteDesktop): .purple
        case .bookmark(let bookmark): bookmark.accent.swiftUIColor
        case .widget(.calendar), .widget(.focus): .orange
        case .widget(.health): .pink
        }
    }
}

private struct BookmarkEditorView: View {
    let dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var accent: DashboardAccent = .blue
    @State private var showsValidationError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bookmark") {
                    TextField("Name", text: $title)
                        .textInputAutocapitalization(.words)
                    TextField("Website URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Color") {
                    Picker("Accent", selection: $accent) {
                        ForEach(DashboardAccent.allCases, id: \.self) { color in
                            Label(color.title, systemImage: "circle.fill")
                                .foregroundStyle(color.swiftUIColor)
                                .tag(color)
                        }
                    }
                }

                if showsValidationError {
                    Section {
                        Label("Enter a name and a valid website address.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("New Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if dashboard.addBookmark(title: title, url: url, accent: accent) {
                            dismiss()
                        } else {
                            showsValidationError = true
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private extension DashboardAccent {
    var title: String {
        rawValue.capitalized
    }

    var swiftUIColor: Color {
        switch self {
        case .orange: .orange
        case .cyan: .cyan
        case .red: .red
        case .purple: .purple
        case .blue: .blue
        case .green: .green
        case .pink: .pink
        }
    }
}

#if DEBUG
#Preview("Dashboard Editor") {
    let environment = AppEnvironment.preview(windowCount: 0)
    DashboardEditorView(dashboard: environment.dashboard)
        .previewEnvironment(environment)
}

#Preview("New Bookmark") {
    let environment = AppEnvironment.preview(windowCount: 0)
    BookmarkEditorView(dashboard: environment.dashboard)
        .previewEnvironment(environment)
}
#endif
