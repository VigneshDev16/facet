import Foundation
import CoreGraphics

/// Command-line validation of the ML pipeline. Run via `Facet --selftest`.
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        if ok { print("  PASS  \(label) \(detail)") }
        else { failures += 1; print("  FAIL  \(label) \(detail)") }
    }

    static func run(args: [String]) {
        print("=== Facet self-test ===")
        testTokenizer(args: args)
        testClipText()
        testAlignmentMath()
        if let dir = value(of: "--faces", in: args) { testFaces(dir: dir) }
        if let dir = value(of: "--index", in: args) {
            print("\n[end-to-end index] \(dir)")
            let lib = value(of: "--library", in: args) ?? NSTemporaryDirectory() + "/facet-bench"
            IndexBench.run(folder: dir, libraryPath: lib, threshold: value(of: "--threshold", in: args).flatMap(Double.init))
        }
        if let dir = value(of: "--pairs", in: args) { print("\n[lfw pairs] \(dir)"); PairBench.run(dir: dir) }
        print(failures == 0 ? "\n=== ALL PASSED ===" : "\n=== \(failures) FAILURE(S) ===")
        exit(failures == 0 ? 0 : 1)
    }

    static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: tokenizer

    struct Fixture: Decodable { let text: String; let ids: [Int]; let full77: [Int] }

    static func testTokenizer(args: [String]) {
        print("\n[tokenizer]")
        guard let path = value(of: "--fixtures", in: args) else {
            print("  SKIP  no --fixtures given"); return
        }
        do {
            let tok = try CLIPTokenizer(vocabURL: Res.vocab())
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
            var bad = 0
            for f in fixtures {
                let got = tok.encode(f.text)
                if got != f.ids {
                    bad += 1
                    print("        \(f.text.debugDescription)\n          want \(f.ids)\n          got  \(got)")
                }
                let full = tok.tokenize(f.text).map(Int.init)
                if full != f.full77 { bad += 1; print("        ctx77 mismatch for \(f.text.debugDescription)") }
            }
            check(bad == 0, "matches OpenAI CLIP reference", "(\(fixtures.count) cases)")
        } catch {
            check(false, "tokenizer init", "\(error)")
        }
    }

    // MARK: CLIP text space

    static func testClipText() {
        print("\n[clip text]")
        do {
            let tok = try CLIPTokenizer(vocabURL: Res.vocab())
            let te = try ClipTextEmbedder(url: Res.model("mobileclip_s2_text"), tokenizer: tok)
            let dog = try te.embed("a photo of a dog")
            let puppy = try te.embed("a photo of a puppy")
            let plane = try te.embed("a photo of an airplane")
            check(dog.count == 512, "embedding dim", "\(dog.count)")
            let near = dot(dog, puppy), far = dot(dog, plane)
            check(near > far, "dog~puppy > dog~airplane",
                  String(format: "%.3f vs %.3f", near, far))
            check(abs(dot(dog, dog) - 1) < 1e-3, "L2 normalised",
                  String(format: "%.4f", dot(dog, dog)))
        } catch {
            check(false, "clip text", "\(error)")
        }
    }

    // MARK: alignment geometry

    static func testAlignmentMath() {
        print("\n[alignment]")
        // A known similarity applied to the template must be recovered exactly.
        let angle = 0.3, scale = 1.7, tx = 25.0, ty = -11.0
        let c = scale * cos(angle), s = scale * sin(angle)
        let src = FaceAligner.template.map {
            CGPoint(x: c * $0.x - s * $0.y + tx, y: s * $0.x + c * $0.y + ty)
        }
        guard let t = FaceAligner.similarityTransform(src: src, dst: FaceAligner.template) else {
            check(false, "transform solved"); return
        }
        var worst = 0.0
        for (p, want) in zip(src, FaceAligner.template) {
            let got = p.applying(t)
            worst = max(worst, hypot(got.x - want.x, got.y - want.y))
        }
        check(worst < 1e-6, "recovers known similarity", String(format: "max err %.2e px", worst))

        // Recovered scale should invert the one we applied.
        let recovered = sqrt(t.a * t.a + t.b * t.b)
        check(abs(recovered - 1 / scale) < 1e-9, "scale inverted",
              String(format: "%.6f vs %.6f", recovered, 1 / scale))
    }

    // MARK: faces

    static func testFaces(dir: String) {
        print("\n[faces] \(dir)")
        FaceBench.run(dir: dir)
    }
}
