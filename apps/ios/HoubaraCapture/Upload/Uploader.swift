import CaptureKit
import Foundation
import Network

/// Drains the upload queue: asks the ingest API for a presigned URL, then hands the file to a
/// background URLSession so uploads continue while the phone is locked or the app is closed.
@MainActor
final class Uploader: NSObject, ObservableObject {
    @Published private(set) var jobs: [UploadJob] = []
    @Published private(set) var isOnline = true
    @Published private(set) var lastError: String?

    let queue: UploadQueue
    private let dataRoot: URL
    private let clientProvider: @MainActor () -> IngestClient?
    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var pumping = false
    private var pumpAgain = false

    static let sessionIdentifier = "org.habura.HoubaraCapture.uploads"

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Uploader.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(dataRoot: URL, queueURL: URL, clientProvider: @escaping @MainActor () -> IngestClient?) {
        self.dataRoot = dataRoot
        self.queue = UploadQueue(storeURL: queueURL)
        self.clientProvider = clientProvider
        super.init()

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
                if online { self?.kick() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "uploader.network"))
        // Retries jobs whose back-off has expired.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
        Task {
            let running = await backgroundSession.allTasks.compactMap(\.taskDescription)
            await queue.markInFlight(Set(running))
            await refresh()
            kick()
        }
    }

    var pendingCount: Int { jobs.filter { $0.state != .done }.count }

    func enqueue(_ newJobs: [UploadJob]) async {
        for job in newJobs { await queue.enqueue(job) }
        await refresh()
        kick()
    }

    func retryAll() {
        Task {
            await queue.retryAll()
            kick()
        }
    }

    func clearFinished() {
        Task {
            await queue.removeDone(olderThan: Date())
            await refresh()
        }
    }

    /// Starts whatever is ready. Safe to call often.
    func kick() {
        if pumping {
            pumpAgain = true
            return
        }
        pumping = true
        Task {
            repeat {
                pumpAgain = false
                await pump()
            } while pumpAgain
            pumping = false
        }
    }

    private func refresh() async {
        jobs = await queue.jobs
    }

    private func pump() async {
        guard let client = clientProvider() else {
            if pendingCount > 0 { lastError = IngestError.notConfigured.localizedDescription }
            return
        }
        guard isOnline else { return }
        for job in await queue.claim() {
            let fileURL = dataRoot.appendingPathComponent(job.filePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                await queue.markFailed(job.id, error: "File is missing on this phone")
                continue
            }
            do {
                let ticket = try await client.requestTicket(for: job)
                await queue.setKey(job.id, key: ticket.key)
                let request = IngestClient.putRequest(ticket: ticket, contentType: job.contentType)
                let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
                task.taskDescription = job.id
                task.resume()
                lastError = nil
            } catch {
                await queue.markFailed(job.id, error: error.localizedDescription)
                lastError = error.localizedDescription
            }
        }
        await refresh()
    }

    fileprivate func finished(jobId: String, error: String?) {
        Task {
            if let error {
                await queue.markFailed(jobId, error: error)
                lastError = error
            } else {
                await queue.markDone(jobId)
            }
            await refresh()
            kick()
        }
    }
}

extension Uploader: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let jobId = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let message: String?
        if let error {
            message = error.localizedDescription
        } else if !(200..<300).contains(status) {
            message = "Storage rejected the upload (HTTP \(status))"
        } else {
            message = nil
        }
        Task { @MainActor in self.finished(jobId: jobId, error: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundEvents.shared.completionHandler?()
            BackgroundEvents.shared.completionHandler = nil
        }
    }
}
