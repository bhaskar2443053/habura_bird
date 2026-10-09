import CaptureKit
import Foundation
import ImageIO
import UIKit

/// Sessions live on the phone first: Documents/Sessions/{session_id}/ holds the JPEGs, the app's
/// own state.json and, once finished, the session.json manifest that is uploaded. The folder is
/// visible in the Files app, so nothing is lost if the server is unreachable for a whole season.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [CaptureSession] = []
    let root: URL

    private var sessionsDir: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(root: URL) {
        self.root = root
        load()
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        sessions = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")) else { return nil }
            return try? SessionStore.decoder.decode(CaptureSession.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func session(_ id: String) -> CaptureSession? {
        sessions.first { $0.id == id }
    }

    func folder(_ sessionId: String) -> URL {
        sessionsDir.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// Path relative to `root`, as stored in upload jobs.
    func relativePath(_ sessionId: String, _ file: String) -> String {
        "Sessions/\(sessionId)/\(file)"
    }

    func imageURL(_ sessionId: String, _ shot: Shot) -> URL {
        folder(sessionId).appendingPathComponent(shot.fileName)
    }

    func save(_ session: CaptureSession) {
        let dir = folder(session.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try SessionStore.encoder.encode(session).write(to: dir.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            assertionFailure("could not save session \(session.id): \(error)")
        }
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    /// Writes the JPEG and returns its file name inside the session folder.
    func writeImage(_ data: Data, sessionId: String, shotId: String) throws -> String {
        let name = "\(shotId).jpg"
        let dir = folder(sessionId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    func deleteShot(_ shot: Shot, from sessionId: String) {
        guard var session = session(sessionId) else { return }
        try? FileManager.default.removeItem(at: imageURL(sessionId, shot))
        session.remove(shotId: shot.id)
        save(session)
    }

    func delete(_ session: CaptureSession) {
        try? FileManager.default.removeItem(at: folder(session.id))
        sessions.removeAll { $0.id == session.id }
    }

    /// Marks the session finished, writes session.json and returns the upload jobs for it.
    func finish(_ session: CaptureSession) throws -> [UploadJob] {
        var session = session
        session.finishedAt = Date()
        let manifestName = "session.json"
        try session.manifest().encoded().write(to: folder(session.id).appendingPathComponent(manifestName), options: .atomic)
        save(session)
        let images = session.shots.map { shot in
            UploadJob.image(shot, in: session, filePath: relativePath(session.id, shot.fileName))
        }
        return images + [UploadJob.manifest(for: session, filePath: relativePath(session.id, manifestName))]
    }
}

/// Small, cached thumbnails so the checklist doesn't decode 12 MP JPEGs on scroll.
enum Thumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150_000_000  // decoded bytes; full-screen photos are ~20 MB each
        return cache
    }()

    static func load(_ url: URL, maxPixel: Int = 240) async -> UIImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image, let cg = image.cgImage { cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height) }
        return image
    }
}
