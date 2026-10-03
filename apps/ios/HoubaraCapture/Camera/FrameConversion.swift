import CaptureKit
import CoreImage
import CoreVideo
import ImageIO

/// Pixel plumbing between camera buffers / JPEGs and CaptureKit's `GrayImage`.
enum FrameConversion {
    private static let ciContext = CIContext()

    /// Centre square of the luma plane, copied at native resolution (no resampling, so the
    /// sharpness measure isn't inflated by downscaling).
    static func centerLuma(of buffer: CVPixelBuffer, side: Int) -> GrayImage? {
        guard CVPixelBufferIsPlanar(buffer) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let s = min(side, width, height)
        guard s >= 3 else { return nil }
        let x0 = (width - s) / 2, y0 = (height - s) / 2
        let src = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: s * s)
        pixels.withUnsafeMutableBufferPointer { dst in
            for y in 0..<s {
                (dst.baseAddress! + y * s).update(from: src + (y0 + y) * stride + x0, count: s)
            }
        }
        return GrayImage(width: s, height: s, pixels: pixels)
    }

    /// Centre square of a still, rendered to 8-bit gray at full resolution.
    static func centerGray(of image: CGImage, side: Int) -> GrayImage? {
        let s = min(side, image.width, image.height)
        guard s >= 3,
              let crop = image.cropping(to: CGRect(x: (image.width - s) / 2, y: (image.height - s) / 2, width: s, height: s))
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: s * s)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: s, height: s))
            return true
        }
        return drawn ? GrayImage(width: s, height: s, pixels: pixels) : nil
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// EXIF orientation of a JPEG (portrait iPhone shots are usually `.right`).
    static func orientation(of data: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else { return .up }
        return orientation
    }

    static func jpeg(from buffer: CVPixelBuffer, quality: CGFloat = 0.95) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        return ciContext.jpegRepresentation(
            of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options
        )
    }
}

/// Quality of a captured still, judged on a full-resolution centre crop (the guide area).
enum StillAnalysis {
    struct Result: @unchecked Sendable {  // CGImage is immutable
        let quality: QualityReport
        let width: Int
        let height: Int
        let image: CGImage?
    }

    static func analyse(_ data: Data, thresholds: QualityThresholds) -> Result {
        guard let image = FrameConversion.cgImage(from: data),
              let gray = FrameConversion.centerGray(of: image, side: 1024)
        else {
            let failed = QualityReport(sharpness: 0, glareRatio: 0, brightness: 0, shortSidePx: 0, failures: ["unreadable"])
            return Result(quality: failed, width: 0, height: 0, image: nil)
        }
        let quality = Quality.assess(gray, shortSidePx: min(image.width, image.height), thresholds: thresholds)
        return Result(quality: quality, width: image.width, height: image.height, image: image)
    }
}
