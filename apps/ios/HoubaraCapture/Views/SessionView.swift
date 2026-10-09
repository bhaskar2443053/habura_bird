import CaptureKit
import SwiftUI

/// The region checklist for one bird.
struct SessionView: View {
    let sessionId: String
    @Binding var path: [Route]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @State private var skipping: ViewKey?
    @State private var skipReason = ""
    @State private var confirmingFinish = false
    @State private var typingRing = false
    @State private var errorMessage: String?

    var body: some View {
        if let session = store.session(sessionId) {
            content(session)
        } else {
            ContentUnavailableView("Session not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ session: CaptureSession) -> some View {
        let pending = session.pending(model.protocols)
        let toCheck = session.shotsToCheck.count
        return List {
            Section {
                NavigationLink(value: Route.photograph(session.id)) {
                    Label("Photograph bird", systemImage: "camera.fill").font(.headline)
                }
                if !session.shots.isEmpty {
                    NavigationLink(value: Route.sort(session.id)) {
                        LabeledContent {
                            if toCheck > 0 {
                                Text("\(toCheck) to check").foregroundStyle(.orange)
                            } else {
                                Text("\(session.shots.count)")
                            }
                        } label: {
                            Label("See, sort and share photos", systemImage: "square.grid.2x2")
                        }
                    }
                }
            } footer: {
                Text("Take photos in any order without coming back here; they're sorted into body parts for you. Tap a part below to photograph only that part.")
            }

            Section("Bird") {
                if let ring = session.ringRead {
                    LabeledContent("Ring") {
                        VStack(alignment: .trailing) {
                            Text(ring.code).font(.headline.monospaced())
                            if let match = ring.match {
                                Text(RingText.describe(match, registryEmpty: model.ringRegistry.codes.isEmpty))
                                    .font(.caption).foregroundStyle(match.confident ? Color.green : Color.orange)
                            }
                        }
                    }
                } else {
                    Text("Ring not read yet").foregroundStyle(.secondary)
                }
                Button("Type the ring code") { typingRing = true }
                if !pending.isEmpty {
                    Text("\(pending.count) views left").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(model.protocols.regions, id: \.region) { proto in
                Section {
                    ForEach(proto.views, id: \.name) { view in
                        viewRow(session, proto, view)
                    }
                } header: {
                    Text(proto.required ? proto.region.title : "\(proto.region.title) (optional)")
                } footer: {
                    if !proto.guidance.isEmpty { Text(proto.guidance) }
                }
            }

            Section("Extra photos") {
                let key = ViewKey(.other, "adhoc")
                NavigationLink(value: Route.capture(session.id, key)) {
                    LabeledContent("Anything else worth keeping", value: "\(session.shots(for: key).count)")
                }
            }

            Section {
                Button {
                    if pending.isEmpty { finish(session) } else { confirmingFinish = true }
                } label: {
                    Label(session.isFinished ? "Upload changes" : "Finish and upload", systemImage: "icloud.and.arrow.up")
                        .font(.headline)
                }
                .disabled(session.shots.isEmpty)
            } footer: {
                Text("Photos stay on this phone until they reach cloud storage, so it is fine to finish without signal.")
            }
        }
        .navigationTitle(session.ringRead?.code ?? "New bird")
        .alert("Skip this view?", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } })) {
            TextField("Reason (e.g. bird stressed)", text: $skipReason)
            Button("Skip") {
                if let key = skipping {
                    var updated = session
                    updated.skip(key, reason: skipReason.isEmpty ? "skipped" : skipReason)
                    store.save(updated)
                }
                skipReason = ""
            }
            Button("Cancel", role: .cancel) { skipReason = "" }
        }
        .confirmationDialog(
            "\(pending.count) views aren't captured yet. Finish anyway?",
            isPresented: $confirmingFinish, titleVisibility: .visible
        ) {
            Button("Finish; record them as not captured") { finish(session) }
            Button("Keep capturing", role: .cancel) {}
        }
        .alert("Couldn't finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $typingRing) {
            RingConfirmView(sessionId: session.id, review: RingReview(shotId: nil, candidates: []))
        }
    }

    private func viewRow(_ session: CaptureSession, _ proto: RegionProtocol, _ view: ViewSpec) -> some View {
        let key = ViewKey(proto.region, view.name)
        let passing = session.passingCount(key)
        let taken = session.shots(for: key).count
        let skipped = session.skipped.first { $0.region == key.region && $0.view == key.view }
        let done = session.isDone(key, in: model.protocols)
        return NavigationLink(value: Route.capture(session.id, key)) {
            HStack {
                Image(systemName: skipped != nil ? "forward.circle" : done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(skipped != nil ? Color.orange : done ? Color.green : Color.secondary)
                BirdReferenceView(region: proto.region, view: view.name, showsCameraHint: false)
                    .frame(width: 56)
                VStack(alignment: .leading) {
                    Text(view.title)
                    Group {
                        if let skipped {
                            Text("Skipped: \(skipped.reason)")
                        } else {
                            Text("\(passing)/\(proto.minShotsPerView) good" + (taken > passing ? " · \(taken) taken" : ""))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let best = session.best(key) {
                    ThumbnailView(url: store.imageURL(session.id, best))
                }
            }
        }
        .swipeActions {
            if skipped != nil {
                Button("Unskip") {
                    var updated = session
                    updated.unskip(key)
                    store.save(updated)
                }
            } else {
                Button("Skip") { skipping = key }.tint(.orange)
            }
        }
    }

    private func finish(_ session: CaptureSession) {
        Task {
            do {
                try await model.finish(session)
                path.removeAll()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
