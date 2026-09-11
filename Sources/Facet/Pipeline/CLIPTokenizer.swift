import Foundation

/// Port of OpenAI CLIP's `SimpleTokenizer` (byte-level BPE, 49408 vocab, 77 ctx).
/// MobileCLIP's text encoder expects exactly this tokenisation.
final class CLIPTokenizer {
    static let contextLength = 77
    private static let sotToken = 49406
    private static let eotToken = 49407

    private var encoder: [String: Int] = [:]
    private var bpeRanks: [Pair: Int] = [:]
    private var byteEncoder: [UInt8: Character] = [:]
    private var cache: [String: [String]] = [:]
    private let pattern: NSRegularExpression

    struct Pair: Hashable { let a: String; let b: String }

    init(vocabURL: URL) throws {
        // CLIP's regex: contractions, letter runs, single digits, punctuation runs.
        pattern = try NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive])

        byteEncoder = Self.bytesToUnicode()

        let raw = try String(contentsOf: vocabURL, encoding: .utf8)
        var lines = raw.components(separatedBy: "\n")
        // Line 0 is "#version: 0.2"; CLIP keeps merges[1 : 49152-256-2+1].
        let upper = min(49152 - 256 - 2 + 1, lines.count)
        lines = Array(lines[1..<upper])

        var merges: [Pair] = []
        merges.reserveCapacity(lines.count)
        for line in lines {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            merges.append(Pair(a: String(parts[0]), b: String(parts[1])))
        }

        // Vocab order: 256 byte chars, then the same with </w>, then merged pairs, then specials.
        var vocab: [String] = byteEncoderOrderedValues()
        vocab += vocab.map { $0 + "</w>" }
        for m in merges { vocab.append(m.a + m.b) }
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        encoder = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($0.element, $0.offset) })
        bpeRanks = Dictionary(uniqueKeysWithValues: merges.enumerated().map { ($0.element, $0.offset) })
    }

    /// Byte values that map to printable glyphs, in CLIP's canonical order.
    private func byteEncoderOrderedValues() -> [String] {
        var bs: [UInt8] = []
        bs += Array(UInt8(ascii: "!")...UInt8(ascii: "~"))
        bs += Array(UInt8(0xA1)...UInt8(0xAC))
        bs += Array(UInt8(0xAE)...UInt8(0xFF))
        var out = bs.map { String(byteEncoder[$0]!) }
        for b in 0...255 where !bs.contains(UInt8(b)) {
            out.append(String(byteEncoder[UInt8(b)]!))
        }
        return out
    }

    private static func bytesToUnicode() -> [UInt8: Character] {
        var bs: [Int] = []
        bs += Array(Int(UInt8(ascii: "!"))...Int(UInt8(ascii: "~")))
        bs += Array(0xA1...0xAC)
        bs += Array(0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            map[UInt8(b)] = Character(UnicodeScalar(UInt32(c))!)
        }
        return map
    }

    private func pairs(_ word: [String]) -> Set<Pair> {
        guard word.count > 1 else { return [] }
        var out = Set<Pair>()
        for i in 0..<(word.count - 1) { out.insert(Pair(a: word[i], b: word[i + 1])) }
        return out
    }

    /// Applies the learned merge list to one whitespace-delimited token.
    private func bpe(_ token: String) -> [String] {
        if let hit = cache[token] { return hit }
        guard !token.isEmpty else { return [] }

        var word = token.map { String($0) }
        word[word.count - 1] += "</w>"

        var current = pairs(word)
        while !current.isEmpty {
            // Pick the merge with the lowest (earliest-learned) rank.
            var best: Pair?
            var bestRank = Int.max
            for p in current {
                if let r = bpeRanks[p], r < bestRank { bestRank = r; best = p }
            }
            guard let bigram = best else { break }

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if let j = word[i...].firstIndex(of: bigram.a) {
                    newWord.append(contentsOf: word[i..<j])
                    i = j
                } else {
                    newWord.append(contentsOf: word[i...])
                    break
                }
                if word[i] == bigram.a, i < word.count - 1, word[i + 1] == bigram.b {
                    newWord.append(bigram.a + bigram.b)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
            current = pairs(word)
        }
        cache[token] = word
        return word
    }

    /// Lowercases, collapses whitespace, and splits into BPE token ids (no specials).
    func encode(_ text: String) -> [Int] {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var ids: [Int] = []
        let ns = cleaned as NSString
        let matches = pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let tok = ns.substring(with: m.range)
            // Byte-level: every UTF-8 byte becomes a printable stand-in glyph.
            let mapped = String(Array(tok.utf8).map { byteEncoder[$0]! })
            for piece in bpe(mapped) {
                if let id = encoder[piece] { ids.append(id) }
            }
        }
        return ids
    }

    /// Full 77-slot context: `<sot> … <eot>` zero-padded, truncated if needed.
    func tokenize(_ text: String) -> [Int32] {
        var ids = [Self.sotToken] + encode(text)
        if ids.count > Self.contextLength - 1 {
            ids = Array(ids.prefix(Self.contextLength - 1))
        }
        ids.append(Self.eotToken)
        var out = [Int32](repeating: 0, count: Self.contextLength)
        for (i, v) in ids.enumerated() { out[i] = Int32(v) }
        return out
    }
}
