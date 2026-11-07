import CoreGraphics
import Foundation

public enum Selection {
    public static func rectangle(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }

    // Overlay coordinates have a bottom-left origin; image pixels have a top-left origin.
    public static func pixels(for region: CGRect, in bounds: CGRect, width: Int, height: Int) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0, width > 0, height > 0 else { return nil }
        let clipped = region.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let sx = CGFloat(width) / bounds.width
        let sy = CGFloat(height) / bounds.height
        let left = floor((clipped.minX - bounds.minX) * sx)
        let top = floor((bounds.maxY - clipped.maxY) * sy)
        let right = ceil((clipped.maxX - bounds.minX) * sx)
        let bottom = ceil((bounds.maxY - clipped.minY) * sy)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    public static func crop(_ image: CGImage, region: CGRect, bounds: CGRect) throws -> CGImage {
        guard let pixels = pixels(for: region, in: bounds, width: image.width, height: image.height),
              let crop = image.cropping(to: pixels) else {
            throw LensError.message("Select an area at least 2 points wide and high.")
        }
        return crop
    }
}

public enum LensError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
