import CoreGraphics
import Foundation
import ImageIO

/// CGImageSource-based downsampling decode: never materializes the full-res
/// bitmap when a smaller one is requested, applies EXIF orientation, and
/// forces the decode onto the calling (background) thread.
public enum ImageDownsampler {
    public static func decode(url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}
