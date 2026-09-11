import SwiftUI
import Combine
import AppKit

enum Route: Hashable {
    case library
    case people
    case person(Int64)
    case folder(Int64)
}

@MainActor
final class AppState: ObservableObject {
    let store: Store
    let indexer: Indexer
    let auth: Auth
    let sharing: SharingServer

    @Published var route: Route = .library { didSet { refresh() } }
    @Published var searchText: String = ""
    @Published var requiredPeople: [Int64] = [] { didSet { refresh() } }
    @Published var excludedPeople: [Int64] = [] { didSet { refresh() } }

    @Published private(set) var assets: [Asset] = []
    @Published private(set) var people: [PersonRow] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var searching = false
    @Published var statusMessage: String?

    @Published var thumbSize: Double = 168
    @Published var selection: Int64?
    /// Active "photos that look like this face" search, if any.
    @Published private(set) var similarFaceLabel: String?
    private var similarVector: [Float]?

    private var textEmbedder: ClipTextEmbedder?
    private var searchTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    // Remote sharing
    @Published var sharingEnabled = false
    @Published var sharingPort: Int = 8765
    @Published var keepAwake = true
    @Published private(set) var accounts: [Auth.Account] = []
    @Published var sharingError: String?
    private var awakeToken: NSObjectProtocol?

    init() throws {
        store = try Store()
        indexer = Indexer(store: store)
        auth = Auth(store: store)
        sharing = SharingServer(store: store, auth: auth)
        folders = store.folders()
        people = store.people()
        accounts = auth.accounts()
        sharingPort = Int(store.setting("sharing.port") ?? "") ?? 8765
        keepAwake = (store.setting("sharing.keepAwake") ?? "1") == "1"
        sharingEnabled = (store.setting("sharing.enabled") ?? "0") == "1"

        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(280), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        refresh()
        if sharingEnabled { startSharing() }
    }

    // MARK: sharing

    func startSharing() {
        guard !accounts.isEmpty else {
            sharingError = "Add at least one sign-in account first."
            sharingEnabled = false
            return
        }
        do {
            try sharing.start(port: UInt16(sharingPort))
            sharingEnabled = true
            sharingError = nil
            store.setSetting("sharing.enabled", "1")
            store.setSetting("sharing.port", String(sharingPort))
            applyKeepAwake()
        } catch {
            sharingEnabled = false
            sharingError = "Could not listen on port \(sharingPort): \(error.localizedDescription)"
        }
    }

    func stopSharing() {
        sharing.stop()
        sharingEnabled = false
        store.setSetting("sharing.enabled", "0")
        applyKeepAwake()
    }

    /// Holds a power assertion so an idle Mac stays reachable while sharing is on.
    func applyKeepAwake() {
        if let t = awakeToken { ProcessInfo.processInfo.endActivity(t); awakeToken = nil }
        store.setSetting("sharing.keepAwake", keepAwake ? "1" : "0")
        guard sharingEnabled, keepAwake else { return }
        awakeToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Facet remote access is on")
    }

    func addAccount(username: String, password: String, isOwner: Bool) -> String? {
        do {
            try auth.createAccount(username: username, password: password, isOwner: isOwner)
            accounts = auth.accounts()
            return nil
        } catch { return error.localizedDescription }
    }

    func resetPassword(accountID: Int64, password: String) -> String? {
        do { try auth.setPassword(accountID: accountID, password: password); return nil }
        catch { return error.localizedDescription }
    }

    func removeAccount(_ id: Int64) {
        auth.deleteAccount(id)
        accounts = auth.accounts()
        if accounts.isEmpty && sharingEnabled { stopSharing() }
    }

    func signOutEverywhere() { auth.revokeAllSessions() }

    var currentPerson: PersonRow? {
        if case .person(let id) = route { return people.first { $0.id == id } ?? store.person(id: id) }
        return nil
    }

    // MARK: refresh

