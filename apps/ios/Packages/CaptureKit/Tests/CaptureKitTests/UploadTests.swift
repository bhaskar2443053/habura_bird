import XCTest
@testable import CaptureKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class UploadTests: XCTestCase {
    func session() -> CaptureSession {
        CaptureSession(site: "site-a", operatorName: "op", deviceId: "dev", deviceModel: "iPhone", protocolVersion: 1)
    }

    func shot() -> Shot {
        Shot(region: .iris, view: "left_eye", spectrum: .nir, fileName: "a.jpg", width: 1, height: 1,
             quality: QualityReport(sharpness: 1, glareRatio: 0, brightness: 1, shortSidePx: 1, failures: []))
    }

    func testManifestWaitsForImagesOfItsSession() async {
        let queue = UploadQueue(storeURL: nil)
        let s = session()
        let image = UploadJob.image(shot(), in: s, filePath: "a.jpg")
        await queue.enqueue(image)
        await queue.enqueue(UploadJob.manifest(for: s, filePath: "session.json"))
        var ready = await queue.ready()
        XCTAssertEqual(ready.map(\.kind), [.image])
        let claimed = await queue.claim()
        XCTAssertEqual(claimed.map(\.state), [.uploading])
        let none = await queue.claim()
        XCTAssertTrue(none.isEmpty, "a claimed job is not handed out twice")
        await queue.markDone(image.id)
        ready = await queue.ready()
        XCTAssertEqual(ready.map(\.kind), [.manifest])
    }

    func testFailureBacksOffAndRetryAllClearsIt() async {
        let queue = UploadQueue(storeURL: nil)
        let job = UploadJob.image(shot(), in: session(), filePath: "a.jpg")
        let now = Date()
        await queue.enqueue(job)
        _ = await queue.claim(now: now)
        await queue.markFailed(job.id, error: "offline", now: now)
        var ready = await queue.ready(now: now)
        XCTAssertTrue(ready.isEmpty)
        ready = await queue.ready(now: now.addingTimeInterval(6))
        XCTAssertEqual(ready.count, 1)
        await queue.retryAll()
        ready = await queue.ready(now: now)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(UploadQueue.backoff(attempts: 3), 20)
        XCTAssertEqual(UploadQueue.backoff(attempts: 50), 1800)
    }

    func testQueuePersistsAndResumesInterruptedUploads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(newID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let job = UploadJob.image(shot(), in: session(), filePath: "a.jpg")
        do {
            let queue = UploadQueue(storeURL: url)
            await queue.enqueue(job)
            _ = await queue.claim()
        }
        let reopened = UploadQueue(storeURL: url)
        let restored = await reopened.job(job.id)
        XCTAssertEqual(restored?.state, .pending)
        XCTAssertEqual(restored?.attempts, 1)
        await reopened.markInFlight([job.id])
        let inFlight = await reopened.job(job.id)
        XCTAssertEqual(inFlight?.state, .uploading)
    }

    func testEditedManifestIsQueuedAgainButImagesAreNot() async {
        let queue = UploadQueue(storeURL: nil)
        let s = session()
        let image = UploadJob.image(shot(), in: s, filePath: "a.jpg")
        let manifest = UploadJob.manifest(for: s, filePath: "session.json")
        for job in [image, manifest] {
            await queue.enqueue(job)
            await queue.markDone(job.id)
        }
        await queue.enqueue(image)
        await queue.enqueue(manifest)
        let ready = await queue.ready()
        XCTAssertEqual(ready.map(\.kind), [.manifest])
    }

    func testTicketRequestMatchesIngestAPI() throws {
        let client = IngestClient(baseURL: URL(string: "https://api.example.org/v1")!)
        let s = session()
        let sh = shot()
        let request = try client.ticketRequest(for: .image(sh, in: s, filePath: "a.jpg"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.org/v1/uploads")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        XCTAssertEqual(body, [
            "site": "site-a", "session_id": s.id, "region": "iris", "view": "left_eye",
            "spectrum": "nir", "content_type": "image/jpeg", "shot_id": sh.id,
        ])
        let manifest = try client.ticketRequest(for: .manifest(for: s, filePath: "session.json"))
        XCTAssertEqual(manifest.url?.lastPathComponent, "manifests")
    }

    func testDecodeTicketRejectsErrors() throws {
        let url = URL(string: "https://api.example.org/uploads")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"shot_id":"abc","key":"raw/a","url":"https://s3.example.org/put"}"#.utf8)
        XCTAssertEqual(try IngestClient.decodeTicket(data: data, response: ok).key, "raw/a")
        let bad = HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try IngestClient.decodeTicket(data: Data("nope".utf8), response: bad))
    }
}
