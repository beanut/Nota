import InkKit
import SwiftUI
import UIKit

/// Presentation mode's scene wiring. When an external display or AirPlay screen connects, iPadOS asks for a
/// scene in the non-interactive external-display role; instead of mirroring the whole iPad screen, Nota shows
/// InkKit's `PresentationMirror` there: the page being worked on, without chrome, and the laser pointer.
/// Every other scene is the SwiftUI app's own.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, configurationForConnecting session: UISceneSession,
                     options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = PresentationSceneDelegate.self
        }
        return configuration
    }
}

/// The external display's window: InkKit's mirror of the presented page, themed like the editor.
final class PresentationSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: PresentationMirror().inkTheme(.nota))
        window.isHidden = false
        self.window = window
        InkPresentation.shared.isMirroring = true
    }

    func sceneDidDisconnect(_: UIScene) {
        window = nil
        InkPresentation.shared.isMirroring = false
    }
}
