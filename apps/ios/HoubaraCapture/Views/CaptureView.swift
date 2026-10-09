import AVFoundation
import CaptureKit
import SwiftUI

/// Camera screen. Free mode (the default from the session screen) photographs the whole bird
/// without stopping: each photo is sorted into a body part automatically and the highlighted part
/// moves on by itself, so nobody has to go back to the checklist while holding the bird. Guided
/// mode (a checklist row) stays on one view. Both show the live quality gate, auto-capture and
/// the camera slows down or pauses when the phone gets hot or sits idle.
struct CaptureView: View {
    let sessionId: String
    /// Sort photos automatically and walk through the checklist on its own.
    let free: Bool
    /// In free mode: the part highlighted as the one being photographed now.
    @State private var key: ViewKey

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heat: HeatMonitor
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
    @State private var lastSortedId: String?
    @State private var moving: Shot?
    @State private var paused = false
    @State private var lastActivity = Date()

    init(sessionId: String, initialKey: ViewKey, free: Bool = false) {
        self.sessionId = sessionId
        self.free = free
        _key = State(initialValue: initialKey)
    }

    private var proto: RegionProtocol? { model.protocols[key.region] }
    private var viewSpec: ViewSpec? { proto?.views.first { $0.name == key.view } }
    private var thresholds: QualityThresholds { proto?.quality ?? QualityThresholds() }
    private var session: CaptureSession? { store.session(sessionId) }
    private var autoCaptureAllowed: Bool { settings.autoCapture && key.region != .other }
    private var load: CameraLoad { heat.load }

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
                if free { partStrip }
                instructions
                if let message = CameraLoad.message(for: heat.heat) {
                    Label(message, systemImage: "thermometer.sun.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(heat.heat == .critical ? Color.red : Color.orange)
                        .foregroundStyle(.white)
                }
                Spacer()
                controls
            }
            if paused { pausedOverlay }
        }
        .simultaneousGesture(TapGesture().onEnded { lastActivity = Date() })
        .navigationTitle(free ? "Photograph bird" : key.region == .other ? "Extra photo" : key.region.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { cameraMenu }
        }
        .task { await resume() }
        .task(id: paused) { await watchIdle() }
        .onAppear {
            camera.onAutoCapture = { take() }
            camera.setLoad(load)
            ringReader.setInterval(load.ringReadInterval)
            applyKey()
        }
        .onDisappear {
            camera.onAutoCapture = nil
            camera.setFrameObserver(nil)
            camera.stop()
        }
        .onChange(of: key) { applyKey() }
        .onChange(of: heat.heat) {
            camera.setLoad(load)
            ringReader.setInterval(load.ringReadInterval)
            if load.paused { pause() }
        }
        .sheet(item: $moving) { shot in
            MovePhotoSheet(sessionId: sessionId, shot: shot)
        }
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
                    .frame(width: free ? 90 : 130)
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

    /// Every checklist view as a picture chip; the highlighted one is what the next photo is
    /// sorted into unless the photo itself says otherwise. Tap to jump.
    private var partStrip: some View {
        let session = session
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PartChoice.all(model.protocols)) { choice in
                        let done = session?.isDone(choice.key, in: model.protocols) == true
                        let count = session?.shots(for: choice.key).count ?? 0
                        Button {
                            key = choice.key
                            lastActivity = Date()
                        } label: {
                            VStack(spacing: 2) {
                                BirdReferenceView(region: choice.key.region, view: choice.key.view, showsCameraHint: false)
                                    .frame(width: 58, height: 44)
                                HStack(spacing: 2) {
                                    if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    Text(count > 0 ? "\(count)" : " ").monospacedDigit()
                                }
                                .font(.caption2)
                            }
                            .padding(4)
                            .background(Color.white.opacity(choice.key == key ? 0.95 : 0.6), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(choice.key == key ? Color.orange : .clear, lineWidth: 3))
                            .foregroundStyle(.black)
                        }
                        .id(choice.key)
                        .accessibilityLabel(choice.title + (done ? ", done" : ""))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(.black.opacity(0.5))
            .onChange(of: key) { withAnimation { proxy.scrollTo(key, anchor: .center) } }
            .onAppear { proxy.scrollTo(key, anchor: .center) }
        }
    }

    private var pausedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: heat.heat >= .serious ? "thermometer.sun.fill" : "pause.circle")
                .font(.system(size: 48))
            Text(heat.heat == .critical ? "Phone is too hot" : "Camera paused")
                .font(.title3.weight(.semibold))
            Text(heat.heat == .critical
                 ? "Put the phone in shade for a few minutes. Photos taken so far are saved."
                 : "Paused to keep the phone cool while no photos are being taken.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
            Button {
                Task { await resume() }
            } label: {
                Label(heat.heat == .critical ? "Use camera anyway" : "Continue", systemImage: "camera.fill")
                    .font(.headline)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
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
            if free, let lastSorted = session?.shots.first(where: { $0.id == lastSortedId }) {
                Button {
                    moving = lastSorted
                } label: {
                    HStack(spacing: 8) {
                        ThumbnailView(url: store.imageURL(sessionId, lastSorted), size: 34)
                        Text("Saved as \(PartChoice.title(ViewKey(lastSorted.region, lastSorted.view), model.protocols))")
                        Text("Change").underline()
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                }
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
                    if !free, let next = nextKey, session?.isDone(key, in: model.protocols) == true {
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

    // MARK: Heat and idle

    private func resume() async {
        lastActivity = Date()
        paused = false
        await camera.start()
    }

    private func pause() {
        guard !paused else { return }
        paused = true
        camera.stop()
    }

    /// The camera is the main heat source: stop it when nothing has been photographed or tapped
    /// for a while (the bird is being handled, ringed or measured).
    private func watchIdle() async {
        while !paused, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if busy || ringReview != nil || moving != nil || showingReference {
                lastActivity = Date()
            } else if Date().timeIntervalSince(lastActivity) >= load.idlePauseAfter {
                pause()
            }
        }
    }

    private func take() {
        guard !busy, !paused, session != nil else { return }
        busy = true
        lastActivity = Date()
        let target = key
        let free = free
        let spectrum = spectrum
        let thresholds = thresholds
        let registry = model.ringRegistry
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

                var label = RegionLabel(source: free ? .suggested : target.region == .other ? .unlabelled : .checklist)
                var warning: String?
                var guess: (Region, Double)?
                if let image = analysis.image {
                    let orientation = FrameConversion.orientation(of: data)
                    guess = await Task.detached(priority: .userInitiated) {
                        RegionClassifier.shared.classify(image, orientation: orientation)
                    }.value
                    if let guess {
                        let (region, confidence) = guess
                        label.modelRegion = region
                        label.modelConfidence = confidence
                        if !free, target.region == .other {
                            label.source = .model
                        } else if !free, region != target.region, confidence >= RegionSuggester.modelThreshold {
                            warning = "This looks like \(region.title) (\(Int(confidence * 100))%). Delete it if it was taken by mistake."
                        }
                    }
                }

                // Free mode: a ring code in the photo means it's the ring photo, whatever part is
                // highlighted.
                var key = target
                if free, let before = store.session(sessionId) {
                    var ringSeen = false
                    if target.region != .ring {
                        let reads = await Task.detached(priority: .userInitiated) {
                            RingOCR.quickCandidates(in: data)
                        }.value
                        ringSeen = RegionSuggester.looksLikeRingCode(reads, registry: registry)
                    }
                    key = RegionSuggester.suggest(
                        target: target, ringCodeSeen: ringSeen, model: guess, session: before, protocols: model.protocols
                    )
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

                if free {
                    lastSortedId = shot.id
                    // Move on once the highlighted part has enough good photos.
                    if current.isDone(target, in: model.protocols) {
                        if let next = current.nextPending(after: target, in: model.protocols) {
                            self.key = next
                        } else {
                            feedback = "Every part has a good photo. Go back to finish, or keep shooting."
                        }
                    }
                }

                if key.region == .ring, current.ringRead?.match?.confident != true {
                    let candidates = await Task.detached(priority: .userInitiated) {
                        RingOCR.candidates(in: data)
                    }.value
                    if free {
                        // Don't interrupt the handling: take a confident registry read silently,
                        // otherwise the code is confirmed later on the sorting screen.
                        if let match = registry.bestMatch(candidates), match.confident, let code = match.code,
                           var latest = store.session(sessionId) {
                            latest.ringRead = RingRead(code: code, match: match, source: "vision", shotId: shotId)
                            store.save(latest)
                            feedback = "Ring \(code) read"
                        }
                    } else {
                        ringReview = RingReview(shotId: shotId, candidates: candidates)
                    }
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

/// Free photographing, starting at the first part that still needs photos.
struct PhotographView: View {
    let sessionId: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        CaptureView(sessionId: sessionId, initialKey: start, free: true)
    }

    private var start: ViewKey {
        let session = store.session(sessionId)
        return session?.pending(model.protocols).first
            ?? PartChoice.all(model.protocols).first?.key
            ?? ViewKey(.other, "adhoc")
    }
}
