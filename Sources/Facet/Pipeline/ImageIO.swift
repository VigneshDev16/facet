import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import AppKit

enum ImageDecoder {
    /// Extensions we treat as importable stills.
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "rw2", "orf", "raf", "pef", "srw",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes at most `maxPixel` on the long edge, with EXIF orientation already applied.
    /// Uses the embedded thumbnail when one is large enough, which makes scanning far cheaper.
    static func decode(url: URL, maxPixel: Int) -> CGImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    struct Metadata {
        var width = 0, height = 0
        var capturedAt: Date?
        var camera: String?
        var latitude: Double?
        var longitude: Double?
        var orientation: Int = 1
    }

    static func metadata(url: URL) -> Metadata {
        var m = Metadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return m }

        m.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        m.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        m.orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5–8 are 90° rotations, so the stored pixel dims are transposed.
        if m.orientation >= 5 { swap(&m.width, &m.height) }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            m.capturedAt = raw.flatMap(parseExifDate)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            m.camera = [make, model].compactMap { $0 }.joined(separator: " ").trimmed.nilIfEmpty
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            m.latitude = latRef == "S" ? -lat : lat
            m.longitude = lonRef == "W" ? -lon : lon
        }
        return m
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func parseExifDate(_ s: String) -> Date? { exifFormatter.date(from: s) }

    /// Encodes a downscaled JPEG for the on-disk thumbnail cache.
    static func jpegThumbnail(from image: CGImage, maxPixel: Int, quality: CGFloat = 0.72) -> Data? {
        let scale = min(1.0, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
