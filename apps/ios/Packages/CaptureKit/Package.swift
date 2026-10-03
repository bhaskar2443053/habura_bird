// swift-tools-version:5.9
// Platform-independent core of the capture app: protocols, quality gate, session model,
// ring code matching and the upload queue. No UIKit/AVFoundation, so `swift test` runs on Linux.
import PackageDescription

let package = Package(
    name: "CaptureKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "CaptureKit", targets: ["CaptureKit"])],
    targets: [
        .target(name: "CaptureKit"),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
    ]
)
