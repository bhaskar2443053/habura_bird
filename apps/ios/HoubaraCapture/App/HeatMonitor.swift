import CaptureKit
import Foundation

/// Follows the phone's thermal state so the camera, OCR and uploads can back off before iOS dims
/// the screen or shuts the camera off (phones overheat quickly in direct sun).
@MainActor
final class HeatMonitor: ObservableObject {
    @Published private(set) var heat: CameraLoad.Heat = HeatMonitor.current
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.heat = HeatMonitor.current }
        }
    }

    var load: CameraLoad { CameraLoad.forHeat(heat) }

    nonisolated static var current: CameraLoad.Heat {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
