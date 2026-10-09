import CaptureKit
import SwiftUI

enum Route: Hashable {
    case session(String)
    case capture(String, ViewKey)
    /// Free photographing: photos are sorted into body parts automatically.
    case photograph(String)
    case sort(String)
    case uploads
    case settings
}

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var uploader: Uploader
    @State private var path: [Route] = []
    @State private var showingNewSession = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !settings.isConfigured {
                    Section {
                        NavigationLink(value: Route.settings) {
                            Label("Set the site and server address before uploading", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Button {
                        showingNewSession = true
                    } label: {
                        Label("New bird session", systemImage: "plus.circle.fill").font(.headline)
                    }
                }
                let open = store.sessions.filter { !$0.isFinished }
                if !open.isEmpty {
                    Section("In progress") {
                        ForEach(open) { row($0) }
                    }
                }
                let finished = store.sessions.filter(\.isFinished)
                if !finished.isEmpty {
                    Section("Finished") {
                        ForEach(finished) { session in
                            row(session).deleteDisabled(waitingUploads(session) > 0)
                        }
                        .onDelete { offsets in
                            offsets.map { finished[$0] }.forEach { store.delete($0) }
                        }
                    }
                }
            }
            .navigationTitle("Houbara Capture")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.uploads) {
                        Label("\(uploader.pendingCount)", systemImage: uploader.pendingCount == 0 ? "icloud" : "icloud.and.arrow.up")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .session(id): SessionView(sessionId: id, path: $path)
                case let .capture(id, key): CaptureView(sessionId: id, initialKey: key)
                case let .photograph(id): PhotographView(sessionId: id)
                case let .sort(id): SortPhotosView(sessionId: id)
                case .uploads: UploadsView()
                case .settings: SettingsView()
                }
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionView { session in
                    showingNewSession = false
                    path.append(.session(session.id))
                }
            }
        }
    }

    private func waitingUploads(_ session: CaptureSession) -> Int {
        uploader.jobs.filter { $0.sessionId == session.id && $0.state != .done }.count
    }

    private func row(_ session: CaptureSession) -> some View {
        NavigationLink(value: Route.session(session.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.ringRead?.code ?? "Unidentified bird").font(.headline.monospaced())
                Text("\(session.site) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(session.shots.count) photos")
                    if session.isFinished {
                        let waiting = waitingUploads(session)
                        Text(waiting == 0 ? "· uploaded" : "· \(waiting) to upload")
                            .foregroundStyle(waiting == 0 ? Color.green : Color.orange)
                    }
                }
                .font(.caption)
            }
        }
    }
}

struct NewSessionView: View {
    let onStart: (CaptureSession) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var context: CaptureContext = .handling
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Where and who") {
                    TextField("Site (e.g. breeding-centre-1)", text: $settings.site)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Operator", text: $settings.operatorName)
                }
                Section("Bird") {
                    Picker("Situation", selection: $context) {
                        Text("In hand").tag(CaptureContext.handling)
                        Text("Aviary").tag(CaptureContext.aviary)
                        Text("Free").tag(CaptureContext.free)
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                }
                Section {
                    Text("Photograph the parts in any order; each photo is sorted into a body part for you, and you can check the sorting after the bird is released. A clear leg ring photo identifies the bird. Keep handling short; the photos taken so far are always kept.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New bird")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { onStart(model.startSession(context: context, notes: notes)) }
                        .disabled(keySegment(settings.site).isEmpty)
                }
            }
            .onAppear { model.location.refresh() }
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    var size: CGFloat = 44
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { image = await Thumbnails.load(url) }
    }
}
