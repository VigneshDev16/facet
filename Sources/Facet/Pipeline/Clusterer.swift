import Foundation
import Accelerate

/// Incremental face grouping.
///
/// New faces are matched against existing person centroids (blocked BLAS sgemm, so
/// cost is O(faces x people) rather than O(faces²)), creating a new provisional person
/// when nothing is close enough. A centroid merge pass then folds together clusters
/// that the streaming order split apart.
final class Clusterer {
    private let store: Store
    private let dim = Store.embeddingDim

    init(store: Store) { self.store = store }

    private struct Cluster {
        var personID: Int64
        var sum: [Float]      // unnormalised running total
        var count: Int
        var named: Bool
        var centroid: [Float] {
            var c = sum
            normalize(&c)
            return c
        }
    }

    func run() {
        let threshold = Float(store.doubleSetting("clusterThreshold",
                                                  default: Double(Tuning.defaultClusterThreshold)))
        let mergeThreshold = min(0.9, threshold + 0.05)

        var clusters = loadExistingClusters()
        let pending = store.unclusteredFaces(minQuality: Tuning.clusterMinQuality)
        guard !pending.isEmpty else {
            mergeClusters(&clusters, threshold: mergeThreshold)
            return
        }

        let blockSize = 128
        var assignments: [(faceID: Int64, personID: Int64)] = []

        for start in stride(from: 0, to: pending.count, by: blockSize) {
            let block = Array(pending[start..<min(start + blockSize, pending.count)])
            let queries = store.faceVectors.matrix(rows: block.map(\.vecRow))

            // Similarities of every face in the block against every current centroid.
            // `clusters` may grow while we walk the block, so the row stride is pinned
            // to the count the matrix was actually built with.
            let baseClusterCount = clusters.count
            var sims = [Float]()
            if baseClusterCount > 0 {
                var centroidMatrix = [Float](repeating: 0, count: baseClusterCount * dim)
                for (i, c) in clusters.enumerated() {
                    let v = c.centroid
                    for j in 0..<dim { centroidMatrix[i * dim + j] = v[j] }
                }
                sims = [Float](repeating: 0, count: block.count * baseClusterCount)
                queries.withUnsafeBufferPointer { q in
                    centroidMatrix.withUnsafeBufferPointer { c in
                        sims.withUnsafeMutableBufferPointer { s in
                            // S(block x K) = Q(block x dim) * Cᵀ(dim x K)
                            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                        Int32(block.count), Int32(baseClusterCount), Int32(dim),
                                        1.0, q.baseAddress!, Int32(dim),
                                        c.baseAddress!, Int32(dim),
                                        0.0, s.baseAddress!, Int32(baseClusterCount))
                        }
                    }
                }
            }

            for (i, face) in block.enumerated() {
                var bestIdx = -1
                var bestScore = threshold
                for k in 0..<baseClusterCount {
                    let v = sims[i * baseClusterCount + k]
                    if v >= bestScore { bestScore = v; bestIdx = k }
                }

                let vec = Array(queries[(i * dim)..<((i + 1) * dim)])
                if bestIdx >= 0 {
                    clusters[bestIdx].count += 1
                    for j in 0..<dim { clusters[bestIdx].sum[j] += vec[j] }
                    assignments.append((face.id, clusters[bestIdx].personID))
                } else if let pid = try? store.createPerson(coverFaceID: face.id) {
                    // Faces later in this block won't see this centroid; the merge pass
                    // below reunites any duplicates that creates.
                    clusters.append(Cluster(personID: pid, sum: vec, count: 1, named: false))
                    assignments.append((face.id, pid))
                }
            }
        }

        try? store.db.transaction {
            for a in assignments {
                store.assign(faceID: a.faceID, personID: a.personID)
            }
        }
        store.markClustered(pending.map(\.id))

