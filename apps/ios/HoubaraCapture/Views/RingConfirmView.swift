import CaptureKit
import SwiftUI

struct RingReview: Identifiable {
    let id = UUID()
    /// The ring photo the reads came from; nil when the operator types the code.
    let shotId: String?
    let candidates: [String]
}

enum RingText {
    static func describe(_ match: RingMatch, registryEmpty: Bool) -> String {
        switch match.status {
        case .exact: return "In ring registry"
        case .fuzzy: return "Matches \(match.code ?? "") in registry"
        case .ambiguous: return "Matches several registered rings; check the code"
        case .unknown: return registryEmpty ? "No ring registry loaded" : "Not in registry (new ring or misread?)"
        case .invalidFormat: return "Doesn't look like a ring code"
        }
    }
}

/// The operator confirms or corrects the ring code. It becomes the session's ground-truth ID
/// candidate; the server re-reads the ring photo and flags disagreements for review.
struct RingConfirmView: View {
    let sessionId: String
    let review: RingReview
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var proposed: RingMatch?

    private var registryEmpty: Bool { model.ringRegistry.codes.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if review.shotId != nil && review.candidates.isEmpty {
                    Section {
                        Text("No code could be read from this photo. Type it in, or retake with the code facing the camera.")
                    }
                }
                if let proposed {
                    Section("Best read") {
                        LabeledContent(proposed.code ?? RingRegistry.normalize(proposed.read)) {
                            Text(RingText.describe(proposed, registryEmpty: registryEmpty))
                                .foregroundStyle(proposed.confident ? Color.green : Color.orange)
                        }
                        .font(.body.monospaced())
                    }
                }
                if review.candidates.count > 1 {
                    Section("Other reads") {
                        ForEach(review.candidates, id: \.self) { candidate in
                            Button(candidate) { code = candidate }.font(.body.monospaced())
                        }
                    }
                }
                Section {
                    TextField("e.g. HB1023", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title2.monospaced())
                    if !code.isEmpty {
                        let match = model.ringRegistry.match(code)
                        Text(RingText.describe(match, registryEmpty: registryEmpty))
                            .font(.caption).foregroundStyle(match.confident ? Color.green : Color.secondary)
                    }
                } header: {
                    Text("Ring code")
                }
            }
            .navigationTitle("Confirm ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(RingRegistry.normalize(code).isEmpty)
                }
            }
            .onAppear {
                proposed = model.ringRegistry.bestMatch(review.candidates)
                if let proposed {
                    code = proposed.code ?? RingRegistry.normalize(proposed.read)
                } else {
                    code = store.session(sessionId)?.ringRead?.code ?? ""
                }
            }
        }
    }

    private func save() {
        guard var session = store.session(sessionId) else { return dismiss() }
        let typed = RingRegistry.normalize(code)
        let match = model.ringRegistry.match(typed)
        let fromVision = review.candidates.contains(typed) || proposed?.code == typed
        session.ringRead = RingRead(
            code: match.confident ? (match.code ?? typed) : typed,
            match: match,
            source: fromVision ? "vision" : "manual",
            shotId: review.shotId
        )
        store.save(session)
        dismiss()
    }
}
