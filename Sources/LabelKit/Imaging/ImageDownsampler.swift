import CoreGraphics
import Foundation
import ImageIO

/// CGImageSource-based downsampling decode: never materializes the full-res
/// bitmap when a smaller one is requested, applies EXIF orientation, and
/// forces the decode onto the calling (background) thread.
public enum ImageDownsampler {
    /// `preferEmbedded` (sidebar/placeholder tiers only) uses the camera's
    /// embedded EXIF thumbnail when present — decoding that ~160 px JPEG is
    /// ~10× cheaper than a scaled full decode of a 4000 px image. Falls back
    /// to a full decode when no thumbnail is embedded (PNGs, re-exported
    /// files), so it's never slower. The full-detail canvas path leaves it
    /// off: an embedded thumbnail is useless at canvas resolution.
    public static func decode(url: URL, maxPixel: CGFloat, preferEmbedded: Bool = false) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let fromImageKey = preferEmbedded
            ? kCGImageSourceCreateThumbnailFromImageIfAbsent
            : kCGImageSourceCreateThumbnailFromImageAlways
        let thumbnailOptions = [
            fromImageKey: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}
