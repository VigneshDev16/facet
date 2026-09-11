import Foundation
import CoreGraphics

enum FaceAligner {
    static let outputSize = 112

    /// InsightFace's canonical 112x112 landmark template (upper-left origin):
    /// image-left eye, image-right eye, nose tip, image-left mouth corner, image-right mouth corner.
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares similarity (rotation + uniform scale + translation) mapping
    /// `src` onto `dst`. Closed-form 2D Procrustes — no SVD needed for the 2x2 case.
    static func similarityTransform(src: [CGPoint], dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = CGFloat(src.count)

        let mp = CGPoint(x: src.reduce(0) { $0 + $1.x } / n, y: src.reduce(0) { $0 + $1.y } / n)
        let mq = CGPoint(x: dst.reduce(0) { $0 + $1.x } / n, y: dst.reduce(0) { $0 + $1.y } / n)

        var a: CGFloat = 0   // Σ p·q   (aligned component)
        var b: CGFloat = 0   // Σ p×q   (rotational component)
        var normP: CGFloat = 0
        for i in 0..<src.count {
            let px = src[i].x - mp.x, py = src[i].y - mp.y
            let qx = dst[i].x - mq.x, qy = dst[i].y - mq.y
            a += px * qx + py * qy
            b += px * qy - py * qx
            normP += px * px + py * py
        }
        guard normP > 1e-9 else { return nil }

        let scale = sqrt(a * a + b * b) / normP
        guard scale.isFinite, scale > 1e-9 else { return nil }
        let theta = atan2(b, a)
        let c = scale * cos(theta), s = scale * sin(theta)

        // (x,y) -> (c·x - s·y + tx, s·x + c·y + ty)
        let tx = mq.x - (c * mp.x - s * mp.y)
        let ty = mq.y - (s * mp.x + c * mp.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    /// Warps the face onto the 112x112 ArcFace template.
    ///
    /// Landmarks and the template are both in upper-left-origin pixel space, while
    /// CoreGraphics draws with a lower-left origin, so the transform is conjugated by
    /// a vertical flip on each side: M = Flip(112) ∘ A ∘ Flip(H).
    static func align(image: CGImage, landmarks: FiveLandmarks) -> CGImage? {
        guard let a = similarityTransform(src: landmarks.asArray, dst: template) else { return nil }

        let h = CGFloat(image.height)
        let out = CGFloat(outputSize)
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let flipDst = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out)
        let m = flipSrc.concatenating(a).concatenating(flipDst)

        guard let ctx = CGContext(data: nil, width: outputSize, height: outputSize,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // Edge pixels can fall outside the source; a neutral fill avoids black borders.
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))
        ctx.concatenate(m)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h))
        return ctx.makeImage()
    }

    /// Square crop around a face box with margin, used for People thumbnails.
    static func thumbnailCrop(image: CGImage, normalizedBox: CGRect, margin: CGFloat = 0.45) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let px = CGRect(x: normalizedBox.origin.x * w, y: normalizedBox.origin.y * h,
                        width: normalizedBox.width * w, height: normalizedBox.height * h)
        let side = max(px.width, px.height) * (1 + margin * 2)
        let cx = px.midX, cy = px.midY
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width >= 8, rect.height >= 8 else { return nil }
        return image.cropping(to: rect.integral)
    }
}
