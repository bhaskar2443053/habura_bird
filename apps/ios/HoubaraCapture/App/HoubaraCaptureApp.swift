import SwiftUI
import UIKit

/// Holds the system's completion handler while a background upload session finishes its events.
final class BackgroundEvents {
    static let shared = BackgroundEvents()
    var completionHandler: (() -> Void)?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Created here rather than lazily by a view so that a background relaunch for finished
        // uploads reconnects to the background URLSession even when no UI is built.
        _ = AppModel.shared
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundEvents.shared.completionHandler = completionHandler
    }
}

@main
struct HoubaraCaptureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.store)
                .environmentObject(model.uploader)
                .environmentObject(model.heat)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.uploader.kick() }
        }
    }
}
