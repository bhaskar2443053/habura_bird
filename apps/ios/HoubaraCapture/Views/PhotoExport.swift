import CaptureKit
import SwiftUI
import UIKit

/// The iOS share sheet (AirDrop, Save to Files, Save Images to Photos, Mail, …).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Files handed to the share sheet, kept alive until it closes.
struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

extension SessionStore {
    /// A folder of readable copies of a session's photos for sharing: names say what each photo
    /// shows (`HB1023_face_left_2.jpg`), plus the session.json manifest. The originals are not
    /// touched. Files are hard-linked when possible, so exporting costs no extra space.
    func exportFiles(_ session: CaptureSession) throws -> [URL] {
        let fm = FileManager.default
        let name = keySegment(session.ringRead?.code ?? "bird") + "_" + session.startedAt.exportStamp
        let dir = fm.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls: [URL] = []
        var counts: [String: Int] = [:]
        let prefix = keySegment(session.ringRead?.code ?? "bird")
        for shot in session.shots {
            let base = "\(prefix)_\(shot.region.rawValue)_\(shot.view)"
            counts[base, default: 0] += 1
            let target = dir.appendingPathComponent("\(base)_\(counts[base]!).jpg")
            let source = imageURL(session.id, shot)
            guard fm.fileExists(atPath: source.path) else { continue }
            do {
                try fm.linkItem(at: source, to: target)
            } catch {
                try fm.copyItem(at: source, to: target)
            }
            urls.append(target)
        }
        let manifest = dir.appendingPathComponent("session.json")
        try session.manifest().encoded().write(to: manifest, options: .atomic)
        urls.append(manifest)
        return urls
    }

    /// Readable copy of one photo for sharing or saving to Photos.
    func exportFile(_ shot: Shot, in session: CaptureSession) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = keySegment(session.ringRead?.code ?? "bird")
        let target = dir.appendingPathComponent("\(prefix)_\(shot.region.rawValue)_\(shot.view)_\(shot.id.prefix(6)).jpg")
        try? fm.removeItem(at: target)
        try fm.copyItem(at: imageURL(session.id, shot), to: target)
        return target
    }
}

private extension Date {
    var exportStamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: self)
    }
}

/// Full-screen photo viewer: swipe between a session's photos, pinch or double-tap to zoom,
/// share or save the one on screen.
struct PhotoViewer: View {
    let sessionId: String
    @State var selection: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: ShareItems?
    @State private var moving: Shot?

    var body: some View {
        let session = store.session(sessionId)
        let shots = session?.shots ?? []
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(shots) { shot in
                    ZoomableImage(url: store.imageURL(sessionId, shot)).tag(shot.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title(shots))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        moving = shots.first { $0.id == selection }
                    } label: {
                        Label("Change body part", systemImage: "arrow.left.arrow.right")
                    }
                    Spacer()
                    Button {
                        guard let session, let shot = shots.first(where: { $0.id == selection }),
                              let url = try? store.exportFile(shot, in: session) else { return }
                        sharing = ShareItems(urls: [url])
                    } label: {
                        Label("Share or save", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $sharing) { ShareSheet(items: $0.urls) }
            .sheet(item: $moving) { MovePhotoSheet(sessionId: sessionId, shot: $0) }
            .onChange(of: shots.map(\.id)) { _, ids in
                if ids.isEmpty { dismiss() } else if !ids.contains(selection) { selection = ids[0] }
            }
        }
    }

    private func title(_ shots: [Shot]) -> String {
        guard let index = shots.firstIndex(where: { $0.id == selection }) else { return "" }
        let shot = shots[index]
        return "\(PartChoice.title(ViewKey(shot.region, shot.view), model.protocols)) (\(index + 1) of \(shots.count))"
    }
}

/// Pinch and pan with a native scroll view; double-tap toggles zoom.
private struct ZoomableImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomingScrollView(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Decoded downscaled so a swipe through many 12 MP photos stays within memory.
        .task(id: url) { image = await Thumbnails.load(url, maxPixel: 2400) }
    }
}

private struct ZoomingScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = imageView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
