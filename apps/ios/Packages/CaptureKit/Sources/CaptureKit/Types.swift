import Foundation

/// Body regions (and the leg ring) a photo belongs to. Raw values match `birdreid.types.Region`.
public enum Region: String, Codable, CaseIterable, Sendable {
    case iris
    case face
    case beak
    case plumageDorsal = "plumage_dorsal"
    case plumageVentral = "plumage_ventral"
    case wing
    case tail
    case feet
    case ring
    case other

    public var title: String {
        switch self {
        case .iris: return "Iris"
        case .face: return "Face"
        case .beak: return "Beak"
        case .plumageDorsal: return "Back plumage"
        case .plumageVentral: return "Breast plumage"
        case .wing: return "Wing"
        case .tail: return "Tail"
        case .feet: return "Feet"
        case .ring: return "Leg ring"
        case .other: return "Other"
        }
    }
}

/// Raw values match `birdreid.types.Spectrum`.
public enum Spectrum: String, Codable, CaseIterable, Sendable {
    case rgb
    case nir
    case rgbNir = "rgb+nir"
}

/// How the bird was being held or observed during the session.
public enum CaptureContext: String, Codable, CaseIterable, Sendable {
    case handling
    case aviary
    case free
}

/// Lower-case 32-hex-character id, the same shape as Python's `uuid4().hex`.
public func newID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// Sanitises user-typed names (site, operator) into a safe object-key segment.
public func keySegment(_ text: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    let mapped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .map { allowed.contains($0) ? $0 : "-" }
    return String(String(mapped).prefix(64))
}
