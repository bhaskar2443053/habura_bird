import XCTest
@testable import CaptureKit

final class EyeAndSidesTests: XCTestCase {
    /// Pale iris-coloured frame with a dark disc (the pupil) and optional dark border band.
    func frame(width: Int = 160, height: Int = 120, pupilRadius: Double, center: (Double, Double) = (80, 60),
               darkEdge: Bool = false) -> GrayImage {
        var pixels = [UInt8](repeating: 170, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - center.0, dy = Double(y) - center.1
                if (dx * dx + dy * dy).squareRoot() <= pupilRadius { pixels[y * width + x] = 15 }
                if darkEdge, x < 30 { pixels[y * width + x] = 5 }
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    func report() -> QualityReport {
        QualityReport(sharpness: 200, glareRatio: 0, brightness: 120, shortSidePx: 3000, failures: [])
    }

    func testCloseUpEyePasses() {
        let image = frame(pupilRadius: 15)  // pupil 30 px of 120: 0.25
        XCTAssertEqual(Quality.pupilFraction(image), 0.25, accuracy: 0.03)
        var r = report()
        Quality.checkEyeSize(image, report: &r)
        XCTAssertTrue(r.passed)
    }

    func testTinyEyeFails() {
        var r = report()
        Quality.checkEyeSize(frame(pupilRadius: 2.5), report: &r)
        XCTAssertEqual(r.failures, ["eye_too_small"])
        XCTAssertEqual(Quality.advice(for: "eye_too_small"), "Move closer: the eye should fill the circle")
    }

    func testDarkBackgroundAtTheEdgeIsNotAPupil() {
        XCTAssertLessThan(Quality.pupilFraction(frame(pupilRadius: 2, darkEdge: true)), Quality.minPupilFraction)
    }

    func testOffCentreBlobIgnored() {
        XCTAssertEqual(Quality.pupilFraction(frame(pupilRadius: 12, center: (20, 20))), 0)
    }

    func testTitlesNameTheBirdsOwnSide() {
        XCTAssertEqual(ViewSpec(name: "left_eye").title, "Bird's left eye")
        XCTAssertEqual(ViewSpec(name: "right_lateral").title, "Bird's right lateral")
        XCTAssertEqual(ViewSpec(name: "frontal").title, "Frontal")
        XCTAssertEqual(ViewSpec(name: "left_eye").mirroredName, "right_eye")
        XCTAssertNil(ViewSpec(name: "code").mirroredName)
    }

    func testSwapSides() {
        var s = CaptureSession(site: "s", operatorName: "o", deviceId: "d", deviceModel: "m", protocolVersion: 1)
        let q = report()
        s.add(Shot(region: .iris, view: "left_eye", spectrum: .rgb, fileName: "a.jpg", width: 1, height: 1, quality: q))
        s.add(Shot(region: .iris, view: "right_eye", spectrum: .rgb, fileName: "b.jpg", width: 1, height: 1, quality: q))
        s.add(Shot(region: .face, view: "left_lateral", spectrum: .rgb, fileName: "c.jpg", width: 1, height: 1, quality: q))
        s.swapSides(of: .iris)
        XCTAssertEqual(s.shots.map(\.view), ["right_eye", "left_eye", "left_lateral"])
        XCTAssertEqual(s.shots[0].label.source, .operatorChoice)
    }
}
