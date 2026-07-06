import CoreGraphics
import Foundation
import ImageIO

/// Header-only image properties — no pixel decode, so it's cheap enough to
/// call lazily on first display of each image.
public enum ImageMetadata {
    /// Pixel size in DISPLAY orientation: EXIF orientations 5-8 swap width
    /// and height so editor space always matches what the user sees (and what
    /// Create ML coordinates mean).
    public static func pixelSize(of url: URL) -> CGSize? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }

        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
