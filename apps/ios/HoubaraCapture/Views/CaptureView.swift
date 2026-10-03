import AVFoundation
import CaptureKit
import SwiftUI

/// Guided capture for one view of one region: live preview with a guide shape, the live quality
/// gate, auto-capture when the gate holds, and the shots taken so far.
struct CaptureView: View {
    let sessionId: String
    @State private var key: ViewKey

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var camera = CameraController()
    @State private var spectrum: Spectrum = .rgb
    @State private var busy = false
    @State private var flash = false
    @State private var feedback: String?
    @State private var classifierWarning: String?
    @State private var liveRing: RingMatch?
    @State private var ringReview: RingReview?
    @State private var ringReader = LiveRingReader()
    @State private var showingReference = false

    init(sessionId: String, initialKey: ViewKey) {
        self.sessionId = sessionId
        _key = State(initialValue: initialKey)
    }

    private var proto: RegionProtocol? { model.protocols[key.region] }
    private var viewSpec: ViewSpec? { proto?.views.first { $0.name == key.view } }
    private var thresholds: QualityThresholds { proto?.quality ?? QualityThresholds() }
    private var session: CaptureSession? { store.session(sessionId) }
    private var autoCaptureAllowed: Bool { settings.autoCapture && key.region != .other }

    private var nextKey: ViewKey? {
        session?.pending(model.protocols).first { $0 != key }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorization == .denied || camera.authorization == .restricted {
                permissionMessage
            } else {
                CameraPreview(camera: camera).ignoresSafeArea()
                GuideShape(circle: key.region == .iris)
                    .stroke(guideColor, lineWidth: 3)
                    .padding(40)
                    .aspectRatio(1, contentMode: .fit)
                    .allowsHitTesting(false)
            }
            if flash { Color.white.ignoresSafeArea().transition(.opacity) }
            VStack(spacing: 0) {
                instructions
                Spacer()
                controls
            }
        }
        .navigationTitle(key.region == .other ? "Extra photo" : key.region.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { cameraMenu }
        }
        .task { await camera.start() }
        .onAppear {
            camera.onAutoCapture = { take() }
            applyKey()
        }
        .onDisappear {
            camera.onAutoCapture = nil
            camera.setFrameObserver(nil)
            camera.stop()
        }
        .onChange(of: key) { applyKey() }
        .onChange(of: settings.autoCapture) { camera.setAutoCapture(autoCaptureAllowed) }
        .onChange(of: camera.current) { spectrum = defaultSpectrum }
        .sheet(isPresented: $showingReference) {
            if let viewSpec {
                BirdReferenceSheet(region: key.region, view: viewSpec)
            }
        }
        .sheet(item: $ringReview) { review in
            RingConfirmView(sessionId: sessionId, review: review)
        }
    }

    // MARK: Pieces

    private var guideColor: Color {
        guard let quality = camera.liveQuality else { return .white.opacity(0.7) }
        return quality.passed ? .green : .red
    }

    private var instructions: some View {
        HStack(alignment: .top, spacing: 10) {
            // The picture carries the instruction; the text is there for detail.
            Button {
                showingReference = true
            } label: {
                BirdReferenceView(region: key.region, view: key.view)
                    .frame(width: 130)
                    .padding(4)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(viewSpec == nil)
            .accessibilityHint("Shows a larger reference picture")
            VStack(alignment: .leading, spacing: 4) {
                Text(viewSpec?.title ?? "Any region").font(.headline)
                if let hint = viewSpec?.hint, !hint.isEmpty { Text(hint).font(.subheadline) }
                if let guidance = proto?.guidance, !guidance.isEmpty {
                    Text(guidance).font(.caption).foregroundStyle(.yellow)
                }
                if key.region == .other {
                    Text("Not tied to a checklist step; the server classifies it.").font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial)
        .foregroundStyle(.primary)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let quality = camera.liveQuality {
                Text(quality.passed ? "Ready" : quality.failures.map(Quality.advice).joined(separator: " · "))
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(quality.passed ? Color.green : Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            if key.region == .ring {
                Text(liveRingText).font(.callout.monospaced()).foregroundStyle(.white)
            }
            if let feedback {
                Text(feedback).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
            }
            if let classifierWarning {
                Text(classifierWarning).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }

            if camera.current?.isExternal == true {
                Picker("Spectrum", selection: $spectrum) {
                    Text("Visible").tag(Spectrum.rgb)
                    Text("Near-IR").tag(Spectrum.nir)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            HStack(alignment: .center) {
                shotStrip.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: take) {
                    ZStack {
                        Circle().fill(.white).frame(width: 68, height: 68)
                        Circle().stroke(.white, lineWidth: 3).frame(width: 80, height: 80)
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
                .accessibilityLabel("Take photo")
                VStack(spacing: 8) {
                    Toggle("Auto", isOn: $settings.autoCapture).labelsHidden()
                    Text("Auto").font(.caption2).foregroundStyle(.white)
                    if let next = nextKey, session?.isDone(key, in: model.protocols) == true {
                        Button("Next") { key = next }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let proto, key.region != .other {
                let passing = session?.passingCount(key) ?? 0
                Text("\(passing) of \(proto.minShotsPerView) good shots")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding()
        .background(.black.opacity(0.45))
    }

    private var shotStrip: some View {
        HStack(spacing: 6) {
            ForEach((session?.shots(for: key) ?? []).suffix(3)) { shot in
                ZStack(alignment: .bottomTrailing) {
                    ThumbnailView(url: store.imageURL(sessionId, shot), size: 46)
                    Image(systemName: shot.quality.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(shot.quality.passed ? Color.green : Color.red)
                        .background(Circle().fill(.white))
                        .font(.caption)
                }
                .contextMenu {
                    Button("Delete photo", role: .destructive) { store.deleteShot(shot, from: sessionId) }
                }
            }
        }
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(camera.options) { option in
                Button {
                    camera.select(option)
                } label: {
                    if option.id == camera.current?.id {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.isExternal ? "\(option.name) (USB)" : option.name)
                    }
                }
            }
        } label: {
            Image(systemName: "camera.on.rectangle")
        }
    }

    private var permissionMessage: some View {
        VStack(spacing: 12) {
            Text("Camera access is off").font(.headline)
            Text("Allow camera access for Houbara Capture in Settings.").font(.subheadline)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private var liveRingText: String {
        guard let match = liveRing else { return "Point at the ring code…" }
        let shown = match.code ?? RingRegistry.normalize(match.read)
        return "\(shown) · \(RingText.describe(match, registryEmpty: model.ringRegistry.codes.isEmpty))"
    }

    private var defaultSpectrum: Spectrum {
        // The USB-C camera recommended for iris work is near-IR; built-in cameras are visible light.
        camera.current?.isExternal == true ? .nir : .rgb
    }

    // MARK: Actions

    private func applyKey() {
        camera.setThresholds(thresholds)
        camera.setAutoCapture(autoCaptureAllowed)
        spectrum = defaultSpectrum
        feedback = nil
        classifierWarning = nil
        liveRing = nil
        if key.region == .ring {
            let reader = ringReader
            let registry = model.ringRegistry
            camera.setFrameObserver { buffer in
                reader.feed(buffer, registry: registry) { match in liveRing = match }
            }
        } else {
            camera.setFrameObserver(nil)
        }
    }

    private func take() {
        guard !busy, session != nil else { return }
        busy = true
        let key = key
        let spectrum = spectrum
        let thresholds = thresholds
        Task {
            defer { busy = false }
            do {
                let photo = try await camera.capture()
                withAnimation(.easeOut(duration: 0.15)) { flash = true }
                withAnimation(.easeIn(duration: 0.25).delay(0.15)) { flash = false }

                let data = photo.data
                let analysis = await Task.detached(priority: .userInitiated) {
                    StillAnalysis.analyse(data, thresholds: thresholds)
                }.value

                var label = RegionLabel(source: key.region == .other ? .unlabelled : .checklist)
                var warning: String?
                if let image = analysis.image {
                    let orientation = FrameConversion.orientation(of: data)
                    let guess = await Task.detached(priority: .userInitiated) {
                        RegionClassifier.shared.classify(image, orientation: orientation)
                    }.value
                    if let guess {
                        let (region, confidence) = guess
                        label.modelRegion = region
                        label.modelConfidence = confidence
                        if key.region == .other {
                            label.source = .model
                        } else if region != key.region, confidence >= 0.6 {
                            warning = "This looks like \(region.title) (\(Int(confidence * 100))%). Delete it if it was taken by mistake."
                        }
                    }
                }

                let shotId = newID()
                let fileName = try store.writeImage(data, sessionId: sessionId, shotId: shotId)
                let shot = Shot(
                    id: shotId, region: key.region, view: key.view, spectrum: spectrum, fileName: fileName,
                    width: analysis.width, height: analysis.height, quality: analysis.quality,
                    exposure: photo.exposure, label: label, cameraName: photo.cameraName
                )
                guard var current = store.session(sessionId) else { return }
                current.add(shot)
                store.save(current)

                feedback = analysis.quality.passed
                    ? "Good shot"
                    : "Kept, but: " + analysis.quality.failures.map(Quality.advice).joined(separator: ". ")
                classifierWarning = warning

                if key.region == .ring, current.ringRead?.match?.confident != true {
                    let candidates = await Task.detached(priority: .userInitiated) {
                        RingOCR.candidates(in: data)
                    }.value
                    ringReview = RingReview(shotId: shotId, candidates: candidates)
                }
            } catch {
                feedback = error.localizedDescription
            }
        }
    }
}

private struct GuideShape: Shape {
    let circle: Bool

    func path(in rect: CGRect) -> Path {
        circle ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 16)
    }
}