    func refresh() {
        searchTask?.cancel()
        let text = searchText.trimmed
        var q = AssetQuery(text: text, requirePeople: requiredPeople, excludePeople: excludedPeople)

        switch route {
        case .library, .people: break
        case .person(let id): if !q.requirePeople.contains(id) { q.requirePeople.append(id) }
        case .folder(let id): q.folderID = id
        }

        let store = self.store
        let similar = similarVector
        searching = !text.isEmpty

        searchTask = Task { [weak self] in
            var textVec: [Float]?
            if !text.isEmpty {
                do {
                    let embedder = try await self?.ensureTextEmbedder()
                    textVec = try await Task.detached(priority: .userInitiated) {
                        try embedder?.embed(text)
                    }.value
                } catch {
                    await MainActor.run { self?.statusMessage = "Search unavailable: \(error)" }
                }
            }
            if Task.isCancelled { return }

            let ids = await Task.detached(priority: .userInitiated) { () -> [Int64] in
                if let similar {
                    // Rank by face similarity, then map faces back to their photos.
                    let hits = store.faceVectors.search(similar, topK: 4000,
                                                        minScore: Float(store.doubleSetting("searchThreshold",
                                                            default: Double(Tuning.defaultSearchThreshold))))
                    let map = store.assetIDs(forVectorRows: hits.map(\.row))
                    var seen = Set<Int64>()
                    var ordered: [Int64] = []
                    for h in hits {
                        guard let assetID = map[h.row] else { continue }
                        if seen.insert(assetID).inserted { ordered.append(assetID) }
                    }
                    return ordered
                }
                return store.search(q, textVector: textVec)
            }.value
            if Task.isCancelled { return }

            let rows = await Task.detached(priority: .userInitiated) { store.assets(ids: ids) }.value
            if Task.isCancelled { return }
            await MainActor.run {
                self?.assets = rows
                self?.searching = false
            }
        }
    }

    func reloadPeople() {
        people = store.people()
        folders = store.folders()
    }

    private func ensureTextEmbedder() async throws -> ClipTextEmbedder {
        if let e = textEmbedder { return e }
        let e = try await Task.detached(priority: .userInitiated) { () -> ClipTextEmbedder in
            let tok = try CLIPTokenizer(vocabURL: Res.vocab())
            return try ClipTextEmbedder(url: try Res.model("mobileclip_s2_text"), tokenizer: tok)
        }.value
        textEmbedder = e
        return e
    }

    // MARK: actions

    func findSimilar(to face: FaceRow, label: String) {
        guard let v = store.faceVectors.vector(at: face.vecRow) else { return }
        similarVector = v
        similarFaceLabel = label
        searchText = ""
        route = .library
        refresh()
    }

    func clearSimilar() {
        similarVector = nil
        similarFaceLabel = nil
        refresh()
    }

    func togglePersonFilter(_ id: Int64) {
        if let i = requiredPeople.firstIndex(of: id) { requiredPeople.remove(at: i) }
        else { requiredPeople.append(id) }
    }

    func toggleExcludePerson(_ id: Int64) {
        if let i = excludedPeople.firstIndex(of: id) { excludedPeople.remove(at: i) }
        else { excludedPeople.append(id) }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose folders of photos to import"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = try? store.addFolder(path: url.path, bookmark: bookmark)
        }
        folders = store.folders()
        indexer.start()
    }

    func removeFolder(_ id: Int64) {
        try? store.removeFolder(id)
        folders = store.folders()
        if case .folder(let current) = route, current == id { route = .library }
        refresh()
    }

    func rename(person id: Int64, to name: String) {
        store.rename(person: id, to: name)
        reloadPeople()
    }

    func revealInFinder(_ asset: Asset) {
        NSWorkspace.shared.activateFileViewerSelecting([asset.url])
    }

    func openExternally(_ asset: Asset) {
        NSWorkspace.shared.open(asset.url)
    }
}
