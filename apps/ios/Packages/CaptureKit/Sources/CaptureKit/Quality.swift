import Foundation

/// 8-bit luminance image. The app fills it from the camera's luma plane or a decoded still.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Mirrors `birdreid.capture.quality.QualityReport`.
public struct QualityReport: Codable, Hashable, Sendable {
    public var sharpness: Double
    public var glareRatio: Double
    public var brightness: Double
    public var shortSidePx: Int
    public var failures: [String]

    enum CodingKeys: String, CodingKey {
        case sharpness, brightness, failures
        case glareRatio = "glare_ratio"
        case shortSidePx = "short_side_px"
    }

    public init(sharpness: Double, glareRatio: Double, brightness: Double, shortSidePx: Int, failures: [String]) {
        self.sharpness = sharpness
        self.glareRatio = glareRatio
        self.brightness = brightness
        self.shortSidePx = shortSidePx
        self.failures = failures
    }

    public var passed: Bool { failures.isEmpty }

    /// Ranking score among passing shots of the same view.
    public var score: Double { sharpness * (1 - glareRatio) }
}

/// The capture gate, ported from `birdreid.capture.quality` so the phone and server agree.
///
/// On the phone it runs on a full-resolution centre crop (the guide area) rather than the whole
/// frame, which keeps it fast enough for live preview; the server re-assesses the full image.
public enum Quality {
    /// Variance of the 4-neighbour Laplacian; higher means sharper.
    public static func sharpness(_ image: GrayImage) -> Double {
        let w = image.width, h = image.height
        guard w >= 3, h >= 3 else { return 0 }
        var sum = 0.0, sumSq = 0.0
        image.pixels.withUnsafeBufferPointer { p in
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let i = row + x
                    let lap = Int(p[i - w]) + Int(p[i + w]) + Int(p[i - 1]) + Int(p[i + 1]) - 4 * Int(p[i])
                    let v = Double(lap)
                    sum += v
                    sumSq += v * v
                }
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    /// Fraction of saturated pixels (specular highlights, e.g. on the eye).
    public static func glareRatio(_ image: GrayImage, level: UInt8 = 250) -> Double {
        guard !image.pixels.isEmpty else { return 0 }
        let saturated = image.pixels.reduce(0) { $0 + ($1 >= level ? 1 : 0) }
        return Double(saturated) / Double(image.pixels.count)
    }

    public static func brightness(_ image: GrayImage) -> Double {
        guard !image.pixels.isEmpty else { return 0 }
        let total = image.pixels.reduce(0) { $0 + Int($1) }
        return Double(total) / Double(image.pixels.count)
    }

    /// - Parameter shortSidePx: short side of the full photo, which may be larger than `image`
    ///   when `image` is a crop.
    public static func assess(
        _ image: GrayImage, shortSidePx: Int? = nil, thresholds: QualityThresholds
    ) -> QualityReport {
        var report = QualityReport(
            sharpness: sharpness(image),
            glareRatio: glareRatio(image),
            brightness: brightness(image),
            shortSidePx: shortSidePx ?? min(image.width, image.height),
            failures: []
        )
        if report.sharpness < thresholds.minSharpness { report.failures.append("blurry") }
        if report.glareRatio > thresholds.maxGlareRatio { report.failures.append("glare") }
        if report.brightness < thresholds.minBrightness { report.failures.append("too_dark") }
        if report.brightness > thresholds.maxBrightness { report.failures.append("too_bright") }
        if report.shortSidePx < thresholds.minShortSidePx { report.failures.append("too_small") }
        return report
    }

    /// Smallest pupil, as a fraction of the photo's short side, for an eye close-up. An eye that
    /// fills the guide circle has a pupil of roughly 0.2–0.3; a whole-head shot about 0.03.
    public static let minPupilFraction = 0.08

    /// Adds `eye_too_small` when no pupil-sized dark disc is found. `frame` is the whole photo or
    /// preview downscaled (about 160 px on the short side is plenty), not the centre crop.
    public static func checkEyeSize(_ frame: GrayImage, report: inout QualityReport) {
        if pupilFraction(frame) < minPupilFraction { report.failures.append("eye_too_small") }
    }

    /// Diameter of the largest round dark blob in the middle of the frame (the pupil), relative to
    /// the short side; 0 when there is none. Dark areas touching the frame edge (background,
    /// hands, shadows) and elongated shapes are ignored.
    public static func pupilFraction(_ image: GrayImage) -> Double {
        let w = image.width, h = image.height
        guard w >= 8, h >= 8 else { return 0 }
        // Darkest few percent plus a margin: the pupil is the darkest thing in an eye close-up.
        var histogram = [Int](repeating: 0, count: 256)
        for p in image.pixels { histogram[Int(p)] += 1 }
        let target = image.pixels.count * 3 / 100
        var seen = 0, low = 0
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen >= target { low = value; break }
        }
        let threshold = UInt8(min(90, low + 25))

        var label = [Int32](repeating: 0, count: w * h)
        var best = 0.0
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where label[start] == 0 && image.pixels[start] < threshold {
            next += 1
            label[start] = next
            stack.append(start)
            var count = 0
            var minX = w, maxX = 0, minY = h, maxY = 0
            var touchesEdge = false
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }
                for n in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1]
                where n >= 0 && label[n] == 0 && image.pixels[n] < threshold {
                    label[n] = next
                    stack.append(n)
                }
            }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            let aspect = Double(max(bw, bh)) / Double(min(bw, bh))
            let fill = Double(count) / Double(bw * bh)
            let cx = Double(minX + maxX) / 2 / Double(w), cy = Double(minY + maxY) / 2 / Double(h)
            let central = (0.2...0.8).contains(cx) && (0.2...0.8).contains(cy)
            guard !touchesEdge, central, aspect <= 1.8, fill >= 0.45 else { continue }
            let diameter = (4 * Double(count) / Double.pi).squareRoot() / Double(min(w, h))
            best = max(best, diameter)
        }
        return best
    }

    /// Human-readable fix for each failure code, shown on the capture screen.
    public static func advice(for failure: String) -> String {
        switch failure {
        case "blurry": return "Hold steady and tap to focus"
        case "glare": return "Reduce glare: tilt the phone or diffuse the light"
        case "too_dark": return "Too dark: add diffused light"
        case "too_bright": return "Too bright: move out of direct sun"
        case "too_small": return "Move closer"
        case "eye_too_small": return "Move closer: the eye should fill the circle"
        default: return failure
        }
    }
}

/// Fires auto-capture once the gate has passed for `requiredStreak` consecutive preview frames,
/// then waits `cooldown` seconds so one steady moment doesn't produce a burst of identical shots.
public struct AutoCaptureTrigger: Sendable {
    public var requiredStreak: Int
    public var cooldown: TimeInterval
    private var streak = 0
    private var lastFired: Date?

    public init(requiredStreak: Int = 5, cooldown: TimeInterval = 1.5) {
        self.requiredStreak = requiredStreak
        self.cooldown = cooldown
    }

    public mutating func feed(passed: Bool, at now: Date = Date()) -> Bool {
        streak = passed ? streak + 1 : 0
        if let last = lastFired, now.timeIntervalSince(last) < cooldown { return false }
        guard streak >= requiredStreak else { return false }
        streak = 0
        lastFired = now
        return true
    }

    public mutating func reset() {
        streak = 0
    }
}
