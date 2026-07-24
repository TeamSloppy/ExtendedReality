#if os(iOS)
import SwiftUI
import UIKit

struct IOSHandControlView: View {
    let controller: HandTrackingController
    let isExternalDisplayConnected: Bool

    var body: some View {
        @Bindable var controller = controller

        ZStack {
            HandTrackingPreview(controller: controller)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.isRunning ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(controller.snapshot.hands.count) hands")
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                HStack(spacing: 10) {
                    Picker("Pointing hand", selection: $controller.preferredHand) {
                        ForEach(PreferredHand.allCases) { hand in
                            Text(hand.title).tag(hand)
                        }
                    }
                    .pickerStyle(.menu)

                    if controller.state == .denied {
                        Button("Settings", systemImage: "gear") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    } else if !controller.isRunning {
                        Button("Start", systemImage: "camera.fill") {
                            Task { await controller.start() }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hand tracking control")
        .accessibilityIdentifier("handTracking.preview")
    }

    private var statusText: String {
        if controller.snapshot.isTwoHandGestureActive {
            return "Two-hand zoom"
        }
        if !isExternalDisplayConnected, controller.isRunning {
            return "Tracking · connect glasses for pointer"
        }
        return controller.state.title
    }
}
#endif
