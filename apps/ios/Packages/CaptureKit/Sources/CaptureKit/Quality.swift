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

    /// Human-readable fix for each failure code, shown on the capture screen.
    public static func advice(for failure: String) -> String {
        switch failure {
        case "blurry": return "Hold steady and tap to focus"
        case "glare": return "Reduce glare: tilt the phone or diffuse the light"
        case "too_dark": return "Too dark: add diffused light"
        case "too_bright": return "Too bright: move out of direct sun"
        case "too_small": return "Move closer"
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
