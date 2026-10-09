import CaptureKit
import Foundation

/// App-wide state: the bundled checklist, settings, local session store, upload queue and the
/// site's ring registry.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let protocols: ProtocolSet
    let settings: AppSettings
    let store: SessionStore
    let uploader: Uploader
    let location = LocationProvider()
    let heat = HeatMonitor()
    @Published private(set) var ringRegistry: RingRegistry

    private let registryURL: URL

    private init() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)

        let settings = AppSettings()
        self.settings = settings
        protocols = AppModel.loadBundledProtocols()
        store = SessionStore(root: documents)
        uploader = Uploader(
            dataRoot: documents,
            queueURL: support.appendingPathComponent("upload-queue.json"),
            clientProvider: { settings.ingestClient }
        )
        registryURL = support.appendingPathComponent("ring-registry.txt")
        let saved = (try? String(contentsOf: registryURL, encoding: .utf8)) ?? ""
        ringRegistry = RingRegistry(codes: RingRegistry.parse(saved))
    }

    private static func loadBundledProtocols() -> ProtocolSet {
        guard let url = Bundle.main.url(forResource: "protocols", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let set = try? ProtocolSet.load(from: data)
        else {
            fatalError("protocols.json missing from the app bundle; run scripts/export_protocols.py")
        }
        return set
    }

    var ringCodesText: String {
        ringRegistry.codes.sorted().joined(separator: "\n")
    }

    func setRingCodes(_ text: String) {
        let codes = RingRegistry.parse(text)
        try? codes.joined(separator: "\n").write(to: registryURL, atomically: true, encoding: .utf8)
        ringRegistry = RingRegistry(codes: codes)
    }

    func startSession(context: CaptureContext, notes: String) -> CaptureSession {
        var session = CaptureSession(
            site: keySegment(settings.site),
            operatorName: settings.operatorName,
            deviceId: settings.deviceId,
            deviceModel: AppSettings.deviceModel,
            context: context,
            notes: notes,
            protocolVersion: protocols.version
        )
        if let fix = location.last {
            session.location = GeoPoint(
                lat: fix.coordinate.latitude, lon: fix.coordinate.longitude, accuracyM: fix.horizontalAccuracy
            )
        }
        store.save(session)
        return session
    }

    /// Records unfinished views as skipped, writes session.json and queues everything for upload.
    func finish(_ session: CaptureSession) async throws {
        var session = session
        for key in session.pending(protocols) {
            session.skip(key, reason: "not captured")
        }
        let jobs = try store.finish(session)
        await uploader.enqueue(jobs)
    }
}
