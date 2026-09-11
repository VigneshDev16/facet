import Foundation
import CoreGraphics
import AppKit

/// Read-only sharing server: browse, search, view and download.
///
/// There are deliberately **no** mutating endpoints — nothing here can delete,
/// rename, re-group or re-index anything. Managing the library stays in the Mac app,
/// so "viewers can't delete" is a property of the surface area, not a permission flag.
final class SharingServer: @unchecked Sendable {
    private let store: Store
    private let auth: Auth
    private var server: HTTPServer?
    private let lock = NSLock()
    private var textEmbedder: ClipTextEmbedder?

    static let cookieName = "facet_session"
    private(set) var port: UInt16 = 8765

    init(store: Store, auth: Auth) {
        self.store = store
        self.auth = auth
    }

    var isRunning: Bool { server != nil }

    func start(port: UInt16) throws {
        stop()
        auth.purgeExpired()
        let s = HTTPServer(port: port) { [weak self] req in
            guard let self else { return .status(500) }
            return self.route(req)
        }
        try s.start()
        server = s
        self.port = port
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private var webCacheDir: URL {
        let u = store.root.appendingPathComponent("webcache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: routing

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        // Public endpoints: the login page and the login POST itself.
        if req.path == "/login" && req.method == "GET" { return page() }
        if req.path == "/api/login" && req.method == "POST" { return handleLogin(req) }
        if req.path == "/manifest.webmanifest" { return manifest() }

        guard let account = currentAccount(req) else {
            // Only navigable HTML routes fall back to the sign-in page. Every asset and
            // API route answers 401 so an unauthenticated fetch can never look like a hit.
            if req.method == "GET", req.path == "/" || req.path == "/index.html" { return page() }
            return .status(401, "Please sign in again.")
        }

        // Everything past this point is read-only by construction.
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return page()
        case ("POST", "/api/logout"):
            if let t = req.cookies[Self.cookieName] { auth.logout(token: t) }
            var res = HTTPResponse.json(["ok": true])
            res.headers["Set-Cookie"] = expiredCookie(secure: req.isSecure)
            return res
        case ("GET", "/api/me"):
            return .json(["username": account.username, "owner": account.isOwner,
                          "photos": store.assetCount, "people": store.people().count])
        case ("GET", "/api/photos"):
            return handlePhotos(req)
        case ("GET", "/api/people"):
            return handlePeople()
        default:
            if req.method == "GET", req.path.hasPrefix("/api/photo/") {
                return handlePhotoDetail(id: idSuffix(req.path, "/api/photo/"))
            }
            if req.method == "GET", req.path.hasPrefix("/thumb/") {
                return serveThumb(id: idSuffix(req.path, "/thumb/"))
            }
            if req.method == "GET", req.path.hasPrefix("/face/") {
                return serveFaceThumb(id: idSuffix(req.path, "/face/"))
            }
            if req.method == "GET", req.path.hasPrefix("/image/") {
                return serveImage(id: idSuffix(req.path, "/image/"),
                                  size: Int(req.query["w"] ?? "") ?? 1600)
            }
            if req.method == "GET", req.path.hasPrefix("/download/") {
                return serveOriginal(id: idSuffix(req.path, "/download/"))
            }
            return .status(404)
        }
    }

    private func idSuffix(_ path: String, _ prefix: String) -> Int64 {
        Int64(path.dropFirst(prefix.count).split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    private func currentAccount(_ req: HTTPRequest) -> Auth.Account? {
        guard let token = req.cookies[Self.cookieName] else { return nil }
        return auth.account(forToken: token)
    }

    // MARK: auth endpoints

    private func handleLogin(_ req: HTTPRequest) -> HTTPResponse {
        let fields: [String: String]
        if let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: String] {
            fields = json
        } else {
            fields = req.formFields
        }
        guard let user = fields["username"], let pass = fields["password"] else {
            return .status(400, "Missing username or password.")
        }
        guard let token = auth.login(username: user, password: pass, clientKey: req.clientAddress) else {
            return .status(401, "Wrong username or password.")
        }
        var res = HTTPResponse.json(["ok": true])
        res.headers["Set-Cookie"] = sessionCookie(token, secure: req.isSecure)
        return res
    }

    private func sessionCookie(_ token: String, secure: Bool) -> String {
        var c = "\(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Lax; Max-Age=\(Int(Auth.sessionLifetime))"
        if secure { c += "; Secure" }
        return c
    }

    private func expiredCookie(secure: Bool) -> String {
        var c = "\(Self.cookieName)=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        if secure { c += "; Secure" }
        return c
    }

    // MARK: data endpoints

    private func photoJSON(_ a: Asset) -> [String: Any] {
        ["id": a.id, "name": a.filename, "w": a.width, "h": a.height,
         "date": ISO8601DateFormatter().string(from: a.capturedAt),
         "bytes": a.bytes]
    }

    private func handlePhotos(_ req: HTTPRequest) -> HTTPResponse {
        let limit = min(max(Int(req.query["limit"] ?? "") ?? 100, 1), 500)
        let offset = max(Int(req.query["offset"] ?? "") ?? 0, 0)
        let text = (req.query["q"] ?? "").trimmed

        var q = AssetQuery(text: text)
        if let p = req.query["person"], let pid = Int64(p) { q.requirePeople = [pid] }
        if let p = req.query["with"], let pid = Int64(p) { q.requirePeople.append(pid) }
        if let p = req.query["without"], let pid = Int64(p) { q.excludePeople = [pid] }
        if let f = req.query["folder"], let fid = Int64(f) { q.folderID = fid }

        var ids: [Int64] = []
        if let faceParam = req.query["similar"], let faceID = Int64(faceParam) {
            ids = similarAssetIDs(faceID: faceID)
        } else {
            var vector: [Float]?
            if !text.isEmpty {
                do { vector = try embedText(text) }
                catch { return .status(500, "Search is unavailable: \(error)") }
            }
            ids = store.search(q, textVector: vector)
        }

        let total = ids.count
        let page = Array(ids.dropFirst(offset).prefix(limit))
        let assets = store.assets(ids: page)
        return .json(["total": total, "offset": offset,
                      "photos": assets.map(photoJSON)])
    }

    private func similarAssetIDs(faceID: Int64) -> [Int64] {
        guard let face = store.face(id: faceID),
              let vec = store.faceVectors.vector(at: face.vecRow) else { return [] }
        let threshold = Float(store.doubleSetting("searchThreshold", default: Double(Tuning.defaultSearchThreshold)))
        let hits = store.faceVectors.search(vec, topK: 4000, minScore: threshold)
        let map = store.assetIDs(forVectorRows: hits.map(\.row))
        var seen = Set<Int64>(), ordered: [Int64] = []
        for h in hits {
            guard let a = map[h.row] else { continue }
            if seen.insert(a).inserted { ordered.append(a) }
        }
        return ordered
    }

    private func handlePeople() -> HTTPResponse {
        let people = store.people().map { p -> [String: Any] in
            var d: [String: Any] = ["id": p.id, "name": p.displayName, "named": p.isNamed, "count": p.faceCount]
            if let c = p.coverFaceID { d["cover"] = c }
            return d
        }
        return .json(["people": people])
    }

    private func handlePhotoDetail(id: Int64) -> HTTPResponse {
        guard let asset = store.asset(id: id) else { return .status(404) }
        let names = Dictionary(uniqueKeysWithValues: store.people(includeHidden: true, minFaces: 0).map { ($0.id, $0) })
        let faces = store.faces(forAsset: id).map { f -> [String: Any] in
            var d: [String: Any] = ["id": f.id, "x": f.box.origin.x, "y": f.box.origin.y,
                                    "w": f.box.width, "h": f.box.height]
            if let pid = f.personID {
                d["person"] = pid
                if let n = names[pid]?.name?.nilIfEmpty { d["name"] = n }
            }
            return d
        }
        var out = photoJSON(asset)
        out["faces"] = faces
        out["camera"] = asset.camera ?? ""
        return .json(out)
    }

    private func embedText(_ text: String) throws -> [Float] {
        try lock.withLock {
            if textEmbedder == nil {
                let tok = try CLIPTokenizer(vocabURL: Res.vocab())
                textEmbedder = try ClipTextEmbedder(url: try Res.model("mobileclip_s2_text"), tokenizer: tok)
            }
        }
        return try textEmbedder!.embed(text)
    }

    // MARK: image endpoints

    private func serveThumb(id: Int64) -> HTTPResponse {
        guard let data = try? Data(contentsOf: store.thumbnailURL(for: id)) else {
            return regenerate(id: id, maxPixel: Tuning.thumbMaxPixel)
        }
        return .bytes(data, type: "image/jpeg", cacheSeconds: 86_400)
    }

    private func serveFaceThumb(id: Int64) -> HTTPResponse {
        guard let data = try? Data(contentsOf: store.faceThumbnailURL(for: id)) else { return .status(404) }
        return .bytes(data, type: "image/jpeg", cacheSeconds: 86_400)
    }

    /// Mid-size render for the phone viewer, cached on disk after the first request.
    /// Always JPEG — mobile browsers handle HEIC and RAW poorly.
    private func serveImage(id: Int64, size: Int) -> HTTPResponse {
        let clamped = min(max(size, 320), 3000)
        let cached = webCacheDir.appendingPathComponent("\(id)-\(clamped).jpg")
        if let d = try? Data(contentsOf: cached) {
            return .bytes(d, type: "image/jpeg", cacheSeconds: 86_400)
        }
        guard let asset = store.asset(id: id),
              let cg = ImageDecoder.decode(url: asset.url, maxPixel: clamped),
              let jpeg = ImageDecoder.jpegThumbnail(from: cg, maxPixel: clamped, quality: 0.82)
        else { return .status(404) }
        try? jpeg.write(to: cached, options: .atomic)
        return .bytes(jpeg, type: "image/jpeg", cacheSeconds: 86_400)
    }

    private func regenerate(id: Int64, maxPixel: Int) -> HTTPResponse {
        guard let asset = store.asset(id: id),
              let cg = ImageDecoder.decode(url: asset.url, maxPixel: maxPixel),
              let jpeg = ImageDecoder.jpegThumbnail(from: cg, maxPixel: maxPixel)
        else { return .status(404) }
        return .bytes(jpeg, type: "image/jpeg", cacheSeconds: 3600)
    }

    /// The original file, as-is. Downloading is explicitly allowed; deleting is not possible.
    private func serveOriginal(id: Int64) -> HTTPResponse {
        guard let asset = store.asset(id: id) else { return .status(404) }
        guard let data = try? Data(contentsOf: asset.url, options: .mappedIfSafe) else {
            return .status(404, "That file is no longer on this Mac.")
        }
        let ext = asset.url.pathExtension.lowercased()
        let type = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
                    "heic": "image/heic", "gif": "image/gif", "tif": "image/tiff",
                    "tiff": "image/tiff", "webp": "image/webp"][ext] ?? "application/octet-stream"
        return .bytes(data, type: type, filename: asset.filename)
    }

    // MARK: static

    private func page() -> HTTPResponse {
        guard let url = Res.bundle.url(forResource: "web/index", withExtension: "html")
                ?? Res.bundle.url(forResource: "index", withExtension: "html", subdirectory: "web"),
              let html = try? String(contentsOf: url, encoding: .utf8)
        else { return .html("<h1>Facet</h1><p>Web UI resource missing from the app bundle.</p>", status: 500) }
        var res = HTTPResponse.html(html)
        // The page is fully self-contained; block any external loading outright.
        res.headers["Content-Security-Policy"] =
            "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'self'"
        return res
    }

    private func manifest() -> HTTPResponse {
        .json(["name": "Facet", "short_name": "Facet", "start_url": "/", "display": "standalone",
               "background_color": "#111113", "theme_color": "#111113",
               "icons": [["src": "/icon.png", "sizes": "512x512", "type": "image/png"]]])
    }
}