        mergeClusters(&clusters, threshold: mergeThreshold)
        attachResidualFaces(clusters, threshold: threshold + 0.05)
        refreshCovers()
    }

    /// Second pass: faces below the seeding quality bar can still join an existing
    /// person, at a stricter cutoff since their embeddings are noisier. Unmatched
    /// faces stay pending so a later run can retry them as clusters grow.
    private func attachResidualFaces(_ clusters: [Cluster], threshold: Float) {
        let residual = store.unassignedFaces()
        guard !residual.isEmpty, !clusters.isEmpty else { return }

        var centroidMatrix = [Float](repeating: 0, count: clusters.count * dim)
        for (i, c) in clusters.enumerated() {
            let v = c.centroid
            for j in 0..<dim { centroidMatrix[i * dim + j] = v[j] }
        }

        var assignments: [(Int64, Int64)] = []
        let blockSize = 256
        for start in stride(from: 0, to: residual.count, by: blockSize) {
            let block = Array(residual[start..<min(start + blockSize, residual.count)])
            let queries = store.faceVectors.matrix(rows: block.map(\.vecRow))
            var sims = [Float](repeating: 0, count: block.count * clusters.count)
            queries.withUnsafeBufferPointer { q in
                centroidMatrix.withUnsafeBufferPointer { c in
                    sims.withUnsafeMutableBufferPointer { s in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                    Int32(block.count), Int32(clusters.count), Int32(dim),
                                    1.0, q.baseAddress!, Int32(dim),
                                    c.baseAddress!, Int32(dim),
                                    0.0, s.baseAddress!, Int32(clusters.count))
                    }
                }
            }
            for (i, face) in block.enumerated() {
                var bestIdx = -1
                var bestScore = threshold
                for k in 0..<clusters.count {
                    let v = sims[i * clusters.count + k]
                    if v >= bestScore { bestScore = v; bestIdx = k }
                }
                if bestIdx >= 0 { assignments.append((face.id, clusters[bestIdx].personID)) }
            }
        }

        try? store.db.transaction {
            for (faceID, personID) in assignments {
                store.assign(faceID: faceID, personID: personID)
            }
        }
    }

    private func loadExistingClusters() -> [Cluster] {
        var out: [Cluster] = []
        for p in store.people(includeHidden: true, minFaces: 0) {
            let rows = store.vectorRows(forPerson: p.id)
            guard !rows.isEmpty else { continue }
            var sum = [Float](repeating: 0, count: dim)
            let m = store.faceVectors.matrix(rows: rows)
            for r in 0..<rows.count {
                for j in 0..<dim { sum[j] += m[r * dim + j] }
            }
            out.append(Cluster(personID: p.id, sum: sum, count: rows.count, named: p.isNamed))
        }
        return out
    }

    /// Folds together clusters whose centroids are mutually close. Two *named*
    /// people are never merged automatically — that's the user's call.
    private func mergeClusters(_ clusters: inout [Cluster], threshold: Float) {
        guard clusters.count > 1 else { return }
        let k = clusters.count
        var matrix = [Float](repeating: 0, count: k * dim)
        for (i, c) in clusters.enumerated() {
            let v = c.centroid
            for j in 0..<dim { matrix[i * dim + j] = v[j] }
        }
        var sims = [Float](repeating: 0, count: k * k)
        matrix.withUnsafeBufferPointer { m in
            sims.withUnsafeMutableBufferPointer { s in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                            Int32(k), Int32(k), Int32(dim),
                            1.0, m.baseAddress!, Int32(dim), m.baseAddress!, Int32(dim),
                            0.0, s.baseAddress!, Int32(k))
            }
        }

        var parent = Array(0..<k)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // Keep the larger cluster as the survivor.
            if clusters[ra].count >= clusters[rb].count { parent[rb] = ra } else { parent[ra] = rb }
        }

        for i in 0..<k {
            for j in (i + 1)..<k where sims[i * k + j] >= threshold {
                if clusters[i].named && clusters[j].named { continue }
                union(i, j)
            }
        }

        var merges: [(from: Int64, to: Int64)] = []
        for i in 0..<k {
            let r = find(i)
            if r != i { merges.append((clusters[i].personID, clusters[r].personID)) }
        }
        for m in merges where m.from != m.to {
            store.merge(person: m.from, into: m.to)
        }
        if !merges.isEmpty {
            clusters = loadExistingClusters()
        }
    }

    /// Gives every person a representative face (highest quality available).
    private func refreshCovers() {
        try? store.db.run("""
            UPDATE people SET cover_face_id = (
                SELECT f.id FROM faces f WHERE f.person_id = people.id
                ORDER BY f.confirmed DESC, f.quality DESC LIMIT 1
            )
            WHERE cover_face_id IS NULL
               OR NOT EXISTS (SELECT 1 FROM faces f2 WHERE f2.id = people.cover_face_id AND f2.person_id = people.id)
            """)
    }

    /// Re-runs grouping from scratch, preserving names by re-seeding from confirmed faces.
    func rebuildAll() {
        try? store.db.run("UPDATE faces SET clustered = 0, person_id = NULL WHERE confirmed = 0")
        try? store.db.run("DELETE FROM people WHERE name IS NULL")
        run()
    }
}
