import Foundation
import Vision
import CoreGraphics

/// One detected face, in the coordinate space of the image it was found in.
struct DetectedFace {
    var boundingBox: CGRect      // normalised, upper-left origin
    var quality: Float           // Vision capture-quality, 0…1
    var confidence: Float
    var roll: Double, yaw: Double, pitch: Double
    var landmarks: FiveLandmarks?
}

/// The five points ArcFace alignment is defined against, in image pixels
/// (upper-left origin). Left/right are *image* sides, not the subject's.
struct FiveLandmarks {
    var eyeL: CGPoint, eyeR: CGPoint, nose: CGPoint, mouthL: CGPoint, mouthR: CGPoint
    var asArray: [CGPoint] { [eyeL, eyeR, nose, mouthL, mouthR] }
}

enum FaceDetector {
    /// Runs landmark + capture-quality detection in one pass over the image.
    static func detect(in image: CGImage) async throws -> [DetectedFace] {
        let size = CGSize(width: image.width, height: image.height)
        let handler = ImageRequestHandler(image)
        let (landmarkFaces, qualityFaces) = try await handler.perform(
            DetectFaceLandmarksRequest(),
            DetectFaceCaptureQualityRequest()
        )

        // Quality comes back as a parallel result set; match on bounding-box overlap.
        return landmarkFaces.map { face in
            let box = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            let quality = bestQuality(for: face, in: qualityFaces, size: size)
            return DetectedFace(
                boundingBox: CGRect(x: box.origin.x / size.width,
                                    y: box.origin.y / size.height,
                                    width: box.width / size.width,
                                    height: box.height / size.height),
                quality: quality,
                confidence: face.confidence,
                roll: face.roll.converted(to: .degrees).value,
                yaw: face.yaw.converted(to: .degrees).value,
                pitch: face.pitch.converted(to: .degrees).value,
                landmarks: fiveLandmarks(from: face, imageSize: size)
            )
        }
    }

    private static func bestQuality(for face: FaceObservation,
                                    in qualityFaces: [FaceObservation],
                                    size: CGSize) -> Float {
        if let q = face.captureQuality?.score { return q }
        let a = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        var best: Float = 0
        var bestIoU: CGFloat = 0.3   // require meaningful overlap before trusting a match
        for q in qualityFaces {
            let b = q.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            let inter = a.intersection(b)
            guard !inter.isNull else { continue }
            let iou = (inter.width * inter.height) /
                      (a.width * a.height + b.width * b.height - inter.width * inter.height)
            if iou > bestIoU, let s = q.captureQuality?.score { bestIoU = iou; best = s }
        }
        return best
    }

    /// Reduces Vision's dense landmark regions to the five ArcFace reference points.
    /// Points are assigned by x-position rather than by Vision's left/right naming,
    /// which is defined from the subject's viewpoint and flips for mirrored shots.
    static func fiveLandmarks(from face: FaceObservation, imageSize: CGSize) -> FiveLandmarks? {
        guard let lm = face.landmarks else { return nil }

        func centroid(_ region: FaceObservation.Landmarks2D.Region) -> CGPoint? {
            let pts = region.pointsInImageCoordinates(imageSize, origin: .upperLeft)
            guard !pts.isEmpty else { return nil }
            let sx = pts.reduce(0.0) { $0 + $1.x }
            let sy = pts.reduce(0.0) { $0 + $1.y }
            return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
        }

        // Pupils are the most precise when present; fall back to eye-outline centroids.
        let e1 = centroid(lm.leftPupil) ?? centroid(lm.leftEye)
        let e2 = centroid(lm.rightPupil) ?? centroid(lm.rightEye)
        guard var eyeA = e1, var eyeB = e2, let noseC = centroid(lm.nose) else { return nil }
        if eyeA.x > eyeB.x { swap(&eyeA, &eyeB) }

        // Mouth corners are the extreme-x points of the outer lip contour.
        let lips = lm.outerLips.pointsInImageCoordinates(imageSize, origin: .upperLeft)
        guard lips.count >= 2,
              let mA = lips.min(by: { $0.x < $1.x }),
              let mB = lips.max(by: { $0.x < $1.x })
        else { return nil }

        return FiveLandmarks(eyeL: eyeA, eyeR: eyeB, nose: noseC, mouthL: mA, mouthR: mB)
    }
}
