import XCTest
@testable import CaptureKit

/// Mirrors tests/test_ocr_and_classifier.py so the phone and server agree on ring reads.
final class RingRegistryTests: XCTestCase {
    let registry = RingRegistry(codes: ["HB1023", "HB1024", "HB2051", "AE0042"])

    func testExactAndNormalised() {
        XCTAssertEqual(registry.match("hb-1023").status, .exact)
        XCTAssertEqual(registry.match("hb-1023").code, "HB1023")
    }

    func testConfusablesResolve() {
        let m = registry.match("AEOO42")
        XCTAssertEqual(m.status, .fuzzy)
        XCTAssertEqual(m.code, "AE0042")
        XCTAssertTrue(m.confident)
    }

    func testOneEditAwayIsFuzzyUnlessTied() {
        XCTAssertEqual(registry.match("HB2O5l").code, "HB2051")
        // HB1025 is one edit from both HB1023 and HB1024.
        XCTAssertEqual(registry.match("HB1025").status, .ambiguous)
    }

    func testUnknownAndInvalid() {
        XCTAssertEqual(registry.match("ZZ9999").status, .unknown)
        XCTAssertEqual(registry.match("??").status, .invalidFormat)
    }

    func testBestMatchPrefersRegistryHits() {
        let best = registry.bestMatch(["XX", "HB1O23", "QQQ999"])
        XCTAssertEqual(best?.code, "HB1023")
        XCTAssertEqual(RingRegistry(codes: []).bestMatch(["HB7777"])?.status, .unknown)
    }

    func testParseCSV() {
        XCTAssertEqual(RingRegistry.parse("HB1023, male\n\nhb-1024\n"), ["HB1023", "HB1024"])
    }

    func testEditDistance() {
        XCTAssertEqual(RingRegistry.editDistance("", "abc"), 3)
        XCTAssertEqual(RingRegistry.editDistance("kitten", "sitting"), 3)
    }
}
