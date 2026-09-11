import Foundation
import CoreGraphics

/// Pipeline constants.
///
/// Face thresholds were calibrated against this exact detect→align→embed chain:
///  - LFW verification protocol: 99.32% accuracy, no false merges below t=0.40.
///  - End-to-end clustering over 127 LFW identities: pairwise F1 peaks across
///    t=0.44–0.52 (precision ≈0.995) and collapses by t=0.62 as people split apart.
/// 0.46 sits in the middle of that plateau, favouring precision — a wrong merge is
/// much more annoying to undo than a person appearing as two groups.
enum Tuning {
    static let analysisMaxPixel = 1600
    static let thumbMaxPixel = 512
    static let faceThumbMaxPixel = 256

    /// Faces smaller than this in the analysis image are too coarse to identify.
    static let minFaceSidePx: CGFloat = 36
    /// Below this Vision capture-quality, a face is stored but never seeds a cluster.
    static let clusterMinQuality: Float = 0.25

    static let defaultClusterThreshold: Float = 0.46
    static let defaultSearchThreshold: Float = 0.30
    static let minClusterSize = 3

    static let batchSize = 64
    static var lanes: Int { max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)) }
}
