import XCTest
@testable import CaptureKit

final class ReferencePoseTests: XCTestCase {
    func testViewsFromBundledProtocols() {
        XCTAssertEqual(ReferencePose.pose(region: .iris, view: "left_eye"),
                       ReferencePose(part: .eye, mirrored: false, camera: .side, closeUp: true))
        XCTAssertEqual(ReferencePose.pose(region: .iris, view: "right_eye").mirrored, true)
        XCTAssertEqual(ReferencePose.pose(region: .face, view: "frontal").camera, .front)
        XCTAssertEqual(ReferencePose.pose(region: .beak, view: "dorsal").camera, .above)
        XCTAssertEqual(ReferencePose.pose(region: .feet, view: "right_plantar"),
                       ReferencePose(part: .feet, mirrored: true, camera: .below))
        XCTAssertEqual(ReferencePose.pose(region: .feet, view: "left_dorsal").camera, .above)
        XCTAssertEqual(ReferencePose.pose(region: .plumageDorsal, view: "back").camera, .above)
        XCTAssertEqual(ReferencePose.pose(region: .plumageVentral, view: "breast").camera, .front)
        XCTAssertEqual(ReferencePose.pose(region: .ring, view: "code").part, .ring)
        XCTAssertEqual(ReferencePose.pose(region: .other, view: "adhoc").part, .wholeBird)
    }
}
