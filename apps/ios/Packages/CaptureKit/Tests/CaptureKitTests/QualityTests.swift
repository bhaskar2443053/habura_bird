import XCTest
@testable import CaptureKit

final class QualityTests: XCTestCase {
    func checkerboard(_ size: Int, cell: Int, low: UInt8 = 40, high: UInt8 = 200) -> GrayImage {
        var px = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size { px[y * size + x] = ((x / cell + y / cell) % 2 == 0) ? low : high }
        }
        return GrayImage(width: size, height: size, pixels: px)
    }

    func testFlatImageHasZeroSharpness() {
        let flat = GrayImage(width: 50, height: 50, pixels: [UInt8](repeating: 120, count: 2500))
        XCTAssertEqual(Quality.sharpness(flat), 0, accuracy: 1e-9)
        XCTAssertEqual(Quality.brightness(flat), 120, accuracy: 1e-9)
        XCTAssertEqual(Quality.glareRatio(flat), 0)
    }

    func testSharpPatternBeatsBlurredPattern() {
        let sharp = checkerboard(64, cell: 2)
        let soft = checkerboard(64, cell: 16)
        XCTAssertGreaterThan(Quality.sharpness(sharp), Quality.sharpness(soft))
    }

    /// Same value birdreid.capture.quality.sharpness returns for this image (42500.0).
    func testMatchesPythonOn4x4() {
        // Interior Laplacians: -400, 100, 100, 0 -> mean -50, variance 42500.
        var px = [UInt8](repeating: 0, count: 16)
        px[5] = 100
        let img = GrayImage(width: 4, height: 4, pixels: px)
        XCTAssertEqual(Quality.sharpness(img), 42500, accuracy: 1e-6)
    }

    func testAssessReportsFailures() {
        let bright = GrayImage(width: 100, height: 100, pixels: [UInt8](repeating: 255, count: 10_000))
        let report = Quality.assess(bright, thresholds: QualityThresholds(minShortSidePx: 640))
        XCTAssertEqual(report.failures, ["blurry", "glare", "too_bright", "too_small"])
        XCTAssertFalse(report.passed)

        let ok = Quality.assess(checkerboard(64, cell: 2), shortSidePx: 3000, thresholds: QualityThresholds())
        XCTAssertTrue(ok.passed, "\(ok.failures)")
        XCTAssertEqual(ok.shortSidePx, 3000)
    }

    func testAutoCaptureNeedsStreakAndCooldown() {
        var trigger = AutoCaptureTrigger(requiredStreak: 3, cooldown: 2)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(trigger.feed(passed: true, at: t0))
        XCTAssertFalse(trigger.feed(passed: false, at: t0))
        XCTAssertFalse(trigger.feed(passed: true, at: t0))
        XCTAssertFalse(trigger.feed(passed: true, at: t0))
        XCTAssertTrue(trigger.feed(passed: true, at: t0))
        for _ in 0..<5 { XCTAssertFalse(trigger.feed(passed: true, at: t0.addingTimeInterval(1))) }
        XCTAssertTrue(trigger.feed(passed: true, at: t0.addingTimeInterval(2.5)))
    }
}
