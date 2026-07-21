import CoreGraphics

enum WindowProjection {
    static func frame(
        for transform: WindowTransform3DoF,
        in viewport: CGRect,
        headPose: HeadPose = .identity
    ) -> CGRect {
        let distanceScale = CGFloat(1 / transform.virtualDistance)

        let width = viewport.width * CGFloat(transform.width) * distanceScale
        let height = viewport.height * CGFloat(transform.height) * distanceScale
        let center = worldPoint(
            yaw: transform.yaw,
            pitch: transform.pitch,
            in: viewport,
            headPose: headPose
        )

        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    static func worldPoint(
        yaw: Double,
        pitch: Double,
        in viewport: CGRect,
        headPose: HeadPose = .identity
    ) -> CGPoint {
        // Core Motion reports a rightward head turn as negative yaw. Adding
        // that value moves world-locked content left, opposite to the turn.
        let relativeYaw = yaw + headPose.yaw
        let relativePitch = pitch - headPose.pitch
        let unrotatedX = CGFloat(relativeYaw / 42) * viewport.width * 0.52
        let unrotatedY = -CGFloat(relativePitch / 24) * viewport.height * 0.44
        // Keep head yaw and pitch aligned with the display axes. Rotating this
        // vector by roll makes a pure left/right head turn drift vertically.
        // Roll is applied to the visual chrome separately by SpatialCanvasView.
        return CGPoint(
            x: viewport.midX + unrotatedX,
            y: viewport.midY + unrotatedY
        )
    }

    static func framePreservingContentAspect(
        _ frame: CGRect,
        contentAspectRatio: Double?,
        verticalChrome: CGFloat
    ) -> CGRect {
        guard let contentAspectRatio,
              contentAspectRatio.isFinite,
              contentAspectRatio > 0 else { return frame }

        let aspectRatio = CGFloat(contentAspectRatio)
        let width = max(frame.width, 1)
        let height = width / aspectRatio + verticalChrome

        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func curvatureAmount(for transform: WindowTransform3DoF) -> CGFloat {
        guard transform.width.isFinite, transform.virtualDistance.isFinite else { return 0 }
        let distanceProgress = CGFloat(
            (transform.virtualDistance - 1.05)
                / (WindowTransform3DoF.virtualDistanceRange.upperBound - 1.05)
        ).clamped(to: 0 ... 1)
        let widthProgress = CGFloat((transform.width - 0.85) / 0.95)
            .clamped(to: 0 ... 1)
        return min(distanceProgress, widthProgress)
    }
}

struct ProjectedSpatialPanel: Identifiable, Equatable {
    let descriptor: SpatialPanelDescriptor
    let transform: WindowTransform3DoF
    let frame: CGRect

    var id: SpatialPanelID { descriptor.id }
}

enum SpatialWindowCompositor {
    static func project(
        window: WorkspaceWindow,
        layout: SpatialAppLayout,
        in viewport: CGRect,
        headPose: HeadPose = .identity
    ) -> [ProjectedSpatialPanel] {
        layout.panels.map { panel in
            let placement = panel.placement
            let scale = window.appTransform.scale
            var transform = WindowTransform3DoF(
                yaw: window.appTransform.yaw + placement.yaw * scale,
                pitch: window.appTransform.pitch + placement.pitch * scale,
                virtualDistance: window.appTransform.virtualDistance + placement.depth * scale,
                width: placement.width * scale,
                height: placement.height * scale
            )
            transform.virtualDistance = transform.virtualDistance.clamped(
                to: WindowTransform3DoF.virtualDistanceRange
            )
            let frame = WindowProjection.frame(
                for: transform,
                in: viewport,
                headPose: headPose
            )
            return ProjectedSpatialPanel(
                descriptor: panel,
                transform: transform,
                frame: frame
            )
        }
    }

    static func boundingFrame(for panels: [ProjectedSpatialPanel]) -> CGRect {
        panels.map(\.frame).reduce(.null) { $0.union($1) }
    }
}

enum VoiceAssistantPlacement {
    struct Anchor: Equatable, Sendable {
        var yaw: Double
        var pitch: Double
    }

    /// The assistant sits in the lower part of the forward view so it remains
    /// comfortable to glance at without requiring a pronounced downward tilt.
    static let downwardPitchOffset = -14.0

    static func anchor(below headPose: HeadPose) -> Anchor {
        Anchor(
            yaw: -headPose.yaw,
            pitch: headPose.pitch + downwardPitchOffset
        )
    }

    static func position(
        for anchor: Anchor,
        in viewport: CGRect,
        headPose: HeadPose,
        isTracking: Bool
    ) -> CGPoint? {
        guard isTracking else { return nil }
        return WindowProjection.worldPoint(
            yaw: anchor.yaw,
            pitch: anchor.pitch,
            in: viewport,
            headPose: headPose
        )
    }
}

enum SpatialDockPlacement {
    static let worldYaw = 0.0
    static let worldPitch = -28.0

    static func position(
        in viewport: CGRect,
        headPose: HeadPose,
        isTracking: Bool
    ) -> CGPoint? {
        guard isTracking else { return nil }
        return WindowProjection.worldPoint(
            yaw: worldYaw,
            pitch: worldPitch,
            in: viewport,
            headPose: headPose
        )
    }
}
