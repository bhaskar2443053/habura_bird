import CaptureKit
import CoreVideo
import ImageIO
import Vision

/// On-device ring/tag reading with Apple Vision, for instant feedback in the field.
/// The server's OCR stays authoritative (design §6.2); this only proposes a code to confirm.
enum RingOCR {
    /// Candidate codes in a still. Rings are curved and often photographed sideways, so every
    /// orientation is tried; the registry decides which read is real.
    static func candidates(in jpeg: Data) -> [String] {
        guard let image = FrameConversion.cgImage(from: jpeg) else { return [] }
        let base = FrameConversion.orientation(of: jpeg)
        var seen: [String] = []
        for orientation in [base, .up, .right, .left, .down] {
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
            for code in recognize(with: handler, level: .accurate) where !seen.contains(code) {
                seen.append(code)
            }
        }
        return seen
    }

    /// Candidate codes in a live preview frame (portrait phone: buffer orientation `.right`).
    static func candidates(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) -> [String] {
        recognize(with: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation), level: .fast)
    }

    private static func recognize(with handler: VNImageRequestHandler, level: VNRequestTextRecognitionLevel) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        // Ring codes aren't words; language correction "fixes" them into wrong ones.
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.03
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        var codes: [String] = []
        for observation in observations {
            for candidate in observation.topCandidates(3) {
                codes.append(RingRegistry.normalize(candidate.string))
            }
        }
        // Codes split over two lines ("HB" / "1023") are also tried joined, top-to-bottom.
        let lines = observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first.map { RingRegistry.normalize($0.string) } }
        if lines.count > 1 { codes.append(lines.joined()) }
        var unique: [String] = []
        for code in codes where code.count >= 2 && !unique.contains(code) { unique.append(code) }
        return unique
    }
}

/// Throttles live OCR to about one frame a second and publishes the best registry match.
final class LiveRingReader: @unchecked Sendable {  // state guarded by `lock`
    private let lock = NSLock()
    private var lastRun = Date.distantPast
    private var busy = false
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "ring.ocr", qos: .utility)

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    /// Call from the camera's analysis queue with each frame.
    func feed(_ buffer: CVPixelBuffer, registry: RingRegistry, onMatch: @escaping (RingMatch?) -> Void) {
        let now = Date()
        lock.lock()
        guard !busy, now.timeIntervalSince(lastRun) >= interval else {
            lock.unlock()
            return
        }
        busy = true
        lastRun = now
        lock.unlock()
        queue.async {
            let match = registry.bestMatch(RingOCR.candidates(in: buffer))
            DispatchQueue.main.async { onMatch(match) }
            self.lock.lock()
            self.busy = false
            self.lock.unlock()
        }
    }
}
