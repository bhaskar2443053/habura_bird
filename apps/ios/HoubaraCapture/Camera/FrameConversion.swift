import CaptureKit
import CoreImage
import CoreVideo
import ImageIO

/// Pixel plumbing between camera buffers / JPEGs and CaptureKit's `GrayImage`.
enum FrameConversion {
    private static let ciContext = CIContext()

    /// Side of the square the quality gate measures, as a fraction of the frame's short side. The
    /// live preview and the still use the same field of view so they agree.
    static let gateFraction = 0.4

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

    /// Every n-th luma sample of the whole preview frame, about `shortSide` px on the short side;
    /// enough to find the pupil for the eye-size check.
    static func downscaledLuma(of buffer: CVPixelBuffer, shortSide: Int = 160) -> GrayImage? {
        guard CVPixelBufferIsPlanar(buffer) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let step = max(1, min(width, height) / shortSide)
        let w = width / step, h = height / step
        guard w >= 8, h >= 8 else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = src + y * step * stride
            for x in 0..<w { pixels[y * w + x] = row[x * step] }
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    /// A still rendered to 8-bit gray: the centre square covering `fraction` of the short side,
    /// resampled (area-averaged) to `side` px. Resampling makes the sharpness number independent
    /// of the camera's resolution: measured at native 24/48 MP, even a sharp photo scores as
    /// blurry because neighbouring pixels barely differ.
    static func centerGray(of image: CGImage, fraction: Double, side: Int) -> GrayImage? {
        let short = min(image.width, image.height)
        let c = max(3, Int(Double(short) * fraction))
        guard let crop = image.cropping(to: CGRect(x: (image.width - c) / 2, y: (image.height - c) / 2, width: c, height: c))
        else { return nil }
        return gray(crop, width: min(side, c), height: min(side, c))
    }

    /// The whole still in 8-bit gray, about `shortSide` px on the short side.
    static func downscaledGray(of image: CGImage, shortSide: Int = 160) -> GrayImage? {
        let scale = Double(shortSide) / Double(min(image.width, image.height))
        return gray(image, width: max(8, Int(Double(image.width) * scale)), height: max(8, Int(Double(image.height) * scale)))
    }

    private static func gray(_ image: CGImage, width: Int, height: Int) -> GrayImage? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? GrayImage(width: width, height: height, pixels: pixels) : nil
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

/// Quality of a captured still, judged on the centre of the frame (the guide area) at the same
/// field of view and roughly the same pixel scale as the live preview check.
enum StillAnalysis {
    struct Result: @unchecked Sendable {  // CGImage is immutable
        let quality: QualityReport
        let width: Int
        let height: Int
        let image: CGImage?
    }

    static func analyse(_ data: Data, thresholds: QualityThresholds, checkEye: Bool = false) -> Result {
        guard let image = FrameConversion.cgImage(from: data),
              let gray = FrameConversion.centerGray(of: image, fraction: FrameConversion.gateFraction, side: 512)
        else {
            let failed = QualityReport(sharpness: 0, glareRatio: 0, brightness: 0, shortSidePx: 0, failures: ["unreadable"])
            return Result(quality: failed, width: 0, height: 0, image: nil)
        }
        var quality = Quality.assess(gray, shortSidePx: min(image.width, image.height), thresholds: thresholds)
        if checkEye, let whole = FrameConversion.downscaledGray(of: image) {
            Quality.checkEyeSize(whole, report: &quality)
        }
        return Result(quality: quality, width: image.width, height: image.height, image: image)
    }
}
