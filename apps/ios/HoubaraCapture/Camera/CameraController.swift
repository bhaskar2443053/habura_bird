import AVFoundation
import CaptureKit
import ImageIO
import UIKit

struct CameraOption: Identifiable, Hashable {
    let id: String
    let name: String
    /// A USB-C (UVC) camera, e.g. the recommended 850 nm NIR camera on an iPad (iPadOS 17+).
    let isExternal: Bool
}

struct CapturedPhoto: Sendable {
    let data: Data
    let exposure: ExposureInfo
    let cameraName: String
}

enum CameraError: LocalizedError {
    case notReady
    case noData

    var errorDescription: String? {
        switch self {
        case .notReady: return "The camera isn't ready yet"
        case .noData: return "The camera returned no image"
        }
    }
}

/// Wraps AVFoundation: one capture session with a photo output for stills and a video data output
/// that feeds the live quality gate, auto-capture and live ring OCR.
final class CameraController: NSObject, ObservableObject, @unchecked Sendable {
    // Thread safety: AVFoundation state is only touched on sessionQueue, analysis state on
    // analysisQueue, and @Published properties on the main queue.
    let session = AVCaptureSession()

    @Published private(set) var options: [CameraOption] = []
    @Published private(set) var current: CameraOption?
    @Published private(set) var liveQuality: QualityReport?
    @Published private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var errorMessage: String?

    /// Called on the main queue when the live gate has passed long enough to take a shot.
    var onAutoCapture: (() -> Void)?

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let analysisQueue = DispatchQueue(label: "camera.analysis", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var inFlight: [Int64: PhotoCaptureDelegate] = [:]  // sessionQueue

    // analysisQueue state
    private var thresholds = QualityThresholds()
    private var trigger = AutoCaptureTrigger()
    private var autoCaptureEnabled = false
    private var frameIndex = 0
    private var frameObserver: ((CVPixelBuffer) -> Void)?
    private var snapshotWaiters: [CheckedContinuation<Data?, Never>] = []

    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        // Virtual multi-camera devices first: they switch to the ultra-wide lens for macro
        // close-ups (eye, ring, feet) automatically on Pro models.
        [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
         .builtInUltraWideCamera, .builtInTelephotoCamera, .external]
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(self, selector: #selector(devicesChanged), name: name, object: nil)
        }
        center.addObserver(
            self, selector: #selector(subjectAreaChanged), name: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil
        )
    }

    // MARK: Lifecycle

