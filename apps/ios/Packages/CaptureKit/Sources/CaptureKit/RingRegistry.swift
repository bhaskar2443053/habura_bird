import Foundation

/// Validates OCR'd ring codes against the site's ring registry.
/// Port of `birdreid.ocr.registry`; keep the two in step.
public struct RingMatch: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case exact, fuzzy, ambiguous, unknown
        case invalidFormat = "invalid_format"
    }

    public var read: String
    public var code: String?
    public var distance: Int
    public var status: Status

    public var confident: Bool { status == .exact || status == .fuzzy }
}

public struct RingRegistry: Sendable {
    public let codes: Set<String>
    public let pattern: String
    public let maxDistance: Int
    private let byCanonical: [String: Set<String>]

    /// - Parameter pattern: the site's ring code format (placeholder until confirmed).
    public init(codes: [String], pattern: String = "^[A-Z0-9]{3,10}$", maxDistance: Int = 1) {
        let normalized = Set(codes.map(RingRegistry.normalize).filter { !$0.isEmpty })
        var byCanonical: [String: Set<String>] = [:]
        for code in normalized {
            byCanonical[RingRegistry.canonical(code), default: []].insert(code)
        }
        self.codes = normalized
        self.pattern = pattern
        self.maxDistance = maxDistance
        self.byCanonical = byCanonical
    }

    /// Parses a pasted list or CSV export: one code per line, taken from the first column.
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let first = line.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
            let code = normalize(first)
            return code.isEmpty ? nil : code
        }
    }

    private static let letters: ClosedRange<Character> = "A"..."Z"
    private static let digits: ClosedRange<Character> = "0"..."9"

    public static func normalize(_ code: String) -> String {
        String(code.uppercased().filter { letters.contains($0) || digits.contains($0) })
    }

    /// Characters OCR commonly confuses on engraved rings, mapped to a canonical form.
    static let confusable: [Character: Character] = [
        "O": "0", "Q": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8",
    ]

    static func canonical(_ code: String) -> String {
        String(normalize(code).map { confusable[$0] ?? $0 })
    }

    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i]
            for j in 1...b.count {
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    public func validFormat(_ code: String) -> Bool {
        normalize(code).range(of: pattern, options: .regularExpression) != nil
    }

    private func normalize(_ code: String) -> String { RingRegistry.normalize(code) }

    public func match(_ read: String) -> RingMatch {
        let code = normalize(read)
        guard validFormat(code) else {
            return RingMatch(read: read, code: nil, distance: -1, status: .invalidFormat)
        }
        if codes.contains(code) {
            return RingMatch(read: read, code: code, distance: 0, status: .exact)
        }
        let canon = RingRegistry.canonical(code)
        if let same = byCanonical[canon], same.count == 1, let only = same.first {
            return RingMatch(read: read, code: only, distance: 0, status: .fuzzy)
        }
        let scored = codes
            .map { (RingRegistry.editDistance(canon, RingRegistry.canonical($0)), $0) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let close = scored.filter { $0.0 <= maxDistance }
        guard let best = close.first else {
            return RingMatch(read: read, code: nil, distance: scored.first?.0 ?? -1, status: .unknown)
        }
        if close.count > 1 && close[1].0 == best.0 {
            return RingMatch(read: read, code: nil, distance: best.0, status: .ambiguous)
        }
        return RingMatch(read: read, code: best.1, distance: best.0, status: .fuzzy)
    }

    /// Best match among several OCR candidate strings (e.g. Vision's top-N for each line).
    /// With an empty registry, returns the first well-formed read with status `unknown`.
    public func bestMatch(_ candidates: [String]) -> RingMatch? {
        let rank: [RingMatch.Status: Int] = [.exact: 0, .fuzzy: 1, .ambiguous: 2, .unknown: 3, .invalidFormat: 4]
        return candidates.map(match).min { a, b in
            let ra = rank[a.status]!, rb = rank[b.status]!
            return ra != rb ? ra < rb : a.distance < b.distance
        }
    }
}
