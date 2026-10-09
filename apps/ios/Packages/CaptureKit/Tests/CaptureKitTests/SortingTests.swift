import XCTest
@testable import CaptureKit

final class SortingTests: XCTestCase {
    let protocols = ProtocolSet(version: 1, regions: [
        RegionProtocol(region: .ring, views: [ViewSpec(name: "code")]),
        RegionProtocol(region: .face, views: [ViewSpec(name: "left"), ViewSpec(name: "right")]),
        RegionProtocol(region: .feet, views: [ViewSpec(name: "left_dorsal"), ViewSpec(name: "right_dorsal")]),
        RegionProtocol(region: .wing, views: [ViewSpec(name: "left_spread")], required: false),
    ])

    func session() -> CaptureSession {
        CaptureSession(site: "s", operatorName: "op", deviceId: "d", deviceModel: "iPhone", protocolVersion: 1)
    }

    func shot(_ region: Region, _ view: String, source: RegionLabel.Source = .suggested) -> Shot {
        Shot(region: region, view: view, spectrum: .rgb, fileName: "x.jpg", width: 4000, height: 3000,
             quality: QualityReport(sharpness: 200, glareRatio: 0, brightness: 120, shortSidePx: 3000, failures: []),
             label: RegionLabel(source: source))
    }

    func testSuggestionFollowsTargetWithoutOtherEvidence() {
        let target = ViewKey(.face, "left")
        XCTAssertEqual(RegionSuggester.suggest(target: target, ringCodeSeen: false, model: nil,
                                               session: session(), protocols: protocols), target)
    }

    func testRingCodeInPhotoWins() {
        let key = RegionSuggester.suggest(target: ViewKey(.feet, "left_dorsal"), ringCodeSeen: true,
                                          model: (.face, 0.9), session: session(), protocols: protocols)
        XCTAssertEqual(key, ViewKey(.ring, "code"))
    }

    func testConfidentModelPicksFirstUnfinishedViewOfItsRegion() {
        var s = session()
        s.add(shot(.feet, "left_dorsal"))
        let key = RegionSuggester.suggest(target: ViewKey(.face, "left"), ringCodeSeen: false,
                                          model: (.feet, 0.8), session: s, protocols: protocols)
        XCTAssertEqual(key, ViewKey(.feet, "right_dorsal"))
        let unsure = RegionSuggester.suggest(target: ViewKey(.face, "left"), ringCodeSeen: false,
                                             model: (.feet, 0.4), session: s, protocols: protocols)
        XCTAssertEqual(unsure, ViewKey(.face, "left"))
    }

    func testRingCodeHeuristic() {
        let empty = RingRegistry(codes: [])
        XCTAssertTrue(RegionSuggester.looksLikeRingCode(["HB1023"], registry: empty))
        XCTAssertFalse(RegionSuggester.looksLikeRingCode(["READER3", "NPRTONLY"], registry: empty))
        let registry = RingRegistry(codes: ["HB1023"])
        XCTAssertTrue(RegionSuggester.looksLikeRingCode(["HB1O23"], registry: registry))
        XCTAssertFalse(RegionSuggester.looksLikeRingCode(["ZZ9999"], registry: registry))
    }

    func testNextPendingWalksForwardAndWraps() {
        var s = session()
        XCTAssertEqual(s.nextPending(after: ViewKey(.face, "left"), in: protocols), ViewKey(.face, "right"))
        XCTAssertEqual(s.nextPending(after: ViewKey(.feet, "right_dorsal"), in: protocols), ViewKey(.ring, "code"))
        for key in [ViewKey(.ring, "code"), ViewKey(.face, "left"), ViewKey(.face, "right"), ViewKey(.feet, "left_dorsal")] {
            s.add(shot(key.region, key.view))
        }
        XCTAssertEqual(s.nextPending(after: ViewKey(.ring, "code"), in: protocols), ViewKey(.feet, "right_dorsal"))
        s.add(shot(.feet, "right_dorsal"))
        XCTAssertNil(s.nextPending(after: ViewKey(.ring, "code"), in: protocols))
    }

    func testRelabelAndConfirm() {
        var s = session()
        let a = shot(.face, "left")
        let b = shot(.face, "right")
        s.add(a)
        s.add(b)
        s.skip(ViewKey(.feet, "left_dorsal"), reason: "x")
        XCTAssertEqual(s.shotsToCheck.count, 2)
        s.relabel(shotId: a.id, to: ViewKey(.feet, "left_dorsal"))
        XCTAssertEqual(s.shots[0].region, .feet)
        XCTAssertEqual(s.shots[0].label.source, .operatorChoice)
        XCTAssertFalse(s.isSkipped(ViewKey(.feet, "left_dorsal")))
        s.confirmSuggestions()
        XCTAssertTrue(s.shotsToCheck.isEmpty)
        let json = try! JSONSerialization.jsonObject(with: s.manifest().encoded()) as! [String: Any]
        let label = ((json["shots"] as! [[String: Any]])[0]["label"] as! [String: Any])
        XCTAssertEqual(label["source"] as? String, "operator")
    }

    func testLoadShedsWorkAsThePhoneHeatsUp() {
        let cool = CameraLoad.forHeat(.nominal)
        let hot = CameraLoad.forHeat(.serious)
        let critical = CameraLoad.forHeat(.critical)
        XCTAssertLessThan(hot.framesPerSecond, cool.framesPerSecond)
        XCTAssertGreaterThan(hot.analyseEvery, cool.analyseEvery)
        XCTAssertTrue(hot.holdUploads)
        XCTAssertFalse(cool.paused)
        XCTAssertTrue(critical.paused)
        XCTAssertNil(CameraLoad.message(for: .fair))
        XCTAssertNotNil(CameraLoad.message(for: .critical))
    }
}
