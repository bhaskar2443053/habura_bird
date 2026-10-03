import XCTest
@testable import CaptureKit

final class SessionTests: XCTestCase {
    let protocols = ProtocolSet(version: 1, regions: [
        RegionProtocol(region: .ring, views: [ViewSpec(name: "code")], minShotsPerView: 2),
        RegionProtocol(region: .feet, views: [ViewSpec(name: "left_dorsal"), ViewSpec(name: "right_dorsal")]),
        RegionProtocol(region: .wing, views: [ViewSpec(name: "left_spread")], required: false),
    ])

    func report(_ sharpness: Double, passed: Bool = true) -> QualityReport {
        QualityReport(sharpness: sharpness, glareRatio: 0, brightness: 120, shortSidePx: 3000,
                      failures: passed ? [] : ["blurry"])
    }

    func shot(_ region: Region, _ view: String, _ sharpness: Double, passed: Bool = true) -> Shot {
        Shot(region: region, view: view, spectrum: .rgb, fileName: "x.jpg", width: 4000, height: 3000,
             quality: report(sharpness, passed: passed))
    }

    func session() -> CaptureSession {
        CaptureSession(site: "site-a", operatorName: "op", deviceId: "dev", deviceModel: "iPhone",
                       protocolVersion: 1)
    }

    func testPendingFollowsChecklistAndMinShots() {
        var s = session()
        XCTAssertEqual(s.pending(protocols), [ViewKey(.ring, "code"), ViewKey(.feet, "left_dorsal"),
                                              ViewKey(.feet, "right_dorsal")])
        s.add(shot(.ring, "code", 200))
        s.add(shot(.ring, "code", 10, passed: false))
        XCTAssertTrue(s.pending(protocols).contains(ViewKey(.ring, "code")), "needs 2 passing shots")
        s.add(shot(.ring, "code", 300))
        s.add(shot(.feet, "left_dorsal", 120))
        s.skip(ViewKey(.feet, "right_dorsal"), reason: "bird stressed")
        XCTAssertTrue(s.isComplete(protocols))
    }

    func testAddingAShotUnskipsTheView() {
        var s = session()
        s.skip(ViewKey(.feet, "left_dorsal"), reason: "x")
        s.add(shot(.feet, "left_dorsal", 120))
        XCTAssertFalse(s.isSkipped(ViewKey(.feet, "left_dorsal")))
    }

    func testManifestMarksBestAndUsesServerKeyLayout() throws {
        var s = session()
        let low = shot(.ring, "code", 200)
        let high = shot(.ring, "code", 300)
        s.add(low)
        s.add(high)
        s.skip(ViewKey(.feet, "left_dorsal"), reason: "injured")
        let manifest = s.manifest()
        XCTAssertEqual(manifest.shots.filter(\.isBest).map(\.shotId), [high.id])
        XCTAssertEqual(manifest.shots[0].key, "raw/site-a/\(s.id)/ring/code_rgb_\(low.id).jpg")
        XCTAssertEqual(s.manifestKey, "raw/site-a/\(s.id)/session.json")

        let json = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]
        XCTAssertEqual(json["session_id"] as? String, s.id)
        XCTAssertEqual(json["operator"] as? String, "op")
        let skipped = json["skipped"] as! [[String: Any]]
        XCTAssertEqual(skipped.first?["reason"] as? String, "injured")
        let firstShot = (json["shots"] as! [[String: Any]])[0]
        XCTAssertNotNil(firstShot["is_best"])
        XCTAssertNotNil((firstShot["quality"] as! [String: Any])["glare_ratio"])
    }

    func testIdsMatchPythonUUIDHex() {
        let id = newID()
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(keySegment(" Site A/1 "), "Site-A-1")
    }

    func testBundledProtocolsDecode() throws {
        // The JSON the app ships, exported from configs/protocols by scripts/export_protocols.py.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HoubaraCapture/Resources/protocols.json")
        let set = try ProtocolSet.load(from: Data(contentsOf: url))
        XCTAssertEqual(set.regions.first?.region, .ring)
        XCTAssertEqual(set[.iris]?.spectra, [.rgb, .nir])
        XCTAssertEqual(set[.iris]?.minShotsPerView, 2)
        XCTAssertFalse(set[.wing]?.required ?? true)
    }
}
