import CaptureKit
import SwiftUI

struct UploadsView: View {
    @EnvironmentObject private var uploader: Uploader
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let waiting = uploader.jobs.filter { $0.state != .done }
        let done = uploader.jobs.count - waiting.count
        List {
            Section {
                LabeledContent("Network", value: uploader.isOnline ? "Online" : "Offline")
                LabeledContent("Waiting", value: "\(waiting.count)")
                LabeledContent("Uploaded", value: "\(done)")
                if let error = uploader.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if settings.ingestClient == nil {
                    Text("No server address set. Photos are kept on the phone until one is added in Settings.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                Button("Retry now") { uploader.retryAll() }.disabled(waiting.isEmpty)
                Button("Clear uploaded from this list") { uploader.clearFinished() }.disabled(done == 0)
            }
            if !waiting.isEmpty {
                Section("Waiting") {
                    ForEach(waiting) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(job)).font(.subheadline)
                            Text(detail(job)).font(.caption).foregroundStyle(.secondary)
                            if let error = job.lastError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Uploads")
    }

    private func title(_ job: UploadJob) -> String {
        switch job.kind {
        case .manifest: return "Session summary (session.json)"
        case .image: return "\(job.region?.title ?? "Photo") · \(job.view ?? "")"
        }
    }

    private func detail(_ job: UploadJob) -> String {
        var parts = [job.state == .uploading ? "Uploading" : "Waiting"]
        if job.attempts > 0 { parts.append("attempt \(job.attempts)") }
        if let next = job.notBefore, next > Date() {
            parts.append("retry \(next.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
