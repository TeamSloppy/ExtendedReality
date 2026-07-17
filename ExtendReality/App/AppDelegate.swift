import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration: UISceneConfiguration
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        } else {
            configuration = UISceneConfiguration(name: "Phone", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = PhoneSceneDelegate.self
        }
        return configuration
    }
}

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let environment = AppEnvironment.shared
        let root = ControllerRootView(environment: environment)
            .environment(environment.workspace)
            .environment(environment.dashboard)
            .environment(environment.inputRouter)
            .environment(environment.headPose)
            .environment(environment.systemData)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = SpatialCanvasViewController(environment: .shared)
        window.makeKeyAndVisible()
        self.window = window
        AppEnvironment.shared.workspace.isExternalDisplayConnected = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        AppEnvironment.shared.workspace.isExternalDisplayConnected = false
    }
}
