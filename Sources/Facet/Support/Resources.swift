import Foundation

enum Res {
    /// Resources resolve from the SPM bundle during development and from the
    /// app bundle's Resources directory once packaged.
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func model(_ name: String) throws -> URL {
        if let u = bundle.url(forResource: "Models/\(name)", withExtension: "mlmodelc") { return u }
        if let u = bundle.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") { return u }
        let fallback = bundle.bundleURL.appendingPathComponent("Contents/Resources/Models/\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        throw MLEngineError.modelMissing(name)
    }

    static func vocab() throws -> URL {
        if let u = bundle.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt") { return u }
        throw MLEngineError.modelMissing("bpe_simple_vocab_16e6.txt")
    }

    /// ~/Library/Application Support/Facet, or $FACET_LIBRARY when set (used for testing).
    static var appSupport: URL {
        if let override = ProcessInfo.processInfo.environment["FACET_LIBRARY"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Facet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
