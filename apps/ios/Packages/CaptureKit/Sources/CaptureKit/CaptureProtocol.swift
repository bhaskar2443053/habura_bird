import Foundation

/// One view of a region, e.g. `left_eye`. Mirrors `birdreid.capture.protocol.ViewSpec`.
public struct ViewSpec: Codable, Hashable, Sendable {
    public var name: String
    public var hint: String

    public init(name: String, hint: String = "") {
        self.name = name
        self.hint = hint
    }

    /// "left_eye" → "Bird's left eye": left and right are always the bird's own, not the
    /// photographer's (field sessions had every eye photo swapped).
    public var title: String {
        let words = name.split(separator: "_").map(String.init)
        guard let first = words.first else { return name }
        if first == "left" || first == "right" {
            return (["Bird's", first] + words.dropFirst()).joined(separator: " ")
        }
        return words.joined(separator: " ").capitalized
    }

    /// The same view on the bird's other side (`left_eye` ↔ `right_eye`), if the name has a side.
    public var mirroredName: String? {
        if name.hasPrefix("left_") { return "right_" + name.dropFirst(5) }
        if name.hasPrefix("right_") { return "left_" + name.dropFirst(6) }
        return nil
    }
}

/// Mirrors `birdreid.capture.protocol.QualityThresholds`.
public struct QualityThresholds: Codable, Hashable, Sendable {
    public var minSharpness: Double
    public var maxGlareRatio: Double
    public var minBrightness: Double
    public var maxBrightness: Double
    public var minShortSidePx: Int

    enum CodingKeys: String, CodingKey {
        case minSharpness = "min_sharpness"
        case maxGlareRatio = "max_glare_ratio"
        case minBrightness = "min_brightness"
        case maxBrightness = "max_brightness"
        case minShortSidePx = "min_short_side_px"
    }

    public init(
        minSharpness: Double = 50, maxGlareRatio: Double = 0.10, minBrightness: Double = 30,
        maxBrightness: Double = 225, minShortSidePx: Int = 256
    ) {
        self.minSharpness = minSharpness
        self.maxGlareRatio = maxGlareRatio
        self.minBrightness = minBrightness
        self.maxBrightness = maxBrightness
        self.minShortSidePx = minShortSidePx
    }
}

/// Capture protocol for one region. Mirrors `birdreid.capture.protocol.RegionProtocol`.
public struct RegionProtocol: Codable, Hashable, Sendable {
    public var region: Region
    public var spectra: [Spectrum]
    public var views: [ViewSpec]
    public var minShotsPerView: Int
    public var required: Bool
    public var quality: QualityThresholds
    public var guidance: String

    enum CodingKeys: String, CodingKey {
        case region, spectra, views, required, quality, guidance
        case minShotsPerView = "min_shots_per_view"
    }

    public init(
        region: Region, spectra: [Spectrum] = [.rgb], views: [ViewSpec], minShotsPerView: Int = 1,
        required: Bool = true, quality: QualityThresholds = QualityThresholds(), guidance: String = ""
    ) {
        self.region = region
        self.spectra = spectra
        self.views = views
        self.minShotsPerView = minShotsPerView
        self.required = required
        self.quality = quality
        self.guidance = guidance
    }
}

/// The bundled checklist, exported from `configs/protocols/*.yaml` by `scripts/export_protocols.py`.
public struct ProtocolSet: Codable, Hashable, Sendable {
    public var version: Int
    public var regions: [RegionProtocol]

    public init(version: Int, regions: [RegionProtocol]) {
        self.version = version
        self.regions = regions
    }

    public static func load(from data: Data) throws -> ProtocolSet {
        try JSONDecoder().decode(ProtocolSet.self, from: data)
    }

    public subscript(region: Region) -> RegionProtocol? {
        regions.first { $0.region == region }
    }
}
