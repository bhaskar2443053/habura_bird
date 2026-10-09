import CaptureKit
import SwiftUI

/// One checklist view and its spec, in checklist order: the choices when sorting photos.
struct PartChoice: Identifiable, Hashable {
    let key: ViewKey
    let title: String
    let required: Bool
    var id: ViewKey { key }

    static func all(_ protocols: ProtocolSet) -> [PartChoice] {
        protocols.regions.flatMap { proto in
            proto.views.map { view in
                let title = proto.views.count > 1 ? "\(proto.region.title): \(view.title)" : proto.region.title
                return PartChoice(key: ViewKey(proto.region, view.name), title: title, required: proto.required)
            }
        }
    }

    static func title(_ key: ViewKey, _ protocols: ProtocolSet) -> String {
        all(protocols).first { $0.key == key }?.title ?? (key.region == .other ? "Other" : key.region.title)
    }
}

/// After the bird is released: every photo under the body part it was sorted into. Tap a photo to
/// move it; "All correct" accepts the automatic sorting.
struct SortPhotosView: View {
    let sessionId: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @State private var editing: Shot?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        if let session = store.session(sessionId) {
            content(session)
        } else {
            ContentUnavailableView("Session not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ session: CaptureSession) -> some View {
        let toCheck = session.shotsToCheck.count
        let groups = groups(session)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if toCheck > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(toCheck) photos were sorted automatically. Tap any photo that is in the wrong place to move it.")
                            .font(.subheadline)
                        Button {
                            var updated = session
                            updated.confirmSuggestions()
                            store.save(updated)
                        } label: {
                            Label("All correct", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
                if groups.isEmpty {
                    Text("No photos yet.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0) { key, shots in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if key.region != .other {
                                BirdReferenceView(region: key.region, view: key.view, showsCameraHint: false)
                                    .frame(width: 48)
                            }
                            Text(PartChoice.title(key, model.protocols)).font(.headline)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(shots) { shot in
                                Button { editing = shot } label: { tile(shot) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Sort photos")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { shot in
            MovePhotoSheet(sessionId: sessionId, shot: shot)
        }
    }

    private func tile(_ shot: Shot) -> some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailView(url: store.imageURL(sessionId, shot), size: 96)
            if shot.label.source == .suggested {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.white, .orange)
                    .font(.title3)
                    .padding(4)
                    .accessibilityLabel("Sorted automatically")
            }
            if !shot.quality.passed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: 96, height: 96)
    }

    /// Photos grouped by view in checklist order, extra photos last.
    private func groups(_ session: CaptureSession) -> [(ViewKey, [Shot])] {
        var order = PartChoice.all(model.protocols).map(\.key)
        for shot in session.shots where !order.contains(ViewKey(shot.region, shot.view)) {
            order.append(ViewKey(shot.region, shot.view))
        }
        return order.compactMap { key in
            let shots = session.shots(for: key)
            return shots.isEmpty ? nil : (key, shots)
        }
    }
}

/// A larger look at one photo and the body parts it can be moved to.
struct MovePhotoSheet: View {
    let sessionId: String
    let shot: Shot
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var ringReview: RingReview?
    @State private var reading = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            Color.secondary.opacity(0.2).aspectRatio(4 / 3, contentMode: .fit)
                        }
                    }
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if shot.region == .ring {
                        Button {
                            readRing()
                        } label: {
                            Label(reading ? "Reading…" : "Read the ring code from this photo", systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .disabled(reading)
                    }

                    Text("This photo shows:").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(PartChoice.all(model.protocols)) { choice in
                            Button { move(to: choice.key) } label: { chip(choice) }
                                .buttonStyle(.plain)
                        }
                        Button { move(to: ViewKey(.other, "adhoc")) } label: {
                            chip(PartChoice(key: ViewKey(.other, "adhoc"), title: "Something else", required: false))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Delete this photo", role: .destructive) {
                        store.deleteShot(shot, from: sessionId)
                        dismiss()
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle(PartChoice.title(ViewKey(shot.region, shot.view), model.protocols))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Correct") {
                        move(to: ViewKey(shot.region, shot.view))
                    }
                }
            }
            .task { image = await Thumbnails.load(store.imageURL(sessionId, shot), maxPixel: 1200) }
            .sheet(item: $ringReview) { review in
                RingConfirmView(sessionId: sessionId, review: review)
            }
        }
    }

    private func chip(_ choice: PartChoice) -> some View {
        let current = choice.key == ViewKey(shot.region, shot.view)
        return VStack(spacing: 4) {
            if choice.key.region == .other {
                Image(systemName: "photo").font(.title).frame(height: 56)
            } else {
                BirdReferenceView(region: choice.key.region, view: choice.key.view, showsCameraHint: false)
                    .frame(height: 56)
            }
            Text(choice.title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(6)
        .background(current ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(current ? Color.orange : .clear, lineWidth: 2))
    }

    private func move(to key: ViewKey) {
        guard var session = store.session(sessionId) else { return dismiss() }
        session.relabel(shotId: shot.id, to: key)
        store.save(session)
        dismiss()
    }

    private func readRing() {
        reading = true
        let url = store.imageURL(sessionId, shot)
        let shotId = shot.id
        Task {
            let candidates = await Task.detached(priority: .userInitiated) { () -> [String] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return RingOCR.candidates(in: data)
            }.value
            reading = false
            ringReview = RingReview(shotId: shotId, candidates: candidates)
        }
    }
}
