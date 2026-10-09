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

    /// One fast pass over a still, used to notice a ring in photos taken while photographing
    /// freely. Cheap enough to run on every shot.
    static func quickCandidates(in jpeg: Data) -> [String] {
        guard let image = FrameConversion.cgImage(from: jpeg) else { return [] }
        let handler = VNImageRequestHandler(cgImage: image, orientation: FrameConversion.orientation(of: jpeg))
        return recognize(with: handler, level: .fast)
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
        // Biggest text first: in a ring photo the ring code is the largest lettering, while cage
        // cards, sleeves and reader labels carry smaller text (a cage card was once read as the
        // ring). The registry match keeps this order for equally good reads.
        let observations = (request.results ?? [])
            .sorted { $0.boundingBox.height > $1.boundingBox.height }
        var codes: [String] = []
        for observation in observations {
            for candidate in observation.topCandidates(3) where !looksLikeLabel(candidate.string) {
                codes.append(RingRegistry.normalize(candidate.string))
            }
        }
        // A code split over two lines ("HB" / "1023") is also tried joined, top-to-bottom, but only
        // for two short lines of similar size; joining a card's lines makes up codes.
        if observations.count >= 2 {
            let pair = observations.prefix(2).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            let heights = pair.map(\.boundingBox.height)
            let parts = pair.compactMap { $0.topCandidates(1).first.map { RingRegistry.normalize($0.string) } }
            let joined = parts.joined()
            if parts.count == 2, heights.min()! > heights.max()! * 0.6, (3...10).contains(joined.count) {
                codes.append(joined)
            }
        }
        codes = codes.filter { (2...10).contains($0.count) }
        var unique: [String] = []
        for code in codes where !unique.contains(code) { unique.append(code) }
        return unique
    }

    /// Text that is clearly not a ring code: several words, or a long run of letters
    /// ("PEN 4 FEMALE", "NPRT ONLY").
    private static func looksLikeLabel(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "/" })
        if words.count > 2 { return true }
        let letters = text.filter(\.isLetter).count
        return letters > 6 || text.count > 14
    }
}

/// Throttles live OCR to about one frame a second and publishes the best registry match.
final class LiveRingReader: @unchecked Sendable {  // state guarded by `lock`
    private let lock = NSLock()
    private var lastRun = Date.distantPast
    private var busy = false
    private var interval: TimeInterval
    private let queue = DispatchQueue(label: "ring.ocr", qos: .utility)

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    /// Reads less often when the phone is hot.
    func setInterval(_ seconds: TimeInterval) {
        lock.lock()
        interval = seconds
        lock.unlock()
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
