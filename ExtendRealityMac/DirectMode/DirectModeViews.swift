import SwiftUI

struct DirectSourceSidebarView: View {
    let store: DirectModeStore

    var body: some View {
        List {
            Section("Output") {
                Picker("Glasses display", selection: Binding(
                    get: { store.selectedOutputDisplayID },
                    set: { store.selectOutput($0) }
                )) {
                    Text("Choose display").tag(CGDirectDisplayID?.none)
                    ForEach(store.outputDisplays) { display in
                        VStack(alignment: .leading) {
                            Text(display.name)
                            Text(display.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(Optional(display.id))
                    }
                }
                .disabled(store.state == .running)

                if let issue = store.outputConfigurationIssue {
                    Label(
                        issue,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            sourceSection(title: "Displays", kind: .display)
            sourceSection(title: "Applications", kind: .application)

            let unavailable = store.workspace.windows.filter { window in
                guard case .macCapture(let reference) = window.source else { return false }
                return store.source(for: reference) == nil
            }
            if !unavailable.isEmpty {
                Section("Unavailable") {
                    ForEach(unavailable) { window in
                        Label(window.title, systemImage: "questionmark.app.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack {
                    Circle()
                        .fill(store.state == .running ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(store.statusTitle).font(.caption)
                    Spacer()
                }
                if store.state != .running, let issue = store.configurationIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(store.state == .running ? "Stop Direct Mode" : "Start Direct Mode") {
                    Task {
                        if store.state == .running { await store.stop() }
                        else { await store.start() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(store.state == .running ? .red : .accentColor)
                .frame(maxWidth: .infinity)
                .disabled(store.state == .loading)
                .help(store.configurationIssue ?? "Open Direct Mode on the selected glasses display")
            }
            .padding()
            .background(.bar)
        }
    }

    private func sourceSection(title: String, kind: DirectCaptureSource.Kind) -> some View {
        Section(title) {
            ForEach(store.sources.filter { $0.kind == kind }) { source in
                Toggle(isOn: Binding(
                    get: { store.isSelected(source) },
                    set: { store.setSource(source, selected: $0) }
                )) {
                    Label(
                        source.title,
                        systemImage: kind == .display ? "display" : "app"
                    )
                }
            }
        }
    }
}

struct DirectModeDetailView: View {
    let store: DirectModeStore

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Direct Spatial Mode").font(.largeTitle.bold())
                    Text("Local 60 fps capture → Metal compositor → selected 1080p output")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
            }

            HStack(spacing: 16) {
                statusCard(
                    title: "Tracking",
                    value: store.headPose.statusText,
                    icon: store.headPose.isTracking ? "gyroscope" : "gyroscope.slash"
                )
                statusCard(
                    title: "Spatial Pointer",
                    value: store.inputStatus,
                    icon: "cursorarrow.motionlines"
                )
                statusCard(
                    title: "Surfaces",
                    value: "\(store.selectedReferences.count) selected",
                    icon: "rectangle.3.group"
                )
            }

            if case .failed(let message) = store.state {
                ContentUnavailableView(
                    "Direct Mode needs attention",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else if store.selectedReferences.isEmpty {
                ContentUnavailableView(
                    "Choose Mac surfaces",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Select one or more displays or applications in the sidebar.")
                )
            } else {
                previewGrid
            }

            HStack {
                Button(store.isPointerCaptured ? "Release Pointer" : "Capture Pointer") {
                    store.togglePointerCapture()
                }
                .disabled(store.state != .running)
                Button("Open Privacy Settings") { store.openInputPrivacySettings() }
                Spacer()
                Text("⌃⌥Space captures · Esc releases · ⌃⌥R recenters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private var previewGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 18)], spacing: 18) {
                ForEach(store.workspace.windows) { window in
                    if case .macCapture(let reference) = window.source {
                        VStack(alignment: .leading, spacing: 8) {
                            Group {
                                if store.source(for: reference) != nil {
                                    ZStack {
                                        DirectMetalSurfaceView(pixelBuffer: store.frames[reference])
                                        if store.frames[reference] == nil {
                                            Text(store.state == .running ? "Waiting for first frame…" : "Preview starts with Direct Mode")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                } else {
                                    ContentUnavailableView("Unavailable", systemImage: "questionmark.app.dashed")
                                }
                            }
                            .frame(height: 180)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(window.title).font(.headline)
                        }
                    }
                }
            }
        }
    }

    private func statusCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 28)
            VStack(alignment: .leading) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).lineLimit(2)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

enum DirectWindowGeometry {
    static let controlHeight: CGFloat = 42
    static let topGap: CGFloat = 8
    static let handleHeight: CGFloat = 18
    static let bottomGap: CGFloat = 8
    static let chromeHeight = controlHeight + topGap + handleHeight + bottomGap

    static func surfaceFrame(in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX,
            y: windowFrame.minY + controlHeight + topGap,
            width: windowFrame.width,
            height: max(1, windowFrame.height - chromeHeight)
        )
    }
}

struct DirectSpatialCanvasView: View {
    let store: DirectModeStore

    var body: some View {
        GeometryReader { proxy in
            let viewport = CGRect(origin: .zero, size: proxy.size)
            let visible = store.workspace.windows.filter { !$0.isMinimized }
            let presentations = store.workspace.presentations(for: visible, headPose: store.headPose.pose)
            let frames = Dictionary(uniqueKeysWithValues: visible.compactMap { window -> (UUID, CGRect)? in
                guard let presentation = presentations[window.id] else { return nil }
                let raw = WindowProjection.frame(
                    for: presentation.window.transform,
                    in: viewport,
                    headPose: presentation.projectionHeadPose
                )
                return (window.id, WindowProjection.framePreservingContentAspect(
                    raw,
                    contentAspectRatio: window.contentAspectRatio,
                    verticalChrome: DirectWindowGeometry.chromeHeight
                ))
            })

            ZStack {
                Color.black.ignoresSafeArea()
                ForEach(visible.sorted(by: { $0.zIndex < $1.zIndex })) { window in
                    if let presentation = presentations[window.id], let frame = frames[window.id] {
                        DirectSpatialWindowView(
                            store: store,
                            window: window,
                            frame: frame
                        )
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .rotationEffect(.degrees(presentation.rotationDegrees))
                    }
                }

                VStack {
                    HStack(spacing: 8) {
                        Circle().fill(store.headPose.isTracking ? .green : .orange).frame(width: 8, height: 8)
                        Text(store.headPose.statusText)
                        Spacer()
                        Text(store.inputStatus)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    Spacer()
                    DirectSpatialDock(store: store)
                        .padding(.bottom, 18)
                }

                if store.isPointerCaptured {
                    Circle()
                        .fill(.white)
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                        .frame(width: 13, height: 13)
                        .position(
                            x: store.virtualCursor.x * proxy.size.width,
                            y: store.virtualCursor.y * proxy.size.height
                        )
                        .allowsHitTesting(false)
                }
            }
            .onAppear { store.updateCanvas(size: proxy.size, windowFrames: frames) }
            .onChange(of: frames) { _, value in store.updateCanvas(size: proxy.size, windowFrames: value) }
            .onChange(of: proxy.size) { _, value in store.updateCanvas(size: value, windowFrames: frames) }
        }
        .preferredColorScheme(.dark)
    }
}

private struct DirectSpatialWindowView: View {
    let store: DirectModeStore
    let window: WorkspaceWindow
    let frame: CGRect
    @State private var lastMoveTranslation = CGSize.zero
    @State private var lastResizeTranslation = CGSize.zero

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label(window.title, systemImage: window.systemImage).lineLimit(1)
                Spacer()
                Button { store.workspace.toggleAttachmentMode(for: window.id, headPose: store.headPose.pose) } label: {
                    Image(systemName: window.attachmentMode.systemImage)
                }
                Button { store.workspace.adjustWindowDistance(window.id, by: -0.08) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                Button { store.workspace.adjustWindowDistance(window.id, by: 0.08) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                Button { store.workspace.toggleMinimize(window.id) } label: { Image(systemName: "minus") }
                Button { store.workspace.toggleExpanded(window.id, for: store.headPose.pose) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                Button { store.removeWindow(window.id) } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: DirectWindowGeometry.controlHeight)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: Capsule())

            Group {
                if case .macCapture(let reference) = window.source,
                   store.source(for: reference) != nil {
                    DirectMetalSurfaceView(pixelBuffer: store.frames[reference])
                } else {
                    ContentUnavailableView(
                        "Source unavailable",
                        systemImage: "questionmark.app.dashed",
                        description: Text("The window will reconnect when its display or application returns.")
                    )
                }
            }
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                store.workspace.activeWindowID == window.id ? .blue : .white.opacity(0.2),
                lineWidth: 2
            ))
            .onTapGesture { store.workspace.focus(window.id) }

            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: 110, height: 7)
                .frame(height: DirectWindowGeometry.handleHeight)
                .contentShape(Rectangle())
                .gesture(moveGesture)
        }
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 7, height: 92)
                .padding(.top, DirectWindowGeometry.controlHeight)
                .contentShape(Rectangle().inset(by: -12))
                .gesture(resizeGesture)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - lastMoveTranslation.width,
                    height: value.translation.height - lastMoveTranslation.height
                )
                lastMoveTranslation = value.translation
                store.workspace.moveWindow(window.id, normalizedDelta: CGVector(
                    dx: delta.width / max(frame.width, 1),
                    dy: delta.height / max(frame.height, 1)
                ))
            }
            .onEnded { _ in lastMoveTranslation = .zero }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = value.translation.width - lastResizeTranslation.width
                lastResizeTranslation = value.translation
                store.workspace.resizeWindow(window.id, normalizedDelta: delta / max(frame.width, 1))
            }
            .onEnded { _ in lastResizeTranslation = .zero }
    }
}

private struct DirectSpatialDock: View {
    let store: DirectModeStore

    var body: some View {
        HStack(spacing: 12) {
            ForEach(store.workspace.windows) { window in
                Button {
                    store.workspace.focus(window.id)
                } label: {
                    Image(systemName: window.systemImage)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(window.isMinimized ? .white.opacity(0.55) : .white)
                .help(window.title)
            }
            Divider().frame(height: 24).overlay(.white.opacity(0.3))
            Button { store.recenter() } label: { Image(systemName: "viewfinder") }
                .buttonStyle(.plain)
                .help("Recenter")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
    }
}
