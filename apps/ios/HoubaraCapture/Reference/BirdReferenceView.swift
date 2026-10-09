import CaptureKit
import SwiftUI

/// Picture of which part of the bird a capture step wants, so operators don't have to read the
/// hint text: a houbara side view with the target part highlighted, flipped for right-side views,
/// and a phone icon showing where to hold the camera (above, below or in front).
///
/// A real reference photo can replace the drawing: add an image named
/// `ref_<region>_<view>` (e.g. `ref_iris_left_eye`) to the app's asset catalog.
struct BirdReferenceView: View {
    let region: Region
    let view: String
    var showsCameraHint = true

    var body: some View {
        if let photo = UIImage(named: "ref_\(region.rawValue)_\(view)") {
            Image(uiImage: photo).resizable().scaledToFit()
        } else {
            BirdDiagram(pose: ReferencePose.pose(region: region, view: view), showsCameraHint: showsCameraHint)
                .aspectRatio(1.3, contentMode: .fit)
                .accessibilityLabel("Reference picture: \(region.title), \(view.replacingOccurrences(of: "_", with: " "))")
        }
    }
}

private struct BirdDiagram: View {
    let pose: ReferencePose
    let showsCameraHint: Bool

    private let silhouette = Color.gray.opacity(0.45)
    private let accent = Color.orange

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { context, canvasSize in
                    var ctx = context
                    if pose.mirrored {
                        ctx.translateBy(x: canvasSize.width, y: 0)
                        ctx.scaleBy(x: -1, y: 1)
                    }
                    draw(in: ctx, size: canvasSize)
                }
                if showsCameraHint, let hint = cameraHint(size: size) {
                    hint
                }
            }
        }
    }

    // MARK: Geometry (bird drawn facing left, i.e. showing its left side)

    /// Bird space (0…1 on both axes) to canvas points; leaves room above and below for the
    /// phone icon.
    private func point(_ x: CGFloat, _ y: CGFloat, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (0.06 + x * 0.88), y: size.height * (0.14 + y * 0.72))
    }

    private func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ size: CGSize) -> CGRect {
        let a = point(x0, y0, size), b = point(x1, y1, size)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private func polygon(_ points: [(CGFloat, CGFloat)], _ size: CGSize) -> Path {
        Path { p in
            p.addLines(points.map { point($0.0, $0.1, size) })
            p.closeSubpath()
        }
    }

    private func legs(_ size: CGSize) -> Path {
        Path { p in
            for (top, bottom) in [((0.52, 0.60), (0.49, 0.92)), ((0.60, 0.60), (0.63, 0.92))] {
                p.move(to: point(top.0, top.1, size))
                p.addLine(to: point(bottom.0, bottom.1, size))
                // Three forward toes.
                for toe in [-0.07, -0.045, 0.02] {
                    p.move(to: point(bottom.0, bottom.1, size))
                    p.addLine(to: point(bottom.0 + toe, bottom.1 + 0.05, size))
                }
            }
        }
    }

    private func path(_ part: ReferencePose.Part, _ size: CGSize) -> Path {
        switch part {
        case .head: return Path(ellipseIn: rect(0.14, 0.06, 0.29, 0.25, size))
        case .eye: return Path(ellipseIn: rect(0.175, 0.115, 0.215, 0.165, size))
        case .beak: return polygon([(0.155, 0.12), (0.06, 0.16), (0.155, 0.19)], size)
        case .back: return Path(ellipseIn: rect(0.40, 0.28, 0.80, 0.41, size))
        case .breast: return Path(ellipseIn: rect(0.27, 0.36, 0.50, 0.64, size))
        case .wing: return Path(ellipseIn: rect(0.44, 0.33, 0.80, 0.53, size))
        case .tail: return polygon([(0.78, 0.38), (0.93, 0.35), (0.94, 0.46), (0.79, 0.53)], size)
        case .feet: return Path(ellipseIn: rect(0.38, 0.86, 0.70, 1.0, size))
        case .ring: return Path(roundedRect: rect(0.488, 0.74, 0.535, 0.80, size), cornerRadius: 2)
        case .wholeBird: return Path(ellipseIn: rect(0.30, 0.28, 0.82, 0.64, size))
        }
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let lineWidth = max(1.5, size.width * 0.012)

        // Silhouette: legs, tail, body, neck, head with crest, beak, eye.
        ctx.stroke(legs(size), with: .color(silhouette), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        ctx.fill(path(.tail, size), with: .color(silhouette))
        ctx.fill(Path(ellipseIn: rect(0.30, 0.28, 0.82, 0.64, size)), with: .color(silhouette))
        ctx.fill(polygon([(0.30, 0.46), (0.43, 0.34), (0.28, 0.12), (0.17, 0.18)], size), with: .color(silhouette))
        ctx.fill(path(.head, size), with: .color(silhouette))
        ctx.fill(polygon([(0.20, 0.08), (0.30, 0.02), (0.25, 0.10)], size), with: .color(silhouette))
        ctx.fill(path(.beak, size), with: .color(silhouette.opacity(0.8)))
        ctx.fill(Path(ellipseIn: rect(0.185, 0.125, 0.205, 0.155, size)), with: .color(.black.opacity(0.6)))
        ctx.stroke(path(.ring, size), with: .color(silhouette.opacity(0.9)), lineWidth: 1)

        // Highlight the requested part.
        let target = path(pose.part, size)
        if pose.part == .feet {
            ctx.stroke(legs(size), with: .color(accent), style: StrokeStyle(lineWidth: lineWidth * 1.4, lineCap: .round))
        } else {
            ctx.fill(target, with: .color(accent.opacity(0.85)))
        }
        // Dashed ring around the target; larger for close-ups so small parts stand out.
        let bounds = target.boundingRect
        let pad = pose.closeUp ? size.width * 0.07 : size.width * 0.025
        ctx.stroke(
            Path(ellipseIn: bounds.insetBy(dx: -pad, dy: -pad)),
            with: .color(accent),
            style: StrokeStyle(lineWidth: 2, dash: [5, 4])
        )
    }

    // MARK: Camera hint

    private func cameraHint(size: CGSize) -> AnyView? {
        let bounds = path(pose.part, size).boundingRect
        var center = CGPoint(x: bounds.midX, y: bounds.midY)
        if pose.mirrored { center.x = size.width - center.x }
        let icon: String
        let position: CGPoint
        switch pose.camera {
        case .side:
            guard pose.closeUp else { return nil }
            icon = "plus.magnifyingglass"
            position = CGPoint(x: center.x + (pose.mirrored ? -1 : 1) * size.width * 0.13, y: max(14, center.y - size.height * 0.08))
        case .above:
            icon = "camera.fill"
            position = CGPoint(x: center.x, y: max(12, bounds.minY - size.height * 0.10))
        case .below:
            icon = "camera.fill"
            position = CGPoint(x: center.x, y: min(size.height - 10, bounds.maxY + size.height * 0.06))
        case .front:
            icon = "camera.fill"
            let dx = size.width * 0.12
            position = CGPoint(x: max(12, min(size.width - 12, center.x + (pose.mirrored ? dx : -dx))), y: center.y)
        }
        let arrow: String? = switch pose.camera {
        case .above: "arrow.down"
        case .below: "arrow.up"
        case .front: pose.mirrored ? "arrow.left" : "arrow.right"
        case .side: nil
        }
        let label = HStack(spacing: 1) {
            Image(systemName: icon)
            if let arrow { Image(systemName: arrow) }
        }
        .font(.system(size: max(10, size.width * 0.07), weight: .bold))
        .foregroundStyle(Color.blue)
        .position(position)
        return AnyView(label)
    }
}

/// Bigger version shown when the operator taps the small reference picture.
struct BirdReferenceSheet: View {
    let region: Region
    let view: ViewSpec
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                BirdReferenceView(region: region, view: view.name)
                    .frame(maxWidth: .infinity)
                    .padding()
                HStack(spacing: 16) {
                    Label("Photograph this part", systemImage: "circle.dashed").foregroundStyle(.orange)
                    Label("Hold the phone here", systemImage: "camera.fill").foregroundStyle(.blue)
                }
                .font(.footnote)
                if !view.hint.isEmpty {
                    Text(view.hint).font(.body).multilineTextAlignment(.center).padding(.horizontal)
                }
                Spacer()
            }
            .navigationTitle("\(region.title): \(view.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
