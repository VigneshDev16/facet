import Foundation
import Accelerate

/// Append-only store of fixed-width L2-normalised Float32 vectors.
///
/// Rows live in one contiguous in-memory buffer so similarity search is a single
/// BLAS matrix-vector product; the backing file is a plain dump of the same bytes
/// so startup is one `read`, not a per-row decode.
final class VectorStore: @unchecked Sendable {
    let dim: Int
    private let url: URL
    private let lock = NSLock()
    private var storage: ContiguousArray<Float> = []
    private(set) var count: Int = 0
    private var handle: FileHandle?

    init(url: URL, dim: Int) throws {
        self.url = url
        self.dim = dim
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let rowBytes = dim * MemoryLayout<Float>.size
        let rows = data.count / rowBytes
        if rows > 0 {
            storage = ContiguousArray(repeating: 0, count: rows * dim)
            storage.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: 0..<(rows * rowBytes))
            }
        }
        count = rows
        storage.reserveCapacity(max(rows * dim, 4096 * dim))

        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(rows * rowBytes)) // drop any torn trailing row
        try h.seekToEnd()
        handle = h
    }

    /// Appends an L2-normalised copy of `v`. Returns its row index.
    @discardableResult
    func append(_ v: [Float]) throws -> Int {
        precondition(v.count == dim, "vector dim mismatch")
        var vec = v
        normalize(&vec)
        return try lock.withLock {
            let row = count
            storage.append(contentsOf: vec)
            count += 1
            try vec.withUnsafeBufferPointer { buf in
                try handle?.write(contentsOf: Data(buffer: buf))
            }
            return row
        }
    }

    func flush() { lock.withLock { try? handle?.synchronize() } }

    func vector(at row: Int) -> [Float]? {
        lock.withLock {
            guard row >= 0, row < count else { return nil }
            return Array(storage[(row * dim)..<((row + 1) * dim)])
        }
    }

    /// Cosine similarity of `query` against every stored row.
    /// Returns a score array indexed by row.
    func scores(for query: [Float]) -> [Float] {
        precondition(query.count == dim)
        var q = query
        normalize(&q)
        return lock.withLock {
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            storage.withUnsafeBufferPointer { m in
                q.withUnsafeBufferPointer { qp in
                    out.withUnsafeMutableBufferPointer { o in
                        // out = M (count x dim, row-major) * q
                        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                                    Int32(count), Int32(dim), 1.0,
                                    m.baseAddress!, Int32(dim),
                                    qp.baseAddress!, 1, 0.0,
                                    o.baseAddress!, 1)
                    }
                }
            }
            return out
        }
    }

    /// Top-`k` rows by cosine similarity, optionally restricted to `allowed`.
    func search(_ query: [Float], topK k: Int, allowed: Set<Int>? = nil, minScore: Float = -1) -> [(row: Int, score: Float)] {
        let s = scores(for: query)
        var hits: [(row: Int, score: Float)] = []
        hits.reserveCapacity(min(s.count, k * 4))
        for (i, v) in s.enumerated() where v >= minScore {
            if let allowed, !allowed.contains(i) { continue }
            hits.append((i, v))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(k))
    }

    /// Mean of the given rows, L2-normalised. Used for person centroids.
    func centroid(of rows: [Int]) -> [Float]? {
        lock.withLock {
            let valid = rows.filter { $0 >= 0 && $0 < count }
            guard !valid.isEmpty else { return nil }
            var acc = [Float](repeating: 0, count: dim)
            storage.withUnsafeBufferPointer { m in
                acc.withUnsafeMutableBufferPointer { a in
                    for r in valid {
                        cblas_saxpy(Int32(dim), 1.0, m.baseAddress! + r * dim, 1, a.baseAddress!, 1)
                    }
                }
            }
            normalize(&acc)
            return acc
        }
    }

    /// Reads a block of rows into a row-major matrix (for clustering passes).
    func matrix(rows: [Int]) -> [Float] {
        lock.withLock {
            var out = [Float](repeating: 0, count: rows.count * dim)
            storage.withUnsafeBufferPointer { m in
                out.withUnsafeMutableBufferPointer { o in
                    for (i, r) in rows.enumerated() where r >= 0 && r < count {
                        cblas_scopy(Int32(dim), m.baseAddress! + r * dim, 1, o.baseAddress! + i * dim, 1)
                    }
                }
            }
            return out
        }
    }
}

@inline(__always)
func normalize(_ v: inout [Float]) {
    var n: Float = 0
    vDSP_svesq(v, 1, &n, vDSP_Length(v.count))
    n = sqrt(n)
    guard n > 1e-8 else { return }
    var inv = 1 / n
    vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
}

@inline(__always)
func dot(_ a: [Float], _ b: [Float]) -> Float {
    var r: Float = 0
    vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
    return r
}

extension NSLock {
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