    func start() async {
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            status = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        }
        let granted = status
        await MainActor.run { authorization = granted }
        guard granted == .authorized else { return }
        sessionQueue.async {
            let devices = self.discover()
            if self.input == nil, let first = devices.first(where: { $0.position == .back }) ?? devices.first {
                self.configure(first)
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func select(_ option: CameraOption) {
        sessionQueue.async {
            guard let device = AVCaptureDevice(uniqueID: option.id) else { return }
            self.configure(device)
        }
    }

    // MARK: Settings from the capture screen

    func setThresholds(_ value: QualityThresholds) {
        analysisQueue.async {
            self.thresholds = value
            self.trigger.reset()
        }
        DispatchQueue.main.async { self.liveQuality = nil }
    }

    func setAutoCapture(_ enabled: Bool) {
        analysisQueue.async {
            self.autoCaptureEnabled = enabled
            self.trigger.reset()
        }
    }

    /// Receives every preview frame on the analysis queue; the observer throttles itself.
    func setFrameObserver(_ observer: ((CVPixelBuffer) -> Void)?) {
        analysisQueue.async { self.frameObserver = observer }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: Capture

    /// Takes a full-resolution still. External UVC cameras that can't produce photos fall back to
    /// the current preview frame.
    func capture() async throws -> CapturedPhoto {
        do {
            return try await capturePhoto()
        } catch {
            guard current?.isExternal == true, let data = await snapshot() else { throw error }
            return CapturedPhoto(data: data, exposure: ExposureInfo(), cameraName: current?.name ?? "external")
        }
    }

    private func capturePhoto() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CapturedPhoto, Error>) in
            sessionQueue.async {
                guard self.session.isRunning, let device = self.input?.device,
                      self.photoOutput.connection(with: .video) != nil
                else {
                    cont.resume(throwing: CameraError.notReady)
                    return
                }
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                // Flash stays at its default (off): no visible flash at the eye (welfare rule).
                settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                let id = settings.uniqueID
                let delegate = PhotoCaptureDelegate(
                    cameraName: device.localizedName, lensPosition: Double(device.lensPosition)
                ) { result in
                    self.sessionQueue.async { self.inFlight[id] = nil }
                    cont.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// JPEG of the next preview frame.
    private func snapshot() async -> Data? {
        await withCheckedContinuation { cont in
            analysisQueue.async { self.snapshotWaiters.append(cont) }
        }
    }

    // MARK: Configuration (sessionQueue)

    @discardableResult
    private func discover() -> [AVCaptureDevice] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: CameraController.deviceTypes, mediaType: .video, position: .unspecified
        ).devices.filter { $0.position != .front }
        let options = devices.map {
            CameraOption(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
        }
        DispatchQueue.main.async { self.options = options }
        return devices
    }

    private func configure(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input { session.removeInput(input) }
        input = nil
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else { return report("Can't use \(device.localizedName)") }
            session.addInput(newInput)
            input = newInput
        } catch {
            return report(error.localizedDescription)
        }

        session.sessionPreset = session.canSetSessionPreset(.photo) ? .photo : .high

        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
            session.addOutput(videoOutput)
        }
        // Full-range luma is what the quality gate reads; fall back to video range.
        let formats = videoOutput.availableVideoPixelFormatTypes
        if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            .first(where: { formats.contains($0) }) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        // The UI is portrait-only; external cameras keep their own orientation.
        if device.deviceType != .external, let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        } catch {}

        let option = CameraOption(id: device.uniqueID, name: device.localizedName, isExternal: device.deviceType == .external)
        DispatchQueue.main.async {
            self.current = option
            self.errorMessage = nil
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    @objc private func devicesChanged(_ note: Notification) {
        sessionQueue.async {
            let devices = self.discover()
            // The active camera was unplugged: fall back to the built-in one.
            if let input = self.input, !devices.contains(input.device) || !input.device.isConnected,
               let fallback = devices.first(where: { $0.position == .back }) {
                self.configure(fallback)
            } else if let plugged = note.object as? AVCaptureDevice, plugged.deviceType == .external,
                      note.name == AVCaptureDevice.wasConnectedNotification {
                // A newly connected NIR camera is almost certainly the one the operator wants.
                self.configure(plugged)
            }
        }
    }

    @objc private func subjectAreaChanged(_ note: Notification) {
        sessionQueue.async {
            guard let device = self.input?.device, device.focusMode == .autoFocus else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            } catch {}
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !snapshotWaiters.isEmpty {
            let jpeg = FrameConversion.jpeg(from: buffer)
            snapshotWaiters.forEach { $0.resume(returning: jpeg) }
            snapshotWaiters.removeAll()
        }
        frameObserver?(buffer)

        frameIndex += 1
        guard frameIndex % 3 == 0, let gray = FrameConversion.centerLuma(of: buffer, side: 512) else { return }
        // Resolution is only checked on the still; the preview is always smaller.
        let report = Quality.assess(gray, shortSidePx: .max, thresholds: thresholds)
        let fire = autoCaptureEnabled && trigger.feed(passed: report.passed)
        DispatchQueue.main.async {
            self.liveQuality = report
            if fire { self.onAutoCapture?() }
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let cameraName: String
    private let lensPosition: Double
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var result: Result<CapturedPhoto, Error>?

    init(cameraName: String, lensPosition: Double, completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.cameraName = cameraName
        self.lensPosition = lensPosition
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            result = .failure(error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            result = .failure(CameraError.noData)
            return
        }
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let exposure = ExposureInfo(
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
            shutterS: (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
            aperture: (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,
            lensPosition: lensPosition
        )
        result = .success(CapturedPhoto(data: data, exposure: exposure, cameraName: cameraName))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error, result == nil { result = .failure(error) }
        completion(result ?? .failure(CameraError.noData))
    }
}
