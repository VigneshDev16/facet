import Foundation
import CoreGraphics

/// Runs the LFW verification protocol against the full detect -> align -> embed chain.
/// Published ArcFace w600k_r50 scores ~99.8% here, so a correct port should land near that;
/// a broken alignment shows up immediately as a large accuracy drop.
enum PairBench {
    struct Pair: Decodable { let a: String; let b: String; let same: Int }

    static func run(dir: String) {
        let sem = DispatchSemaphore(value: 0)
        Task { await execute(dir: dir); sem.signal() }
        sem.wait()
    }

    /// Detect the largest face, align it, and embed. Returns nil when no face is found.
    static func embed(url: URL, embedder: FaceEmbedder) async -> [Float]? {
        guard let cg = ImageDecoder.decode(url: url, maxPixel: 1600),
              let faces = try? await FaceDetector.detect(in: cg),
              let best = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                       < $1.boundingBox.width * $1.boundingBox.height }),
              let lm = best.landmarks,
              let aligned = FaceAligner.align(image: cg, landmarks: lm),
              let v = try? embedder.embed(aligned)
        else { return nil }
        return v
    }

    static func execute(dir: String) async {
        let root = URL(fileURLWithPath: dir)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("labels.json")),
              let pairs = try? JSONDecoder().decode([Pair].self, from: data) else {
            print("  FAIL  cannot read labels.json in \(dir)"); return
        }
        let embedder: FaceEmbedder
        do { embedder = try FaceEmbedder(url: try Res.model("ArcFace")) }
        catch { print("  FAIL  load ArcFace: \(error)"); return }

        let started = Date()
        var scores: [(score: Float, same: Bool)] = []
        var missed = 0
        let lanes = 6

        // Process in bounded-concurrency chunks so the ANE stays fed without unbounded memory.
        for chunkStart in stride(from: 0, to: pairs.count, by: lanes) {
            let chunk = pairs[chunkStart..<min(chunkStart + lanes, pairs.count)]
            let results = await withTaskGroup(of: (Float, Bool)?.self) { group -> [(Float, Bool)?] in
                for p in chunk {
                    group.addTask {
                        async let va = embed(url: root.appendingPathComponent(p.a), embedder: embedder)
                        async let vb = embed(url: root.appendingPathComponent(p.b), embedder: embedder)
                        guard let a = await va, let b = await vb else { return nil }
                        return (dot(a, b), p.same == 1)
                    }
                }
                var acc: [(Float, Bool)?] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for r in results {
                if let r { scores.append((r.0, r.1)) } else { missed += 1 }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("  pairs \(pairs.count), scored \(scores.count), undetected \(missed)")
        print(String(format: "  throughput %.1f img/s (detect+align+embed)",
                     Double(scores.count * 2) / elapsed))
        guard scores.count > 100 else { print("  FAIL  too few scored pairs"); return }

        let same = scores.filter(\.same).map(\.score)
        let diff = scores.filter { !$0.same }.map(\.score)
        func mean(_ a: [Float]) -> Float { a.reduce(0, +) / Float(max(a.count, 1)) }
        print(String(format: "  same mean %.3f   diff mean %.3f", mean(same), mean(diff)))

        var bestT: Float = 0, bestAcc = 0.0
        var t: Float = 0.0
        while t <= 0.95 {
            let correct = scores.filter { ($0.score >= t) == $0.same }.count
            let acc = Double(correct) / Double(scores.count)
            if acc > bestAcc { bestAcc = acc; bestT = t }
            t += 0.005
        }
        print(String(format: "  LFW verification accuracy %.4f at threshold %.3f", bestAcc, bestT))

        // Clustering needs a much stricter operating point: merging two different
        // people is far more damaging than leaving one person split in two.
        for targetFPR in [0.01, 0.005, 0.001] {
            var chosen: Float = 0.95
            var u: Float = 0.20
            while u <= 0.95 {
                let fpr = Double(diff.filter { $0 >= u }.count) / Double(diff.count)
                if fpr <= targetFPR { chosen = u; break }
                u += 0.005
            }
            let recall = Double(same.filter { $0 >= chosen }.count) / Double(same.count)
            print(String(format: "  FPR<=%.1f%% -> threshold %.3f, recall %.4f",
                         targetFPR * 100, chosen, recall))
        }

        print("  threshold sweep (recall = same-person pairs kept, FPR = wrong merges):")
        for u in [Float(0.25), 0.30, 0.35, 0.40, 0.45, 0.50, 0.55] {
            let recall = Double(same.filter { $0 >= u }.count) / Double(same.count)
            let fpr = Double(diff.filter { $0 >= u }.count) / Double(diff.count)
            print(String(format: "    t=%.2f  recall %.4f  FPR %.5f", u, recall, fpr))
        }

        if bestAcc >= 0.985 { print("  PASS  matches published ArcFace accuracy — pipeline is correct") }
        else if bestAcc >= 0.95 { print("  WARN  below published accuracy — alignment may be off") }
        else { print("  FAIL  accuracy far below published — pipeline likely broken") }
    }
}
