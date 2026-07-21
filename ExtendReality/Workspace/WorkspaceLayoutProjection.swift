import Foundation

struct WorkspaceWindowPresentation: Equatable {
    var window: WorkspaceWindow
    var projectionHeadPose: HeadPose
    var rotationDegrees: Double
    var stackIndex: Int?
    var stackCount: Int?
}

enum WorkspaceLayoutProjection {
    static let horizontalGapDegrees = 4.0

    static func presentations(
        windows: [WorkspaceWindow],
        layouts: [UUID: SpatialAppLayout],
        layoutMode: WorkspaceLayoutMode,
        stackOrder: [UUID],
        stackTransform: WorkspaceStackTransform,
        headPose: HeadPose,
        smoothFollowHeadPoses: [UUID: HeadPose] = [:]
    ) -> [UUID: WorkspaceWindowPresentation] {
        switch layoutMode {
        case .freeSpace:
            return Dictionary(
                uniqueKeysWithValues: windows.map { window in
                    let projectionHeadPose: HeadPose
                    switch window.attachmentMode {
                    case .anchor:
                        projectionHeadPose = headPose
                    case .smoothFollow:
                        projectionHeadPose = smoothFollowHeadPoses[window.id] ?? .identity
                    case .follow:
                        projectionHeadPose = .identity
                    }
                    return (
                        window.id,
                        WorkspaceWindowPresentation(
                            window: window,
                            projectionHeadPose: projectionHeadPose,
                            rotationDegrees: -projectionHeadPose.roll,
                            stackIndex: nil,
                            stackCount: nil
                        )
                    )
                }
            )

        case .stack:
            return stackPresentations(
                windows: windows,
                layouts: layouts,
                stackOrder: stackOrder,
                stackTransform: stackTransform,
                headPose: headPose
            )
        }
    }

    private static func stackPresentations(
        windows: [WorkspaceWindow],
        layouts: [UUID: SpatialAppLayout],
        stackOrder: [UUID],
        stackTransform: WorkspaceStackTransform,
        headPose: HeadPose
    ) -> [UUID: WorkspaceWindowPresentation] {
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let orderedIDs = normalizedOrder(stackOrder, windows: windows)
        let orderedWindows = orderedIDs.compactMap { windowsByID[$0] }
        let bounds = orderedWindows.map { window in
            horizontalBounds(
                for: window,
                layout: layouts[window.id] ?? .defaultLayout(for: window),
                rootDistance: stackTransform.virtualDistance
            )
        }
        let totalWidth = bounds.reduce(0) { $0 + $1.width }
            + horizontalGapDegrees * Double(max(orderedWindows.count - 1, 0))
        var cursor = stackTransform.centerYaw - totalWidth / 2
        var result: [UUID: WorkspaceWindowPresentation] = [:]

        for (index, window) in orderedWindows.enumerated() {
            let interval = bounds[index]
            var presentedWindow = window
            presentedWindow.appTransform.yaw = cursor - interval.lowerBound
            presentedWindow.appTransform.pitch = stackTransform.pitch
            presentedWindow.appTransform.virtualDistance = stackTransform.virtualDistance
            presentedWindow.appTransform.clampPreservingUnboundedYaw()
            result[window.id] = WorkspaceWindowPresentation(
                window: presentedWindow,
                projectionHeadPose: headPose,
                rotationDegrees: -headPose.roll,
                stackIndex: index,
                stackCount: orderedWindows.count
            )
            cursor += interval.width + horizontalGapDegrees
        }

        return result
    }

    static func normalizedOrder(_ order: [UUID], windows: [WorkspaceWindow]) -> [UUID] {
        let windowIDs = Set(windows.map(\.id))
        var seen: Set<UUID> = []
        let restored = order.filter { windowIDs.contains($0) && seen.insert($0).inserted }
        return restored + windows.map(\.id).filter { seen.insert($0).inserted }
    }

    static func horizontalBounds(
        for window: WorkspaceWindow,
        layout: SpatialAppLayout,
        rootDistance: Double
    ) -> (lowerBound: Double, upperBound: Double, width: Double) {
        let scale = window.appTransform.scale
        var lowerBound = Double.infinity
        var upperBound = -Double.infinity

        for panel in layout.panels {
            let placement = panel.placement
            let distance = (rootDistance + placement.depth * scale).clamped(
                to: WindowTransform3DoF.virtualDistanceRange
            )
            let center = placement.yaw * scale
            let halfWidth = placement.width * scale / distance * 42 / (2 * 0.52)
            lowerBound = min(lowerBound, center - halfWidth)
            upperBound = max(upperBound, center + halfWidth)
        }

        if !lowerBound.isFinite || !upperBound.isFinite {
            return (-1, 1, 2)
        }
        return (lowerBound, upperBound, upperBound - lowerBound)
    }
}

private extension SpatialAppTransform3DoF {
    mutating func clampPreservingUnboundedYaw() {
        let originalYaw = yaw
        clamp()
        yaw = originalYaw.isFinite ? originalYaw : 0
    }
}
