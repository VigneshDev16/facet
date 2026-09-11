import Foundation

/// Headless server mode, used for testing the sharing surface:
/// `Facet --serve --library <path> --port <n> --account user:pass`
enum ServeCommand {
    static func run(args: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let libPath = value("--library") ?? Res.appSupport.path
        let port = UInt16(value("--port") ?? "8765") ?? 8765

        let store: Store
        do { store = try Store(root: URL(fileURLWithPath: libPath)) }
        catch { print("cannot open library: \(error)"); exit(1) }

        let auth = Auth(store: store)
        if let spec = value("--account") {
            let parts = spec.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                do {
                    try auth.createAccount(username: String(parts[0]), password: String(parts[1]),
                                           isOwner: auth.accountCount == 0)
                    print("created account \(parts[0])")
                } catch { print("account: \(error.localizedDescription)") }
            }
        }
        guard auth.accountCount > 0 else { print("no accounts; pass --account user:pass"); exit(1) }

        let server = SharingServer(store: store, auth: auth)
        do { try server.start(port: port) }
        catch { print("listen failed: \(error)"); exit(1) }

        print("serving \(store.assetCount) photos on http://127.0.0.1:\(port)")
        fflush(stdout)
        dispatchMain()
    }
}
