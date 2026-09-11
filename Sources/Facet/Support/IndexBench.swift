import Foundation

/// Runs the real pipeline (scan -> analyse -> cluster) over a folder tree and,
/// when each subfolder is one identity, scores the resulting grouping against it.
enum IndexBench {
    static func run(folder: String, libraryPath: String, threshold: Double?) {
        let sem = DispatchSemaphore(value: 0)
        Task { await execute(folder: folder, libraryPath: libraryPath, threshold: threshold); sem.signal() }
        sem.wait()
    }

    static func execute(folder: String, libraryPath: String, threshold: Double?) async {
        let root = URL(fileURLWithPath: libraryPath)
        try? FileManager.default.removeItem(at: root)

        let store: Store
        do { store = try Store(root: root) } catch { print("  FAIL  store: \(error)"); return }
        if let t = threshold { store.setSetting("clusterThreshold", String(t)) }

        let fe: FaceEmbedder
        let ce: ClipImageEmbedder
        do {
            fe = try FaceEmbedder(url: try Res.model("ArcFace"))
            ce = try ClipImageEmbedder(url: try Res.model("mobileclip_s2_image"))
        } catch { print("  FAIL  models: \(error)"); return }

        // Scan
        let folderID = (try? store.addFolder(path: folder, bookmark: nil)) ?? 0
        let fm = FileManager.default
        var files: [URL] = []
        if let en = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil) {
            for case let u as URL in en where ImageDecoder.isSupported(u) { files.append(u) }
        }
        try? store.db.transaction {
            for u in files {
                let attrs = try? fm.attributesOfItem(atPath: u.path)
                let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                _ = try? store.upsertAsset(folderID: folderID, url: u, bytes: bytes, mtime: mtime,
                                           meta: ImageDecoder.metadata(url: u))
            }
        }
        print("  scanned \(files.count) files -> \(store.assetCount) assets")

        // Analyse
        let started = Date()
        var processed = 0
        while true {
            let batch = store.pending(column: "face_state", limit: 64)
            if batch.isEmpty { break }
            await withTaskGroup(of: Void.self) { group in
                var it = batch.makeIterator()
                var running = 0
                func next() {
                    guard let a = it.next() else { return }
                    running += 1
                    group.addTask { await Indexer.process(asset: a, store: store, faces: fe, clip: ce) }
                }
                for _ in 0..<Tuning.lanes { next() }
                while running > 0 { await group.next(); running -= 1; next() }
            }
            processed += batch.count
        }
        let analyseTime = Date().timeIntervalSince(started)
        store.faceVectors.flush(); store.clipVectors.flush()
        print(String(format: "  analysed %d photos in %.1fs (%.1f photos/s)",
                     processed, analyseTime, Double(processed) / analyseTime))
        print("  faces detected: \(store.faceCount)")

        // Cluster
        let clusterStart = Date()
        Clusterer(store: store).run()
        print(String(format: "  clustered in %.2fs", Date().timeIntervalSince(clusterStart)))

        let people = store.people(includeHidden: true, minFaces: 0)
        let named = store.people(includeHidden: true, minFaces: 2)
        print("  clusters: \(people.count) total, \(named.count) with 2+ faces")

        score(store: store)
        checkSearch(store: store)
    }

    /// Pairwise precision/recall over faces whose ground-truth identity is the folder name.
    static func score(store: Store) {
        var identityOf: [Int64: String] = [:]   // faceID -> identity
        var clusterOf: [Int64: Int64] = [:]     // faceID -> personID
        try? store.db.query("""
            SELECT f.id, f.person_id, a.path FROM faces f
            JOIN assets a ON a.id = f.asset_id
            """) { s in
            let fid = s.int(0)
            let ident = URL(fileURLWithPath: s.string(2)).deletingLastPathComponent().lastPathComponent
            identityOf[fid] = ident
            if let p = s.intOpt(1) { clusterOf[fid] = p }
        }

        let assigned = identityOf.keys.filter { clusterOf[$0] != nil }
        print("  faces assigned to a person: \(assigned.count) of \(identityOf.count)")
        guard assigned.count > 10 else { print("  FAIL  too few assigned"); return }

        var tp = 0, fp = 0, fn = 0
        let arr = Array(assigned)
        for i in 0..<arr.count {
            for j in (i + 1)..<arr.count {
                let sameIdent = identityOf[arr[i]] == identityOf[arr[j]]
                let sameCluster = clusterOf[arr[i]] == clusterOf[arr[j]]
                if sameIdent && sameCluster { tp += 1 }
                else if !sameIdent && sameCluster { fp += 1 }
                else if sameIdent && !sameCluster { fn += 1 }
            }
        }
        let precision = Double(tp) / Double(max(tp + fp, 1))
        let recall = Double(tp) / Double(max(tp + fn, 1))
        let f1 = 2 * precision * recall / max(precision + recall, 1e-9)
        print(String(format: "  pairwise precision %.4f  recall %.4f  F1 %.4f", precision, recall, f1))

        // How often did one real person get split across clusters?
        var clustersPerIdentity: [String: Set<Int64>] = [:]
        for f in assigned {
            clustersPerIdentity[identityOf[f]!, default: []].insert(clusterOf[f]!)
        }
        let splits = clustersPerIdentity.filter { $0.value.count > 1 }.count
        let avg = Double(clustersPerIdentity.values.map(\.count).reduce(0, +)) / Double(max(clustersPerIdentity.count, 1))
        print(String(format: "  identities split across clusters: %d of %d (avg %.2f clusters each)",
                     splits, clustersPerIdentity.count, avg))

        if precision >= 0.95 { print("  PASS  grouping precision is high (few wrong merges)") }
        else { print("  WARN  precision below 0.95 — different people are being merged") }
    }

    /// Exercises the text-search path end to end.
    static func checkSearch(store: Store) {
        do {
            let tok = try CLIPTokenizer(vocabURL: Res.vocab())
            let te = try ClipTextEmbedder(url: try Res.model("mobileclip_s2_text"), tokenizer: tok)
            let v = try te.embed("a man wearing a suit and tie")
            let ids = store.search(AssetQuery(text: "a man wearing a suit and tie"), textVector: v, limit: 5)
            print("  text search returned \(ids.count) ranked results (top: \(ids.prefix(3).map(String.init).joined(separator: ", ")))")
            print(ids.isEmpty ? "  FAIL  text search returned nothing" : "  PASS  text search path works")
        } catch {
            print("  FAIL  text search: \(error)")
        }
    }
}
