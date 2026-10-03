import Foundation

/// Exposure metadata of a still, stored with each shot for retraining and audits.
public struct ExposureInfo: Codable, Hashable, Sendable {
    public var iso: Double?
    public var shutterS: Double?
    public var aperture: Double?
    public var lensPosition: Double?

    enum CodingKeys: String, CodingKey {
        case iso, aperture
        case shutterS = "shutter_s"
        case lensPosition = "lens_position"
    }

    public init(iso: Double? = nil, shutterS: Double? = nil, aperture: Double? = nil, lensPosition: Double? = nil) {
        self.iso = iso
        self.shutterS = shutterS
        self.aperture = aperture
        self.lensPosition = lensPosition
    }
}

/// Where a shot's region label came from. The server re-classifies every photo regardless.
public struct RegionLabel: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The checklist step the photo was taken in.
        case checklist
        /// An on-device classifier model.
        case model
        /// Ad-hoc photo outside the checklist; left for the server to classify.
        case unlabelled
    }

    public var source: Source
    /// On-device classifier's guess and confidence, kept even when it disagrees with the checklist.
    public var modelRegion: Region?
    public var modelConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case source
        case modelRegion = "model_region"
        case modelConfidence = "model_confidence"
    }

    public init(source: Source, modelRegion: Region? = nil, modelConfidence: Double? = nil) {
        self.source = source
        self.modelRegion = modelRegion
        self.modelConfidence = modelConfidence
    }
}

public struct Shot: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var region: Region
    public var view: String
    public var spectrum: Spectrum
    public var capturedAt: Date
    /// File name inside the session folder on the phone.
    public var fileName: String
    public var width: Int
    public var height: Int
    public var quality: QualityReport
    public var exposure: ExposureInfo
    public var label: RegionLabel
    public var cameraName: String

    public init(
        id: String = newID(), region: Region, view: String, spectrum: Spectrum, capturedAt: Date = Date(),
        fileName: String, width: Int, height: Int, quality: QualityReport,
        exposure: ExposureInfo = ExposureInfo(), label: RegionLabel = RegionLabel(source: .checklist),
        cameraName: String = ""
    ) {
        self.id = id
        self.region = region
        self.view = view
        self.spectrum = spectrum
        self.capturedAt = capturedAt
        self.fileName = fileName
        self.width = width
        self.height = height
        self.quality = quality
        self.exposure = exposure
        self.label = label
        self.cameraName = cameraName
    }
}

public struct ViewKey: Codable, Hashable, Sendable {
    public var region: Region
    public var view: String

    public init(_ region: Region, _ view: String) {
        self.region = region
        self.view = view
    }
}

public struct SkippedView: Codable, Hashable, Sendable {
    public var region: Region
    public var view: String
    public var reason: String
}

/// The ring read the operator confirmed on the phone. The server's OCR stays authoritative.
public struct RingRead: Codable, Hashable, Sendable {
    public var code: String
    public var match: RingMatch?
    /// `vision` for an on-device OCR read the operator accepted, `manual` if typed.
    public var source: String
    public var shotId: String?

    enum CodingKeys: String, CodingKey {
        case code, match, source
        case shotId = "shot_id"
    }

    public init(code: String, match: RingMatch?, source: String, shotId: String?) {
        self.code = code
        self.match = match
        self.source = source
        self.shotId = shotId
    }
}

public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double
    public var accuracyM: Double

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case accuracyM = "accuracy_m"
    }

    public init(lat: Double, lon: Double, accuracyM: Double) {
        self.lat = lat
        self.lon = lon
        self.accuracyM = accuracyM
    }
}

