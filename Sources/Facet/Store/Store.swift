import Foundation
import CoreGraphics

// MARK: - Domain types

struct Folder: Identifiable, Hashable {
    let id: Int64
    var path: String
    var lastScan: Date?
    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct Asset: Identifiable, Hashable {
    let id: Int64
    var folderID: Int64
    var path: String
    var filename: String
    var width: Int
    var height: Int
    var bytes: Int64
    var capturedAt: Date
    var camera: String?
    var url: URL { URL(fileURLWithPath: path) }
    var aspect: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 1 }
}

struct FaceRow: Identifiable, Hashable {
    let id: Int64
    var assetID: Int64
    var box: CGRect          // normalised, upper-left origin
    var quality: Float
    var personID: Int64?
    var vecRow: Int
    var confirmed: Bool
}

struct PersonRow: Identifiable, Hashable {
    let id: Int64
    var name: String?
    var coverFaceID: Int64?
    var faceCount: Int
    var hidden: Bool
    var displayName: String { name?.nilIfEmpty ?? "Unnamed" }
    var isNamed: Bool { name?.nilIfEmpty != nil }
}

enum IndexState: Int64 { case pending = 0, done = 1, failed = 2, skipped = 3 }

/// Filter/sort description for the photo grid.
struct AssetQuery: Equatable {
    var text: String = ""
    var requirePeople: [Int64] = []
    var excludePeople: [Int64] = []
    var folderID: Int64?
    var similarToVector: [Float]?     // face "find this person" search
    var newestFirst: Bool = true

    var isEmpty: Bool {
        text.trimmed.isEmpty && requirePeople.isEmpty && excludePeople.isEmpty
            && folderID == nil && similarToVector == nil
    }
}

// MARK: - Store

final class Store: @unchecked Sendable {
    let db: SQLiteDB
    let faceVectors: VectorStore
    let clipVectors: VectorStore
    let root: URL

    static let embeddingDim = 512

