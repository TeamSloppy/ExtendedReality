@preconcurrency import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct HandTrackingPreview: View {
    let controller: HandTrackingController
    @State private var orientation: HandCameraOrientation = .portrait

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CameraPreviewView(
                    session: controller.captureSession,
                    rotationAngle: rotationAngle
                )
                HandSkeletonOverlay(
                    snapshot: controller.snapshot,
                    sourceAspectRatio: sourceAspectRatio
                )
            }
            .clipped()
        }
        .background(.black)
        #if os(iOS)
        .onAppear { updateOrientation(UIDevice.current.orientation) }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation(UIDevice.current.orientation)
        }
        #else
        .onAppear {
            orientation = .landscapeRight
            controller.setOrientation(.landscapeRight)
        }
        #endif
    }

    private var sourceAspectRatio: CGFloat {
        switch orientation {
        case .portrait, .portraitUpsideDown: 9.0 / 16.0
        case .landscapeLeft, .landscapeRight: 16.0 / 9.0
        }
    }

    private var rotationAngle: CGFloat {
        #if os(iOS)
        HandCameraGeometry.previewRotationAngle(for: orientation)
        #else
        0
        #endif
    }

    #if os(iOS)
    private func updateOrientation(_ deviceOrientation: UIDeviceOrientation) {
        let value: HandCameraOrientation
        switch deviceOrientation {
        case .portraitUpsideDown: value = .portraitUpsideDown
        case .landscapeLeft: value = .landscapeLeft
        case .landscapeRight: value = .landscapeRight
        default: value = .portrait
        }
        orientation = value
        controller.setOrientation(value)
    }
    #endif
}

private struct HandSkeletonOverlay: View {
    let snapshot: HandTrackingSnapshot
    let sourceAspectRatio: CGFloat

    var body: some View {
        Canvas { context, size in
            let imageRect = aspectFillRect(aspectRatio: sourceAspectRatio, in: CGRect(origin: .zero, size: size))
            let interactionRect = CGRect(
                x: imageRect.minX + imageRect.width * 0.12,
                y: imageRect.minY + imageRect.height * 0.10,
                width: imageRect.width * 0.76,
                height: imageRect.height * 0.80
            )
            context.stroke(
                Path(roundedRect: interactionRect, cornerRadius: 10),
                with: .color(.white.opacity(0.32)),
                style: StrokeStyle(lineWidth: 1, dash: [5, 5])
            )

            for hand in snapshot.hands {
                let color: Color = hand.chirality == .left ? .cyan : .orange
                for (startName, endName) in HandSkeleton.segments {
                    guard let start = hand.joint(startName), let end = hand.joint(endName) else { continue }
                    var path = Path()
                    path.move(to: map(start.location, into: imageRect))
                    path.addLine(to: map(end.location, into: imageRect))
                    context.stroke(path, with: .color(color.opacity(0.84)), lineWidth: 2)
                }
                for (name, joint) in hand.joints where joint.confidence >= 0.3 {
                    let point = map(joint.location, into: imageRect)
                    let diameter: CGFloat = name == .indexTip || name == .thumbTip ? 9 : 6
                    let rect = CGRect(
                        x: point.x - diameter / 2,
                        y: point.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }

            let pinchCenters = snapshot.hands.compactMap { hand -> CGPoint? in
                guard snapshot.pinchingHandIDs.contains(hand.id),
                      let index = hand.joint(.indexTip),
                      let thumb = hand.joint(.thumbTip) else {
                    return nil
                }
                return map(
                    CGPoint(
                        x: (index.location.x + thumb.location.x) / 2,
                        y: (index.location.y + thumb.location.y) / 2
                    ),
                    into: imageRect
                )
            }
            if snapshot.isTwoHandGestureActive, pinchCenters.count >= 2 {
                var connection = Path()
                connection.move(to: pinchCenters[0])
                connection.addLine(to: pinchCenters[1])
                context.stroke(
                    connection,
                    with: .color(.green.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 5])
                )
                for center in pinchCenters.prefix(2) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                        with: .color(.green)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func map(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func aspectFillRect(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        let boundsRatio = bounds.width / max(bounds.height, 1)
        if boundsRatio > aspectRatio {
            let height = bounds.width / aspectRatio
            return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
        let width = bounds.height * aspectRatio
        return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
    }
}

#if os(iOS)
private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat

    func makeUIView(context: Context) -> CameraPreviewPlatformView {
        CameraPreviewPlatformView(session: session, rotationAngle: rotationAngle)
    }

    func updateUIView(_ view: CameraPreviewPlatformView, context: Context) {
        view.update(session: session, rotationAngle: rotationAngle)
    }
}

private final class CameraPreviewPlatformView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private var rotationAngle: CGFloat
    private var sessionStartObserver: NSObjectProtocol?

    init(session: AVCaptureSession, rotationAngle: CGFloat) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.rotationAngle = rotationAngle
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        observeSessionStart(session)
        applyConnectionConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let sessionStartObserver {
            NotificationCenter.default.removeObserver(sessionStartObserver)
        }
    }

    func update(session: AVCaptureSession, rotationAngle: CGFloat) {
        if previewLayer.session !== session {
            previewLayer.session = session
            observeSessionStart(session)
        }
        self.rotationAngle = rotationAngle
        applyConnectionConfiguration()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        applyConnectionConfiguration()
    }

    private func observeSessionStart(_ session: AVCaptureSession) {
        if let sessionStartObserver {
            NotificationCenter.default.removeObserver(sessionStartObserver)
        }
        sessionStartObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyConnectionConfiguration()
            }
        }
    }

    private func applyConnectionConfiguration() {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }
}
#elseif os(macOS)
private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat

    func makeNSView(context: Context) -> CameraPreviewPlatformView {
        CameraPreviewPlatformView(session: session)
    }

    func updateNSView(_ view: CameraPreviewPlatformView, context: Context) {
        view.previewLayer.session = session
        guard let connection = view.previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

private final class CameraPreviewPlatformView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
#endif