/// One bird, one capture session: the region checklist plus every shot taken.
/// Mirrors `birdreid.capture.session.CaptureSession`.
public struct CaptureSession: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var site: String
    public var operatorName: String
    public var deviceId: String
    public var deviceModel: String
    public var context: CaptureContext
    public var startedAt: Date
    public var finishedAt: Date?
    public var location: GeoPoint?
    public var notes: String
    public var protocolVersion: Int
    public var ringRead: RingRead?
    public var shots: [Shot]
    public var skipped: [SkippedView]

    public init(
        id: String = newID(), site: String, operatorName: String, deviceId: String, deviceModel: String,
        context: CaptureContext = .handling, startedAt: Date = Date(), notes: String = "", protocolVersion: Int
    ) {
        self.id = id
        self.site = site
        self.operatorName = operatorName
        self.deviceId = deviceId
        self.deviceModel = deviceModel
        self.context = context
        self.startedAt = startedAt
        self.notes = notes
        self.protocolVersion = protocolVersion
        self.shots = []
        self.skipped = []
    }

    public var isFinished: Bool { finishedAt != nil }

    public mutating func add(_ shot: Shot) {
        shots.append(shot)
        skipped.removeAll { $0.region == shot.region && $0.view == shot.view }
    }

    public mutating func remove(shotId: String) {
        shots.removeAll { $0.id == shotId }
        if ringRead?.shotId == shotId { ringRead?.shotId = nil }
    }

    public mutating func skip(_ key: ViewKey, reason: String) {
        unskip(key)
        skipped.append(SkippedView(region: key.region, view: key.view, reason: reason))
    }

    public mutating func unskip(_ key: ViewKey) {
        skipped.removeAll { $0.region == key.region && $0.view == key.view }
    }

    public func isSkipped(_ key: ViewKey) -> Bool {
        skipped.contains { $0.region == key.region && $0.view == key.view }
    }

    public func shots(for key: ViewKey) -> [Shot] {
        shots.filter { $0.region == key.region && $0.view == key.view }
    }

    public func passingCount(_ key: ViewKey) -> Int {
        shots(for: key).filter { $0.quality.passed }.count
    }

    /// Highest-scoring passing shot of a view, which the pipeline treats as `is_best`.
    public func best(_ key: ViewKey) -> Shot? {
        shots(for: key).filter { $0.quality.passed }.max { $0.quality.score < $1.quality.score }
    }

    public func isDone(_ key: ViewKey, in protocols: ProtocolSet) -> Bool {
        guard let proto = protocols[key.region] else { return true }
        return isSkipped(key) || passingCount(key) >= proto.minShotsPerView
    }

    /// Required views still lacking enough passing shots and not skipped, in checklist order.
    public func pending(_ protocols: ProtocolSet) -> [ViewKey] {
        protocols.regions.filter(\.required).flatMap { proto in
            proto.views.map { ViewKey(proto.region, $0.name) }
        }.filter { !isDone($0, in: protocols) }
    }

    public func isComplete(_ protocols: ProtocolSet) -> Bool { pending(protocols).isEmpty }

    /// Object key of a shot, matching `birdreid.storage.object_store.image_key`.
    public func objectKey(for shot: Shot) -> String {
        "raw/\(site)/\(id)/\(shot.region.rawValue)/\(shot.view)_\(shot.spectrum.rawValue)_\(shot.id).jpg"
    }

    public var manifestKey: String { "raw/\(site)/\(id)/session.json" }

    /// session.json uploaded after the images: the fields of the Python manifest plus phone extras.
    public func manifest() -> Manifest {
        Manifest(
            sessionId: id,
            deviceId: deviceId,
            deviceModel: deviceModel,
            operatorName: operatorName,
            site: site,
            context: context,
            startedAt: startedAt,
            finishedAt: finishedAt,
            location: location,
            notes: notes,
            protocolVersion: protocolVersion,
            ringCode: ringRead?.code,
            ringRead: ringRead,
            shots: shots.map { shot in
                Manifest.ShotEntry(
                    shotId: shot.id,
                    key: objectKey(for: shot),
                    region: shot.region,
                    view: shot.view,
                    spectrum: shot.spectrum,
                    capturedAt: shot.capturedAt,
                    width: shot.width,
                    height: shot.height,
                    quality: shot.quality,
                    exposure: shot.exposure,
                    label: shot.label,
                    camera: shot.cameraName,
                    isBest: best(ViewKey(shot.region, shot.view))?.id == shot.id
                )
            },
            skipped: skipped
        )
    }
}

public struct Manifest: Codable, Hashable, Sendable {
    public struct ShotEntry: Codable, Hashable, Sendable {
        public var shotId: String
        public var key: String
        public var region: Region
        public var view: String
        public var spectrum: Spectrum
        public var capturedAt: Date
        public var width: Int
        public var height: Int
        public var quality: QualityReport
        public var exposure: ExposureInfo
        public var label: RegionLabel
        public var camera: String
        public var isBest: Bool

        enum CodingKeys: String, CodingKey {
            case key, region, view, spectrum, width, height, quality, exposure, label, camera
            case shotId = "shot_id"
            case capturedAt = "captured_at"
            case isBest = "is_best"
        }
    }

    public var sessionId: String
    public var deviceId: String
    public var deviceModel: String
    public var operatorName: String
    public var site: String
    public var context: CaptureContext
    public var startedAt: Date
    public var finishedAt: Date?
    public var location: GeoPoint?
    public var notes: String
    public var protocolVersion: Int
    public var ringCode: String?
    public var ringRead: RingRead?
    public var shots: [ShotEntry]
    public var skipped: [SkippedView]

    enum CodingKeys: String, CodingKey {
        case site, context, location, notes, shots, skipped
        case sessionId = "session_id"
        case deviceId = "device_id"
        case deviceModel = "device_model"
        case operatorName = "operator"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case protocolVersion = "protocol_version"
        case ringCode = "ring_code"
        case ringRead = "ring_read"
    }

    /// ISO-8601 dates, sorted keys: the format the server and dataset exports expect.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
