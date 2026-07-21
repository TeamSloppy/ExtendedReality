import SwiftUI

struct GlassesViewport: View {
    let model: StudioAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moveOrigin: StudioWindowTransform?
    @State private var scaleOrigin: StudioWindowTransform?

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = fittedViewport(in: proxy.size)
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                ZStack {
                    spatialBackground
                    spatialContent(in: viewportSize)
                }
                .frame(width: viewportSize.width, height: viewportSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.38), radius: 28, y: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func spatialContent(in size: CGSize) -> some View {
        let viewport = CGRect(origin: .zero, size: size)
        let panels = StudioProjection.project(
            layout: model.layout,
            transform: model.windowTransform,
            camera: model.cameraTransform,
            in: viewport
        )
        let bounds = StudioProjection.boundingFrame(for: panels)

        return ZStack {
            ForEach(panels.sorted(by: panelSort)) { panel in
                if let session = model.session(for: panel.id) {
                    StudioWebView(session: session)
                        .frame(width: max(panel.frame.width, 1), height: max(panel.frame.height, 1))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(
                                    model.activePanelID == panel.id
                                        ? Color.orange.opacity(0.9)
                                        : Color.white.opacity(0.16),
                                    lineWidth: model.activePanelID == panel.id ? 2 : 1
                                )
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            panelBadge(panel)
                                .offset(x: 12, y: 12)
                        }
                        .shadow(color: .black.opacity(0.72), radius: 24, y: 12)
                        .position(x: panel.frame.midX, y: panel.frame.midY)
                        .zIndex(Double(panel.descriptor.placement.layer))
                        .accessibilityLabel(panel.descriptor.accessibilityLabel)
                }
            }

            if !bounds.isNull {
                windowControls(bounds: bounds, viewportSize: size)
                    .zIndex(1_000)
            }

            viewportStatus
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
                .zIndex(2_000)

            cameraControls
                .position(x: 58, y: size.height - 58)
                .zIndex(2_000)

            Text("Drag the lower handle to move · drag the side handle to scale · ⌘0 to recenter")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .allowsHitTesting(false)
                .zIndex(2_000)
        }
        .frame(width: size.width, height: size.height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.windowTransform)
        .clipped()
    }

    private func panelBadge(_ panel: StudioProjectedPanel) -> some View {
        Button {
            model.focus(panel.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.activePanelID == panel.id ? Color.orange : Color.white.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(panel.descriptor.accessibilityLabel)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.58), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Focus \(panel.descriptor.accessibilityLabel)")
    }

    private func windowControls(bounds: CGRect, viewportSize: CGSize) -> some View {
        Group {
            HStack(spacing: 8) {
                controlButton("Move", systemImage: "move.3d") {}
                    .accessibilityHint("Drag to move the spatial window")
                controlButton("Nearer", systemImage: "plus.magnifyingglass") {
                    model.adjustDistance(by: -0.08)
                }
                controlButton("Farther", systemImage: "minus.magnifyingglass") {
                    model.adjustDistance(by: 0.08)
                }
                controlButton("Recenter", systemImage: "scope") {
                    model.resetTransform()
                }
                controlButton("Reset panels", systemImage: "rectangle.3.group") {
                    model.resetSpatialLayout()
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .position(
                x: bounds.midX.clamped(to: 170 ... max(viewportSize.width - 170, 170)),
                y: max(bounds.minY - 34, 64)
            )
            .gesture(moveGesture(viewportSize: viewportSize))

            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.orange.opacity(0.85), lineWidth: 1.5)
                }
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                .frame(width: 20, height: 96)
                .position(
                    x: min(bounds.maxX + 20, viewportSize.width - 14),
                    y: bounds.midY.clamped(to: 80 ... max(viewportSize.height - 80, 80))
                )
                .gesture(scaleGesture)
                .help("Drag to scale the spatial window")

            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.purple.opacity(0.86), lineWidth: 1.5)
                }
                .overlay {
                    Image(systemName: "move.3d")
                        .font(.caption2.bold())
                        .foregroundStyle(.purple)
                }
                .frame(width: 112, height: 20)
                .position(
                    x: bounds.midX.clamped(to: 72 ... max(viewportSize.width - 72, 72)),
                    y: min(bounds.maxY + 20, viewportSize.height - 44)
                )
                .gesture(moveGesture(viewportSize: viewportSize))
                .help("Drag to move the spatial window")
        }
    }

    private func controlButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.86))
        .help(title)
        .accessibilityLabel(title)
    }

    private var cameraControls: some View {
        VStack(spacing: 3) {
            cameraControlButton("Look up", systemImage: "arrow.up") {
                model.rotateCamera(pitch: 5)
            }

            HStack(spacing: 3) {
                cameraControlButton("Look left", systemImage: "arrow.left") {
                    model.rotateCamera(yaw: -5)
                }
                cameraControlButton("Recenter camera", systemImage: "viewfinder") {
                    model.resetCamera()
                }
                cameraControlButton("Look right", systemImage: "arrow.right") {
                    model.rotateCamera(yaw: 5)
                }
            }

            cameraControlButton("Look down", systemImage: "arrow.down") {
                model.rotateCamera(pitch: -5)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Virtual camera controls")
    }

    private func cameraControlButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.cyan.opacity(0.95))
        .help(title)
        .accessibilityLabel(title)
    }

    private var viewportStatus: some View {
        HStack(spacing: 10) {
            Label(model.selectedPreset.title, systemImage: "visionpro")
                .fontWeight(.semibold)
            Spacer()
            if model.primarySession.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading")
            }
            Circle()
                .fill(model.primarySession.errorMessage == nil ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(model.primarySession.errorMessage == nil ? "HOST API v3" : "SERVER OFFLINE")
                .font(.caption.monospaced().weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var spatialBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.035, blue: 0.07),
                    Color(red: 0.005, green: 0.008, blue: 0.018),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Canvas { context, size in
                let spacing: CGFloat = 48
                var path = Path()
                stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
        }
    }

    private func moveGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if moveOrigin == nil { moveOrigin = model.windowTransform }
                guard let moveOrigin else { return }
                model.moveWindow(
                    from: moveOrigin,
                    translation: value.translation,
                    viewport: viewportSize
                )
            }
            .onEnded { _ in moveOrigin = nil }
    }

    private var scaleGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if scaleOrigin == nil { scaleOrigin = model.windowTransform }
                guard let scaleOrigin else { return }
                model.scaleWindow(from: scaleOrigin, translation: value.translation)
            }
            .onEnded { _ in scaleOrigin = nil }
    }

    private func panelSort(_ lhs: StudioProjectedPanel, _ rhs: StudioProjectedPanel) -> Bool {
        if lhs.descriptor.placement.layer != rhs.descriptor.placement.layer {
            return lhs.descriptor.placement.layer < rhs.descriptor.placement.layer
        }
        return lhs.descriptor.placement.depth > rhs.descriptor.placement.depth
    }

    private func fittedViewport(in available: CGSize) -> CGSize {
        let padding: CGFloat = 44
        let width = max(available.width - padding * 2, 320)
        let height = max(available.height - padding * 2, 180)
        let aspect = 16.0 / 9.0
        if width / height > aspect {
            return CGSize(width: height * aspect, height: height)
        }
        return CGSize(width: width, height: width / aspect)
    }
}