    init(root: URL = Res.appSupport) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = try SQLiteDB(path: root.appendingPathComponent("facet.sqlite").path)
        faceVectors = try VectorStore(url: root.appendingPathComponent("vectors/faces.f32"), dim: Self.embeddingDim)
        clipVectors = try VectorStore(url: root.appendingPathComponent("vectors/clip.f32"), dim: Self.embeddingDim)
        try migrate()
    }

    var thumbnailDir: URL { root.appendingPathComponent("thumbs", isDirectory: true) }

    func thumbnailURL(for assetID: Int64) -> URL {
        let shard = String(format: "%02x", UInt8(assetID & 0xFF))
        let dir = thumbnailDir.appendingPathComponent(shard, isDirectory: true)
        return dir.appendingPathComponent("\(assetID).jpg")
    }

    func faceThumbnailURL(for faceID: Int64) -> URL {
        let shard = String(format: "%02x", UInt8(faceID & 0xFF))
        let dir = root.appendingPathComponent("faces", isDirectory: true).appendingPathComponent(shard, isDirectory: true)
        return dir.appendingPathComponent("\(faceID).jpg")
    }

    // MARK: schema

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            bookmark BLOB,
            added_at REAL NOT NULL DEFAULT 0,
            last_scan_at REAL
        );

        CREATE TABLE IF NOT EXISTS assets (
            id INTEGER PRIMARY KEY,
            folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE,
            filename TEXT NOT NULL,
            bytes INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            captured_at REAL NOT NULL DEFAULT 0,
            camera TEXT,
            latitude REAL, longitude REAL,
            thumb_state INTEGER NOT NULL DEFAULT 0,
            face_state INTEGER NOT NULL DEFAULT 0,
            clip_state INTEGER NOT NULL DEFAULT 0,
            clip_row INTEGER NOT NULL DEFAULT -1,
            missing INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_assets_captured ON assets(captured_at DESC);
        CREATE INDEX IF NOT EXISTS idx_assets_folder ON assets(folder_id);
        CREATE INDEX IF NOT EXISTS idx_assets_face_state ON assets(face_state) WHERE face_state = 0;
        CREATE INDEX IF NOT EXISTS idx_assets_clip_state ON assets(clip_state) WHERE clip_state = 0;
        CREATE INDEX IF NOT EXISTS idx_assets_thumb_state ON assets(thumb_state) WHERE thumb_state = 0;

        CREATE TABLE IF NOT EXISTS people (
            id INTEGER PRIMARY KEY,
            name TEXT,
            cover_face_id INTEGER,
            hidden INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS faces (
            id INTEGER PRIMARY KEY,
            asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
            quality REAL NOT NULL DEFAULT 0,
            confidence REAL NOT NULL DEFAULT 0,
            roll REAL NOT NULL DEFAULT 0, yaw REAL NOT NULL DEFAULT 0, pitch REAL NOT NULL DEFAULT 0,
            vec_row INTEGER NOT NULL DEFAULT -1,
            person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
            confirmed INTEGER NOT NULL DEFAULT 0,
            clustered INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_faces_asset ON faces(asset_id);
        CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id);
        CREATE INDEX IF NOT EXISTS idx_faces_unclustered ON faces(clustered) WHERE clustered = 0;
        CREATE INDEX IF NOT EXISTS idx_faces_vecrow ON faces(vec_row);

        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }

    // MARK: settings

    func setting(_ key: String) -> String? {
        var out: String?
        try? db.query("SELECT value FROM settings WHERE key = ?", [key]) { out = $0.string(0) }
        return out
    }

    func setSetting(_ key: String, _ value: String) {
        try? db.run("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    func doubleSetting(_ key: String, default def: Double) -> Double {
        setting(key).flatMap(Double.init) ?? def
    }

    // MARK: folders

    @discardableResult
    func addFolder(path: String, bookmark: Data?) throws -> Int64 {
        try db.run("INSERT OR IGNORE INTO folders(path, bookmark, added_at) VALUES(?,?,?)",
                   [path, bookmark, Date().timeIntervalSince1970])
        return db.scalarInt("SELECT id FROM folders WHERE path = ?", [path])
    }

    func folders() -> [Folder] {
        var out: [Folder] = []
        try? db.query("SELECT id, path, last_scan_at FROM folders ORDER BY path") { s in
            out.append(Folder(id: s.int(0), path: s.string(1),
                              lastScan: s.doubleOpt(2).map { Date(timeIntervalSince1970: $0) }))
        }
        return out
    }

    func removeFolder(_ id: Int64) throws {
        // Vectors are append-only and keep their rows; orphaned rows are simply never referenced.
        try db.run("DELETE FROM folders WHERE id = ?", [id])
        try db.run("DELETE FROM people WHERE id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)")
    }

    func markScanned(_ folderID: Int64) {
        try? db.run("UPDATE folders SET last_scan_at = ? WHERE id = ?", [Date().timeIntervalSince1970, folderID])
    }

    // MARK: assets

    /// Inserts if new, or refreshes metadata and re-queues work if the file changed on disk.
    @discardableResult
    func upsertAsset(folderID: Int64, url: URL, bytes: Int64, mtime: Double, meta: ImageDecoder.Metadata) throws -> Int64 {
        let existing = db.scalarInt("SELECT id FROM assets WHERE path = ?", [url.path])
        let captured = (meta.capturedAt?.timeIntervalSince1970 ?? mtime)
        if existing > 0 {
            let storedMtime = { () -> Double in
                var m = 0.0
                try? db.query("SELECT mtime FROM assets WHERE id = ?", [existing]) { m = $0.double(0) }
                return m
            }()
            if abs(storedMtime - mtime) > 0.5 {
                try db.run("""
                    UPDATE assets SET bytes=?, mtime=?, width=?, height=?, captured_at=?, camera=?,
                        latitude=?, longitude=?, missing=0,
                        thumb_state=0, face_state=0, clip_state=0
                    WHERE id=?
                    """, [bytes, mtime, meta.width, meta.height, captured, meta.camera,
                          meta.latitude, meta.longitude, existing])
                try db.run("DELETE FROM faces WHERE asset_id = ?", [existing])
            } else {
                try db.run("UPDATE assets SET missing=0 WHERE id=?", [existing])
            }
            return existing
        }
        try db.run("""
            INSERT INTO assets(folder_id, path, filename, bytes, mtime, width, height, captured_at, camera, latitude, longitude)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [folderID, url.path, url.lastPathComponent, bytes, mtime,
                  meta.width, meta.height, captured, meta.camera, meta.latitude, meta.longitude])
        return db.lastInsertRowID
    }

    func markMissingOutside(folderID: Int64, presentPaths: Set<String>) {
        var toMark: [Int64] = []
        try? db.query("SELECT id, path FROM assets WHERE folder_id = ? AND missing = 0", [folderID]) { s in
            if !presentPaths.contains(s.string(1)) { toMark.append(s.int(0)) }
        }
        guard !toMark.isEmpty else { return }
        try? db.transaction {
            for id in toMark { try db.run("UPDATE assets SET missing = 1 WHERE id = ?", [id]) }
        }
    }

    func setState(_ column: String, _ state: IndexState, for assetID: Int64) {
        try? db.run("UPDATE assets SET \(column) = ? WHERE id = ?", [state.rawValue, assetID])
    }

    func setClipRow(_ row: Int, for assetID: Int64) {
        try? db.run("UPDATE assets SET clip_row = ?, clip_state = 1 WHERE id = ?", [row, assetID])
    }

    /// Next batch of assets still needing the given pipeline stage.
    func pending(column: String, limit: Int) -> [Asset] {
        var out: [Asset] = []
        try? db.query("""
            SELECT id, folder_id, path, filename, width, height, bytes, captured_at, camera
            FROM assets WHERE \(column) = 0 AND missing = 0
            ORDER BY captured_at DESC LIMIT ?
            """, [limit]) { out.append(Self.asset(from: $0)) }
        return out
    }

    func pendingCount(column: String) -> Int {
        Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE \(column) = 0 AND missing = 0"))
    }

    var assetCount: Int { Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE missing = 0")) }
    var faceCount: Int { Int(db.scalarInt("SELECT COUNT(*) FROM faces")) }

    private static func asset(from s: Statement) -> Asset {
        Asset(id: s.int(0), folderID: s.int(1), path: s.string(2), filename: s.string(3),
              width: Int(s.int(4)), height: Int(s.int(5)), bytes: s.int(6),
              capturedAt: Date(timeIntervalSince1970: s.double(7)), camera: s.stringOpt(8))
    }

    func assets(ids: [Int64]) -> [Asset] {
        guard !ids.isEmpty else { return [] }
        var byID: [Int64: Asset] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 900).map({ Array(ids[$0..<min($0 + 900, ids.count)]) }) {
            let ph = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try? db.query("""
                SELECT id, folder_id, path, filename, width, height, bytes, captured_at, camera
                FROM assets WHERE id IN (\(ph))
                """, chunk.map { $0 as SQLBindable }) { byID[$0.int(0)] = Self.asset(from: $0) }
        }
        return ids.compactMap { byID[$0] }
    }

    func asset(id: Int64) -> Asset? { assets(ids: [id]).first }

    // MARK: faces

    @discardableResult
    func insertFace(assetID: Int64, face: DetectedFace, vecRow: Int) throws -> Int64 {
        try db.run("""
            INSERT INTO faces(asset_id, x, y, w, h, quality, confidence, roll, yaw, pitch, vec_row)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [assetID, face.boundingBox.origin.x, face.boundingBox.origin.y,
                  face.boundingBox.width, face.boundingBox.height,
                  face.quality, face.confidence, face.roll, face.yaw, face.pitch, vecRow])
        return db.lastInsertRowID
    }

    private static func face(from s: Statement) -> FaceRow {
        FaceRow(id: s.int(0), assetID: s.int(1),
                box: CGRect(x: s.double(2), y: s.double(3), width: s.double(4), height: s.double(5)),
                quality: Float(s.double(6)), personID: s.intOpt(7), vecRow: Int(s.int(8)),
                confirmed: s.int(9) != 0)
    }

    private static let faceColumns = "id, asset_id, x, y, w, h, quality, person_id, vec_row, confirmed"

    func faces(forAsset id: Int64) -> [FaceRow] {
        var out: [FaceRow] = []
        try? db.query("SELECT \(Self.faceColumns) FROM faces WHERE asset_id = ? ORDER BY w*h DESC", [id]) {
            out.append(Self.face(from: $0))
        }
        return out
    }

    func faces(forPerson id: Int64, limit: Int = 5000) -> [FaceRow] {
        var out: [FaceRow] = []
        try? db.query("""
            SELECT \(Self.faceColumns) FROM faces WHERE person_id = ?
            ORDER BY confirmed DESC, quality DESC LIMIT ?
            """, [id, limit]) { out.append(Self.face(from: $0)) }
        return out
    }

    func face(id: Int64) -> FaceRow? {
        var out: FaceRow?
        try? db.query("SELECT \(Self.faceColumns) FROM faces WHERE id = ?", [id]) { out = Self.face(from: $0) }
        return out
    }

    /// Faces with a usable embedding that clustering has not yet placed.
    func unclusteredFaces(minQuality: Float, limit: Int = 200_000) -> [FaceRow] {
        var out: [FaceRow] = []
        try? db.query("""
            SELECT \(Self.faceColumns) FROM faces
            WHERE clustered = 0 AND vec_row >= 0 AND quality >= ?
            ORDER BY quality DESC LIMIT ?
            """, [minQuality, limit]) { out.append(Self.face(from: $0)) }
        return out
    }

    /// Faces too low-quality to seed a cluster, but still worth attaching to one.
    func unassignedFaces(limit: Int = 200_000) -> [FaceRow] {
        var out: [FaceRow] = []
        try? db.query("""
            SELECT \(Self.faceColumns) FROM faces
            WHERE person_id IS NULL AND clustered = 0 AND vec_row >= 0
            ORDER BY quality DESC LIMIT ?
            """, [limit]) { out.append(Self.face(from: $0)) }
        return out
    }

    func assign(faceID: Int64, personID: Int64?, confirmed: Bool = false) {
        try? db.run("UPDATE faces SET person_id = ?, clustered = 1, confirmed = ? WHERE id = ?",
                    [personID, confirmed, faceID])
    }

    func markClustered(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        try? db.transaction {
            for id in ids { try db.run("UPDATE faces SET clustered = 1 WHERE id = ?", [id]) }
        }
    }

    // MARK: people

    @discardableResult
    func createPerson(name: String? = nil, coverFaceID: Int64? = nil) throws -> Int64 {
        try db.run("INSERT INTO people(name, cover_face_id, created_at) VALUES(?,?,?)",
                   [name, coverFaceID, Date().timeIntervalSince1970])
        return db.lastInsertRowID
    }

    func people(includeHidden: Bool = false, minFaces: Int = 2) -> [PersonRow] {
        var out: [PersonRow] = []
        let hiddenClause = includeHidden ? "" : "AND p.hidden = 0"
        try? db.query("""
            SELECT p.id, p.name, p.cover_face_id, p.hidden, COUNT(f.id) AS n
            FROM people p LEFT JOIN faces f ON f.person_id = p.id
            WHERE 1=1 \(hiddenClause)
            GROUP BY p.id
            HAVING n >= ? OR p.name IS NOT NULL
            ORDER BY (p.name IS NULL), n DESC
            """, [minFaces]) { s in
            out.append(PersonRow(id: s.int(0), name: s.stringOpt(1), coverFaceID: s.intOpt(2),
                                 faceCount: Int(s.int(4)), hidden: s.int(3) != 0))
        }
        return out
    }

    func person(id: Int64) -> PersonRow? { people(includeHidden: true, minFaces: 0).first { $0.id == id } }

    func rename(person id: Int64, to name: String?) {
        try? db.run("UPDATE people SET name = ? WHERE id = ?", [name?.trimmed.nilIfEmpty, id])
    }

    func setHidden(person id: Int64, _ hidden: Bool) {
        try? db.run("UPDATE people SET hidden = ? WHERE id = ?", [hidden, id])
    }

    func setCover(person id: Int64, faceID: Int64) {
        try? db.run("UPDATE people SET cover_face_id = ? WHERE id = ?", [faceID, id])
    }

    /// Folds `source` into `target`, keeping whichever name already exists.
    func merge(person source: Int64, into target: Int64) {
        try? db.transaction {
            try db.run("UPDATE faces SET person_id = ? WHERE person_id = ?", [target, source])
            try db.run("""
                UPDATE people SET name = COALESCE(name, (SELECT name FROM people WHERE id = ?))
                WHERE id = ?
                """, [source, target])
            try db.run("DELETE FROM people WHERE id = ?", [source])
        }
    }

    func deletePerson(_ id: Int64) {
        try? db.transaction {
            // Detach faces and exclude them from future automatic clustering.
            try db.run("UPDATE faces SET person_id = NULL, clustered = 1 WHERE person_id = ?", [id])
            try db.run("DELETE FROM people WHERE id = ?", [id])
        }
    }

    /// Maps face vector rows back to their photos, in one query per chunk.
    func assetIDs(forVectorRows rows: [Int]) -> [Int: Int64] {
        guard !rows.isEmpty else { return [:] }
        var out: [Int: Int64] = [:]
        for chunk in stride(from: 0, to: rows.count, by: 900).map({ Array(rows[$0..<min($0 + 900, rows.count)]) }) {
            let ph = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try? db.query("SELECT vec_row, asset_id FROM faces WHERE vec_row IN (\(ph))",
                          chunk.map { $0 as SQLBindable }) { out[Int($0.int(0))] = $0.int(1) }
        }
        return out
    }

    func vectorRows(forPerson id: Int64) -> [Int] {
        var out: [Int] = []
        try? db.query("SELECT vec_row FROM faces WHERE person_id = ? AND vec_row >= 0", [id]) {
            out.append(Int($0.int(0)))
        }
        return out
    }

    // MARK: query

    /// Resolves a filter into an ordered list of asset ids.
    func search(_ q: AssetQuery, textVector: [Float]?, limit: Int = 20_000) -> [Int64] {
        var wheres = ["a.missing = 0"]
        var binds: [SQLBindable?] = []

        if let f = q.folderID { wheres.append("a.folder_id = ?"); binds.append(f) }

        if !q.requirePeople.isEmpty {
            let ph = Array(repeating: "?", count: q.requirePeople.count).joined(separator: ",")
            wheres.append("""
                (SELECT COUNT(DISTINCT f.person_id) FROM faces f
                 WHERE f.asset_id = a.id AND f.person_id IN (\(ph))) = ?
                """)
            binds.append(contentsOf: q.requirePeople.map { $0 as SQLBindable })
            binds.append(q.requirePeople.count)
        }
        if !q.excludePeople.isEmpty {
            let ph = Array(repeating: "?", count: q.excludePeople.count).joined(separator: ",")
            wheres.append("NOT EXISTS (SELECT 1 FROM faces f2 WHERE f2.asset_id = a.id AND f2.person_id IN (\(ph)))")
            binds.append(contentsOf: q.excludePeople.map { $0 as SQLBindable })
        }

        let ranked = textVector != nil || q.similarToVector != nil
        let order = ranked ? "" : "ORDER BY a.captured_at \(q.newestFirst ? "DESC" : "ASC")"
        var ids: [Int64] = []
        var clipRows: [Int64: Int] = [:]

        try? db.query("""
            SELECT a.id, a.clip_row FROM assets a
            WHERE \(wheres.joined(separator: " AND ")) \(order) LIMIT ?
            """, binds + [limit]) { s in
            let id = s.int(0)
            ids.append(id)
            clipRows[id] = Int(s.int(1))
        }

        // Rank by semantic similarity when a text query is active.
        if let tv = textVector {
            let scores = clipVectors.scores(for: tv)
            let scored = ids.compactMap { id -> (Int64, Float)? in
                guard let r = clipRows[id], r >= 0, r < scores.count else { return nil }
                return (id, scores[r])
            }
            return scored.sorted { $0.1 > $1.1 }.map(\.0)
        }
        return ids
    }
}
