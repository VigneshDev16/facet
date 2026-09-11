import Foundation
import CoreGraphics

/// Measures how well the detect -> align -> embed chain separates identities.
/// Expects `dir/<PersonName>/<image>.jpg`, i.e. LFW layout.
enum FaceBench {
    struct Sample { let person: String; let vec: [Float] }

    static func run(dir: String) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            await execute(dir: dir)
            sem.signal()
        }
        sem.wait()
    }

    static func execute(dir: String) async {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir)
        guard let people = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter({ $0.hasDirectoryPath }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { print("  FAIL  cannot read \(dir)"); return }

        let embedder: FaceEmbedder
        do { embedder = try FaceEmbedder(url: try Res.model("ArcFace")) }
        catch { print("  FAIL  load ArcFace: \(error)"); return }

        var samples: [Sample] = []
        var noFace = 0, imagesSeen = 0
        let started = Date()

        for p in people {
            let imgs = (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil))?
                .filter { ImageDecoder.isSupported($0) }.sorted(by: { $0.path < $1.path }) ?? []
            for img in imgs {
                imagesSeen += 1
                guard let cg = ImageDecoder.decode(url: img, maxPixel: 1600) else { continue }
                guard let faces = try? await FaceDetector.detect(in: cg), !faces.isEmpty else {
                    noFace += 1; continue
                }
                // Benchmark images are portraits: take the largest face.
                let best = faces.max { a, b in
                    a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
                }!
                guard let lm = best.landmarks,
                      let aligned = FaceAligner.align(image: cg, landmarks: lm),
                      let vec = try? embedder.embed(aligned)
                else { noFace += 1; continue }
                samples.append(Sample(person: p.lastPathComponent, vec: vec))
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("  images \(imagesSeen), embedded \(samples.count), no-face/failed \(noFace)")
        if imagesSeen > 0 {
            print(String(format: "  throughput %.1f img/s (detect+align+embed, %.1fs total)",
                         Double(imagesSeen) / elapsed, elapsed))
        }
        guard samples.count > 4 else { print("  FAIL  too few samples"); return }

        var same: [Float] = [], diff: [Float] = []
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let s = dot(samples[i].vec, samples[j].vec)
                if samples[i].person == samples[j].person { same.append(s) } else { diff.append(s) }
            }
        }
        guard !same.isEmpty, !diff.isEmpty else { print("  FAIL  need >=2 images for some person"); return }

        func stats(_ a: [Float]) -> (mean: Float, p5: Float, p50: Float, p95: Float) {
            let s = a.sorted()
            func q(_ f: Double) -> Float { s[min(s.count - 1, max(0, Int(f * Double(s.count - 1))))] }
            return (a.reduce(0, +) / Float(a.count), q(0.05), q(0.50), q(0.95))
        }
        let ss = stats(same), ds = stats(diff)
        print(String(format: "  same-person  n=%d  mean %.3f  p5 %.3f  p50 %.3f  p95 %.3f",
                     same.count, ss.mean, ss.p5, ss.p50, ss.p95))
        print(String(format: "  diff-person  n=%d  mean %.3f  p5 %.3f  p50 %.3f  p95 %.3f",
                     diff.count, ds.mean, ds.p5, ds.p50, ds.p95))

        // Sweep thresholds; report the one maximising balanced accuracy.
        var bestT: Float = 0, bestAcc = 0.0, bestTPR = 0.0, bestFPR = 0.0
        var t: Float = 0.10
        while t <= 0.80 {
            let tpr = Double(same.filter { $0 >= t }.count) / Double(same.count)
            let fpr = Double(diff.filter { $0 >= t }.count) / Double(diff.count)
            let acc = (tpr + (1 - fpr)) / 2
            if acc > bestAcc { bestAcc = acc; bestT = t; bestTPR = tpr; bestFPR = fpr }
            t += 0.01
        }
        print(String(format: "  best threshold %.2f -> balanced acc %.4f (TPR %.4f, FPR %.4f)",
                     bestT, bestAcc, bestTPR, bestFPR))

        // A usable clustering threshold needs a very low false-merge rate.
        var strictT: Float = 0.80
        var u: Float = 0.20
        while u <= 0.90 {
            let fpr = Double(diff.filter { $0 >= u }.count) / Double(diff.count)
            if fpr <= 0.001 { strictT = u; break }
            u += 0.01
        }
        let strictTPR = Double(same.filter { $0 >= strictT }.count) / Double(same.count)
        print(String(format: "  strict (FPR<=0.1%%) threshold %.2f -> recall %.4f", strictT, strictTPR))

        let separation = ss.p5 - ds.p95
        print(String(format: "  separation (same p5 - diff p95) = %.3f", separation))
        if bestAcc > 0.95 { print("  PASS  identity separation is strong") }
        else { print("  WARN  weak separation — check alignment") }
    }
}
