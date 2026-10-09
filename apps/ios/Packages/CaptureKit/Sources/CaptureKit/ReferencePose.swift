import Foundation

/// What the reference diagram on a capture step shows: which part of the bird to photograph,
/// which side of the bird faces the camera, and where to hold the phone.
public struct ReferencePose: Hashable, Sendable {
    public enum Part: String, CaseIterable, Sendable {
        case ring, head, eye, beak, feet, back, breast, wing, tail, wholeBird
    }

    /// Where the phone is relative to the bird. `side` means the diagram itself is the view.
    public enum Camera: String, Sendable {
        case side, above, below, front
    }

    public var part: Part
    /// The diagram is drawn showing the bird's left side; true flips it to show the right side.
    public var mirrored: Bool
    public var camera: Camera
    /// Close-up subjects (eye, ring) get a magnified inset.
    public var closeUp: Bool

    public init(part: Part, mirrored: Bool = false, camera: Camera = .side, closeUp: Bool = false) {
        self.part = part
        self.mirrored = mirrored
        self.camera = camera
        self.closeUp = closeUp
    }

    /// Derived from the region and the view name in the protocol YAML, so new views
    /// (e.g. `right_plantar`) get a sensible picture without code changes.
    public static func pose(region: Region, view: String) -> ReferencePose {
        let name = view.lowercased()
        let mirrored = name.contains("right")
        let camera: Camera
        if name.contains("plantar") {
            camera = .below
        } else if name.contains("dorsal") || name == "back" {
            camera = .above
        } else if name.contains("frontal") || name == "breast" {
            camera = .front
        } else {
            camera = .side
        }
        switch region {
        case .ring: return ReferencePose(part: .ring, mirrored: mirrored, camera: camera, closeUp: true)
        case .iris: return ReferencePose(part: .eye, mirrored: mirrored, camera: camera, closeUp: true)
        case .face: return ReferencePose(part: .head, mirrored: mirrored, camera: camera)
        case .beak: return ReferencePose(part: .beak, mirrored: mirrored, camera: camera)
        case .feet: return ReferencePose(part: .feet, mirrored: mirrored, camera: camera)
        case .plumageDorsal: return ReferencePose(part: .back, mirrored: mirrored, camera: camera == .side ? .above : camera)
        case .plumageVentral: return ReferencePose(part: .breast, mirrored: mirrored, camera: camera == .side ? .front : camera)
        case .wing: return ReferencePose(part: .wing, mirrored: mirrored, camera: camera)
        case .tail: return ReferencePose(part: .tail, mirrored: mirrored, camera: camera)
        case .other: return ReferencePose(part: .wholeBird, mirrored: mirrored, camera: camera)
        }
    }
}
