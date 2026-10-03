import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One file waiting to reach cloud storage. Images go first; the session's manifest is held back
/// until every image of that session is uploaded, so a manifest in the bucket means "complete".
public struct UploadJob: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, manifest }
    public enum State: String, Codable, Sendable { case pending, uploading, done }

    public var id: String
    public var kind: Kind
    public var site: String
    public var sessionId: String
    public var region: Region?
    public var view: String?
    public var spectrum: Spectrum?
    public var contentType: String
    /// Path relative to the app's data folder.
    public var filePath: String
    public var state: State
    public var attempts: Int
    public var lastError: String?
    public var notBefore: Date?
    public var key: String?
    public var createdAt: Date

    public static func image(_ shot: Shot, in session: CaptureSession, filePath: String) -> UploadJob {
        UploadJob(
            id: shot.id, kind: .image, site: session.site, sessionId: session.id, region: shot.region,
            view: shot.view, spectrum: shot.spectrum, contentType: "image/jpeg", filePath: filePath,
            state: .pending, attempts: 0, createdAt: Date()
        )
    }

    public static func manifest(for session: CaptureSession, filePath: String) -> UploadJob {
        UploadJob(
            id: "manifest-\(session.id)", kind: .manifest, site: session.site, sessionId: session.id,
            contentType: "application/json", filePath: filePath, state: .pending, attempts: 0,
            createdAt: Date()
        )
    }
}

/// Persistent, offline-first upload queue. Breeding sites often have no signal, so captures stay
/// on the phone and the queue drains whenever the network is back.
public actor UploadQueue {
    public private(set) var jobs: [UploadJob] = []
    private let storeURL: URL?

    /// - Parameter storeURL: JSON file the queue persists to; nil keeps it in memory (tests).
    public init(storeURL: URL?) {
        self.storeURL = storeURL
        if let url = storeURL, let data = try? Data(contentsOf: url),
           let saved = try? UploadQueue.decoder.decode([UploadJob].self, from: data) {
            // A job that was mid-upload when the app died is retried.
            jobs = saved.map { job in
                var job = job
                if job.state == .uploading { job.state = .pending }
                return job
            }
        }
    }

    public func enqueue(_ job: UploadJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            // An uploaded image never changes. A manifest is rewritten when a finished session is
            // edited, so it is queued again.
            if jobs[i].state == .done && job.kind == .image { return }
            jobs[i] = job
        } else {
            jobs.append(job)
        }
        save()
    }

    /// Jobs that may start now: pending, past their back-off, and for a manifest, only once every
    /// image job of its session is done.
    public func ready(now: Date = Date()) -> [UploadJob] {
        let unfinishedImageSessions = Set(jobs.filter { $0.kind == .image && $0.state != .done }.map(\.sessionId))
        return jobs.filter { job in
            job.state == .pending
                && (job.notBefore ?? .distantPast) <= now
                && !(job.kind == .manifest && unfinishedImageSessions.contains(job.sessionId))
        }
    }

    /// Marks up to `maxInFlight` minus the uploads already running as uploading and returns them.
    public func claim(now: Date = Date(), maxInFlight: Int = 3) -> [UploadJob] {
        let running = jobs.filter { $0.state == .uploading }.count
        let picked = ready(now: now).prefix(max(0, maxInFlight - running))
        for job in picked {
            update(job.id) {
                $0.state = .uploading
                $0.attempts += 1
            }
        }
        return picked.compactMap { self.job($0.id) }
    }

    /// Re-marks jobs whose background upload survived an app restart.
    public func markInFlight(_ ids: Set<String>) {
        for i in jobs.indices where ids.contains(jobs[i].id) && jobs[i].state != .done {
            jobs[i].state = .uploading
        }
        save()
    }

    public func setKey(_ id: String, key: String) {
        update(id) { $0.key = key }
    }

    public func markDone(_ id: String) {
        update(id) {
            $0.state = .done
            $0.lastError = nil
            $0.notBefore = nil
        }
    }

    /// Back-off: 5 s, 10 s, 20 s … capped at 30 min.
    public func markFailed(_ id: String, error: String, now: Date = Date()) {
        update(id) {
            $0.state = .pending
            $0.lastError = error
            $0.notBefore = now.addingTimeInterval(UploadQueue.backoff(attempts: $0.attempts))
        }
    }

    /// Clears back-off so everything pending is retried now (the "Retry" button).
    public func retryAll() {
        for i in jobs.indices where jobs[i].state == .pending { jobs[i].notBefore = nil }
        save()
    }

    public func removeDone(olderThan cutoff: Date) {
        jobs.removeAll { $0.state == .done && $0.createdAt < cutoff }
        save()
    }

    public func job(_ id: String) -> UploadJob? { jobs.first { $0.id == id } }

    public static func backoff(attempts: Int) -> TimeInterval {
        min(5 * pow(2, Double(max(attempts - 1, 0))), 30 * 60)
    }

    private func update(_ id: String, _ change: (inout UploadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    private func save() {
        guard let url = storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try UploadQueue.encoder.encode(jobs).write(to: url, options: .atomic)
        } catch {
            // The queue keeps working in memory; it is rebuilt from the session folders on launch.
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Presigned upload ticket from the ingest API (`birdreid.api.app`).
public struct UploadTicket: Codable, Hashable, Sendable {
    public var shotId: String
    public var key: String
    public var url: URL

    enum CodingKeys: String, CodingKey {
        case key, url
        case shotId = "shot_id"
    }
}

public enum IngestError: Error, LocalizedError {
    case badStatus(Int, String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case let .badStatus(code, body): return "Server returned \(code): \(body.prefix(200))"
        case .notConfigured: return "Set the server address in Settings"
        }
    }
}

/// Talks to the ingest API, which hands out presigned S3 URLs; the image itself goes straight to S3.
public struct IngestClient: Sendable {
    public var baseURL: URL
    public var apiKey: String?

    public init(baseURL: URL, apiKey: String? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// POST /uploads for an image job, or POST /manifests for a manifest job.
    public func ticketRequest(for job: UploadJob) throws -> URLRequest {
        var body: [String: String] = ["site": job.site, "session_id": job.sessionId]
        let path: String
        switch job.kind {
        case .image:
            path = "uploads"
            body["region"] = job.region?.rawValue ?? Region.other.rawValue
            body["view"] = job.view ?? "adhoc"
            body["spectrum"] = (job.spectrum ?? .rgb).rawValue
            body["content_type"] = job.contentType
            body["shot_id"] = job.id
        case .manifest:
            path = "manifests"
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 30
        return request
    }

    /// The PUT to the presigned URL. S3 rejects it unless Content-Type matches the signature.
    public static func putRequest(ticket: UploadTicket, contentType: String) -> URLRequest {
        var request = URLRequest(url: ticket.url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    public static func decodeTicket(data: Data, response: URLResponse) throws -> UploadTicket {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw IngestError.badStatus(status, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(UploadTicket.self, from: data)
    }

    public func requestTicket(for job: UploadJob, session: URLSession = .shared) async throws -> UploadTicket {
        let request = try ticketRequest(for: job)
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    let fallback = URLResponse(
                        url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
                    )
                    cont.resume(returning: (data ?? Data(), response ?? fallback))
                }
            }.resume()
        }
        return try IngestClient.decodeTicket(data: data, response: response)
    }
}
