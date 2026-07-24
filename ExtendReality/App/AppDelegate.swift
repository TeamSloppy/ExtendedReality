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
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ControllerViewController(environment: environment)
        window.makeKeyAndVisible()
        self.window = window
        for context in connectionOptions.urlContexts {
            environment.handleIncomingURL(context.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            AppEnvironment.shared.handleIncomingURL(context.url)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        let environment = AppEnvironment.shared
        environment.setForegroundActive(false)
        environment.hardwareMouseInput.setCaptureEnabled(false)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppEnvironment.shared.setForegroundActive(true)
    }
}

@MainActor
final class ControllerViewController: UIViewController {
    private let environment: AppEnvironment
    private var host: UIViewController?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersPointerLocked: Bool {
        environment.hardwareMouseInput.isCaptureEnabled
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        environment.hardwareMouseInput.isCaptureEnabled ? .all : []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let root = ControllerRootView(environment: environment)
            .environment(environment.workspace)
            .environment(environment.dashboard)
            .environment(environment.inputRouter)
            .environment(environment.headPose)
            .environment(environment.systemData)
            .environment(environment.youtubeAuth)
            .environment(environment.voiceAssistant)
            .environment(environment.voiceAssistantSettings)
            .environment(environment.wakeWordController)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        environment.hardwareMouseInput.capturePreferenceDidChange = { [weak self] in
            self?.setNeedsUpdateOfPrefersPointerLocked()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if environment.hardwareMouseInput.isCaptureEnabled,
           presses.contains(where: { $0.key?.charactersIgnoringModifiers == UIKeyCommand.inputEscape }) {
            environment.hardwareMouseInput.setCaptureEnabled(false)
            return
        }
        super.pressesBegan(presses, with: event)
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
        let environment = AppEnvironment.shared
        environment.externalDisplayCapture.attach(window: window)
        environment.workspace.isExternalDisplayConnected = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        let environment = AppEnvironment.shared
        if let window {
            environment.externalDisplayCapture.detach(window: window)
        }
        environment.workspace.isExternalDisplayConnected = false
    }
}
