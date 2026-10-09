import CaptureKit
import CoreML
import Vision

/// Optional on-device region classifier (design §6.1).
///
/// Every photo already carries the checklist step it was taken in, and the server re-classifies
/// all uploads. Once a model has been trained on labelled captures, export it with Core ML Tools,
/// name it `RegionClassifier.mlmodel` and add it to the app target: its class labels must be
/// region names (`iris`, `face`, `beak`, `plumage_dorsal`, …). Until then this returns nil.
final class RegionClassifier: @unchecked Sendable {  // immutable after init
    static let shared = RegionClassifier()

    private let model: VNCoreMLModel?

    private init() {
        guard let url = Bundle.main.url(forResource: "RegionClassifier", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url)
        else {
            model = nil
            return
        }
        model = try? VNCoreMLModel(for: mlModel)
    }

    var isAvailable: Bool { model != nil }

    func classify(_ image: CGImage, orientation: CGImagePropertyOrientation) -> (Region, Double)? {
        guard let model else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        guard let top = (request.results as? [VNClassificationObservation])?.first,
              let region = Region(rawValue: top.identifier)
        else { return nil }
        return (region, Double(top.confidence))
    }
}
