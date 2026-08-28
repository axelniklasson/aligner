import AppKit

/// Grayscale snapshot of one display, used to find element edges. Rows are
/// top-down like a `CGImage`; coordinates are device pixels.
final class EdgeMap {
    let width: Int
    let height: Int
    let luma: [UInt8]
    /// The display's frame in AppKit screen coordinates (bottom-left origin).
    let frame: NSRect
    /// Device pixels per point.
    let scale: CGFloat

    init(width: Int, height: Int, luma: [UInt8], frame: NSRect, scale: CGFloat) {
        precondition(luma.count == width * height)
        self.width = width
        self.height = height
        self.luma = luma
        self.frame = frame
        self.scale = scale
    }

    /// Converts a captured image to luminance. Fails only if CoreGraphics
    /// can't allocate the conversion context.
    convenience init?(image: CGImage, frame: NSRect) {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let converted = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard converted else { return nil }
        self.init(width: width, height: height, luma: buffer, frame: frame, scale: CGFloat(width) / frame.width)
    }

    @inline(__always)
    func value(_ x: Int, _ y: Int) -> Int {
        Int(luma[y * width + x])
    }

    func pixel(fromScreen point: NSPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) * scale, y: (frame.maxY - point.y) * scale)
    }

    func screen(fromPixel point: CGPoint) -> NSPoint {
        NSPoint(x: frame.minX + point.x / scale, y: frame.maxY - point.y / scale)
    }

    /// PNG of the luminance buffer, for debugging.
    func pngData() -> Data? {
        var buffer = luma
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
