import Foundation
import CoreGraphics
import SwiftUI

/// Owns the background scan/analyse work and publishes progress for the UI.
@MainActor
final class Indexer: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning(String), analysing, clustering, paused
        var label: String {
            switch self {
            case .idle: return "Up to date"
            case .scanning(let f): return "Scanning \(f)"
            case .analysing: return "Analysing photos"
            case .clustering: return "Grouping people"
            case .paused: return "Paused"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var rate: Double = 0
    @Published private(set) var lastError: String?

    var isBusy: Bool { phase != .idle && phase != .paused }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var remainingText: String {
        guard rate > 0, total > done else { return "" }
        let secs = Double(total - done) / rate
        if secs < 90 { return "about \(Int(secs))s left" }
        if secs < 5400 { return "about \(Int(secs / 60))m left" }
        return String(format: "about %.1fh left", secs / 3600)
    }

    private let store: Store
    private var task: Task<Void, Never>?
    private var cancelled = false

    // Models are loaded once and shared across lanes; CoreML handles concurrent use.
    private var faceEmbedder: FaceEmbedder?
    private var clipEmbedder: ClipImageEmbedder?

    init(store: Store) { self.store = store }

    func loadModels() throws {
        if faceEmbedder == nil { faceEmbedder = try FaceEmbedder(url: try Res.model("ArcFace")) }
        if clipEmbedder == nil { clipEmbedder = try ClipImageEmbedder(url: try Res.model("mobileclip_s2_image")) }
    }

    func start() {
        guard task == nil else { return }
        cancelled = false
        task = Task { [weak self] in
            await self?.runPipeline()
            await MainActor.run { self?.task = nil }
        }
    }

    func pause() {
        cancelled = true
        task?.cancel()
        task = nil
        phase = .paused
    }

    /// Re-queues every asset for analysis (used after changing model settings).
    func reanalyseAll() {
        try? store.db.run("UPDATE assets SET thumb_state = 0, face_state = 0, clip_state = 0")
        try? store.db.run("DELETE FROM faces")
        start()
    }

    private func runPipeline() async {
        do {
            try loadModels()
        } catch {
            lastError = "Could not load models: \(error)"
            phase = .idle
            return
        }

        for folder in store.folders() {
            if cancelled { phase = .paused; return }
            phase = .scanning(folder.displayName)
            await scan(folder: folder)
        }

        await analyse()
        if cancelled { phase = .paused; return }

        phase = .clustering
        let clusterer = Clusterer(store: store)
        await Task.detached(priority: .utility) { clusterer.run() }.value

        phase = .idle
        done = 0; total = 0
    }

    // MARK: scanning

    private func scan(folder: Folder) async {
        let store = self.store
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let root = URL(fileURLWithPath: folder.path)
            var present = Set<String>()
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            var batch: [(URL, Int64, Double)] = []

            func flush() {
                try? store.db.transaction {
                    for (url, bytes, mtime) in batch {
                        let meta = ImageDecoder.metadata(url: url)
                        _ = try? store.upsertAsset(folderID: folder.id, url: url, bytes: bytes, mtime: mtime, meta: meta)
                    }
                }
                batch.removeAll(keepingCapacity: true)
            }

            for case let url as URL in en {
                guard ImageDecoder.isSupported(url) else { continue }
                let vals = try? url.resourceValues(forKeys: Set(keys))
                guard vals?.isRegularFile == true else { continue }
                present.insert(url.path)
                batch.append((url, Int64(vals?.fileSize ?? 0),
                              vals?.contentModificationDate?.timeIntervalSince1970 ?? 0))
                if batch.count >= 256 { flush() }
            }
            flush()
            store.markMissingOutside(folderID: folder.id, presentPaths: present)
            store.markScanned(folder.id)
        }.value
    }

    // MARK: analysis

    private func analyse() async {
        phase = .analysing
        total = store.pendingCount(column: "face_state")
        done = 0
        let started = Date()

        while !cancelled {
            let batch = store.pending(column: "face_state", limit: Tuning.batchSize)
            if batch.isEmpty { break }

            let store = self.store
            guard let fe = faceEmbedder, let ce = clipEmbedder else { break }
            let lanes = Tuning.lanes

            await withTaskGroup(of: Void.self) { group in
                var iterator = batch.makeIterator()
                var running = 0
                func addNext() {
                    guard let asset = iterator.next() else { return }
                    running += 1
                    group.addTask { await Self.process(asset: asset, store: store, faces: fe, clip: ce) }
                }
                for _ in 0..<lanes { addNext() }
                while running > 0 {
                    await group.next()
                    running -= 1
                    addNext()
                }
            }

            done += batch.count
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 0.5 { rate = Double(done) / elapsed }
            if Task.isCancelled { break }
        }
        store.faceVectors.flush()
        store.clipVectors.flush()
    }

    /// One decode feeds the thumbnail, face, and CLIP stages — decoding dominates cost.
    nonisolated static func process(asset: Asset, store: Store, faces fe: FaceEmbedder, clip ce: ClipImageEmbedder) async {
        guard let image = ImageDecoder.decode(url: asset.url, maxPixel: Tuning.analysisMaxPixel) else {
            store.setState("face_state", .failed, for: asset.id)
            store.setState("thumb_state", .failed, for: asset.id)
            store.setState("clip_state", .failed, for: asset.id)
            return
        }

        // Thumbnail
        let thumbURL = store.thumbnailURL(for: asset.id)
        if !FileManager.default.fileExists(atPath: thumbURL.path) {
            if let jpeg = ImageDecoder.jpegThumbnail(from: image, maxPixel: Tuning.thumbMaxPixel) {
                try? FileManager.default.createDirectory(at: thumbURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? jpeg.write(to: thumbURL, options: .atomic)
                store.setState("thumb_state", .done, for: asset.id)
            } else {
                store.setState("thumb_state", .failed, for: asset.id)
            }
        } else {
            store.setState("thumb_state", .done, for: asset.id)
        }

        // Faces
        do {
            let detected = try await FaceDetector.detect(in: image)
            let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
            for face in detected {
                guard face.boundingBox.width * imgW >= Tuning.minFaceSidePx,
                      face.boundingBox.height * imgH >= Tuning.minFaceSidePx,
                      let lm = face.landmarks,
                      let aligned = FaceAligner.align(image: image, landmarks: lm),
                      let vec = try? fe.embed(aligned)
                else { continue }

                guard let row = try? store.faceVectors.append(vec),
                      let faceID = try? store.insertFace(assetID: asset.id, face: face, vecRow: row)
                else { continue }

                // Cache a face crop so the People grid never re-decodes originals.
                if let crop = FaceAligner.thumbnailCrop(image: image, normalizedBox: face.boundingBox),
                   let jpeg = ImageDecoder.jpegThumbnail(from: crop, maxPixel: Tuning.faceThumbMaxPixel) {
                    let u = store.faceThumbnailURL(for: faceID)
                    try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? jpeg.write(to: u, options: .atomic)
                }
            }
            store.setState("face_state", .done, for: asset.id)
        } catch {
            store.setState("face_state", .failed, for: asset.id)
        }

        // Scene embedding for text search
        if let vec = try? ce.embed(image), let row = try? store.clipVectors.append(vec) {
            store.setClipRow(row, for: asset.id)
        } else {
            store.setState("clip_state", .failed, for: asset.id)
        }
    }
}
