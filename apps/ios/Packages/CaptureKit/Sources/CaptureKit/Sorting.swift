import Foundation

/// Sorts a photo taken while photographing freely into a checklist view, so the operator can keep
/// both hands on the bird instead of picking the body part before every shot. The guess is
/// recorded as `RegionLabel.Source.suggested` and can be corrected on the sorting screen; the
/// server re-classifies every upload regardless.
public enum RegionSuggester {
    /// Minimum classifier confidence to override the part the operator is working through.
    public static let modelThreshold = 0.6

    /// - Parameters:
    ///   - target: the part currently highlighted on the capture screen (the walk-through position).
    ///   - ringCodeSeen: on-device OCR found something that reads like a ring code in the photo.
    ///   - model: the on-device classifier's guess, when a model is bundled.
    public static func suggest(
        target: ViewKey, ringCodeSeen: Bool, model: (Region, Double)?,
        session: CaptureSession, protocols: ProtocolSet
    ) -> ViewKey {
        if ringCodeSeen, let key = view(in: .ring, session: session, protocols: protocols) {
            return key
        }
        if let model, model.1 >= modelThreshold, model.0 != target.region,
           let key = view(in: model.0, session: session, protocols: protocols) {
            return key
        }
        return target
    }

    /// The first unfinished view of a region, else its first view.
    static func view(in region: Region, session: CaptureSession, protocols: ProtocolSet) -> ViewKey? {
        guard let proto = protocols[region], let first = proto.views.first else { return nil }
        let keys = proto.views.map { ViewKey(region, $0.name) }
        return keys.first { !session.isDone($0, in: protocols) } ?? ViewKey(region, first.name)
    }

    /// Whether an OCR read looks like a ring code rather than stray text (a reader's label, a
    /// sleeve print): a registry hit when a registry is loaded, otherwise at least two digits.
    public static func looksLikeRingCode(_ candidates: [String], registry: RingRegistry) -> Bool {
        if !registry.codes.isEmpty {
            return registry.bestMatch(candidates)?.confident == true
        }
        return candidates.contains { code in
            (3...12).contains(code.count) && code.filter(\.isNumber).count >= 2
        }
    }
}

/// How hard the camera may work at each device thermal state. Phones held in the sun overheat,
/// dim the screen and finally shut the camera off, so the app sheds work before iOS does.
public struct CameraLoad: Equatable, Sendable {
    public enum Heat: Int, Comparable, Sendable {
        case nominal, fair, serious, critical

        public static func < (a: Heat, b: Heat) -> Bool { a.rawValue < b.rawValue }
    }

    /// Preview frame rate.
    public var framesPerSecond: Int
    /// Run the live quality gate on every n-th preview frame.
    public var analyseEvery: Int
    /// Seconds between live ring OCR attempts.
    public var ringReadInterval: Double
    /// Stop the camera after this many seconds without a photo.
    public var idlePauseAfter: TimeInterval
    /// Highest-quality (multi-frame) still processing; costs heat per shot.
    public var bestStillQuality: Bool
    /// Start no new uploads (the radio adds heat).
    public var holdUploads: Bool
    /// Pause the camera as soon as the phone gets here (the operator can still resume briefly).
    public var paused: Bool

    public static func forHeat(_ heat: Heat) -> CameraLoad {
        switch heat {
        case .nominal, .fair:
            return CameraLoad(framesPerSecond: 24, analyseEvery: 4, ringReadInterval: 1.5, idlePauseAfter: 45,
                              bestStillQuality: true, holdUploads: false, paused: false)
        case .serious:
            return CameraLoad(framesPerSecond: 15, analyseEvery: 6, ringReadInterval: 3, idlePauseAfter: 20,
                              bestStillQuality: false, holdUploads: true, paused: false)
        case .critical:
            return CameraLoad(framesPerSecond: 15, analyseEvery: 6, ringReadInterval: 3, idlePauseAfter: 15,
                              bestStillQuality: false, holdUploads: true, paused: true)
        }
    }

    /// What to tell the operator, or nil when the phone is fine.
    public static func message(for heat: Heat) -> String? {
        switch heat {
        case .nominal, .fair: return nil
        case .serious: return "Phone is hot: camera slowed down. Keep it in shade between shots."
        case .critical: return "Phone is too hot: camera paused. Put it in shade for a few minutes."
        }
    }
}
