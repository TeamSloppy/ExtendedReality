import CoreGraphics

enum WindowProjection {
    static func frame(
        for transform: WindowTransform3DoF,
        in viewport: CGRect,
        headPose: HeadPose = .identity
    ) -> CGRect {
        // Core Motion reports a rightward head turn as negative yaw. Adding
        // that value moves world-locked content left, opposite to the turn.
        let relativeYaw = transform.yaw + headPose.yaw
        let relativePitch = transform.pitch - headPose.pitch
        let distanceScale = CGFloat(1 / transform.virtualDistance)

        let width = viewport.width * CGFloat(transform.width) * distanceScale
        let height = viewport.height * CGFloat(transform.height) * distanceScale
        let unrotatedX = CGFloat(relativeYaw / 42) * viewport.width * 0.52
        let unrotatedY = -CGFloat(relativePitch / 24) * viewport.height * 0.44
        let roll = CGFloat(-headPose.roll * .pi / 180)
        let centerX = viewport.midX + unrotatedX * cos(roll) - unrotatedY * sin(roll)
        let centerY = viewport.midY + unrotatedX * sin(roll) + unrotatedY * cos(roll)

        return CGRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }
}
