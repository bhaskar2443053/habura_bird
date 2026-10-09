import CaptureKit
import Foundation
import UIKit

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Base URL of the ingest API (`birdreid.api.app`), e.g. https://reid.example.org
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    /// Optional bearer token, for when the API sits behind an authenticating gateway.
    @Published var apiKey: String { didSet { defaults.set(apiKey, forKey: "apiKey") } }
    @Published var site: String { didSet { defaults.set(site, forKey: "site") } }
    @Published var operatorName: String { didSet { defaults.set(operatorName, forKey: "operatorName") } }
    @Published var autoCapture: Bool { didSet { defaults.set(autoCapture, forKey: "autoCapture") } }

    let deviceId: String

    init() {
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        site = defaults.string(forKey: "site") ?? ""
        operatorName = defaults.string(forKey: "operatorName") ?? ""
        autoCapture = defaults.object(forKey: "autoCapture") as? Bool ?? true
        if let saved = defaults.string(forKey: "deviceId") {
            deviceId = saved
        } else {
            let id = "iphone-" + newID().prefix(12)
            defaults.set(id, forKey: "deviceId")
            deviceId = id
        }
    }

    var isConfigured: Bool { ingestClient != nil && !site.trimmingCharacters(in: .whitespaces).isEmpty }

    var ingestClient: IngestClient? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        return IngestClient(baseURL: url, apiKey: apiKey.isEmpty ? nil : apiKey)
    }

    /// Hardware model such as "iPhone16,1", recorded with every session for provenance.
    static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }()
}
