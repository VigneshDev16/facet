import Foundation
import CommonCrypto
import Security

/// Accounts and sessions for the read-only sharing server.
///
/// Passwords are stored as PBKDF2-HMAC-SHA256 hashes; session tokens are random
/// 256-bit values stored only as SHA-256 digests, so a copy of the database does
/// not hand an attacker usable sessions.
final class Auth: @unchecked Sendable {
    private let store: Store
    /// OWASP's floor for PBKDF2-HMAC-SHA256.
    static let iterations: UInt32 = 210_000
    static let sessionLifetime: TimeInterval = 60 * 60 * 24 * 30

    struct Account: Identifiable, Hashable {
        let id: Int64
        var username: String
        var isOwner: Bool
        var createdAt: Date
    }

    init(store: Store) {
        self.store = store
        try? store.db.exec("""
        CREATE TABLE IF NOT EXISTS accounts (
            id INTEGER PRIMARY KEY,
            username TEXT NOT NULL UNIQUE COLLATE NOCASE,
            salt BLOB NOT NULL,
            hash BLOB NOT NULL,
            iterations INTEGER NOT NULL,
            is_owner INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
            token_hash BLOB PRIMARY KEY,
            account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            label TEXT
        );
        CREATE TABLE IF NOT EXISTS login_attempts (
            key TEXT PRIMARY KEY,
            failures INTEGER NOT NULL DEFAULT 0,
            locked_until REAL NOT NULL DEFAULT 0
        );
        """)
    }

    // MARK: crypto helpers

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        if ok != errSecSuccess {
            // SecRandom should not fail; fall back to the system CSPRNG rather than weak bytes.
            var g = SystemRandomNumberGenerator()
            d = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
        }
        return d
    }

    static func pbkdf2(password: String, salt: Data, iterations: UInt32) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                    saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
            }
        }
        return out
    }

    static func sha256(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { d in
            data.withUnsafeBytes { s in
                _ = CC_SHA256(s.baseAddress, CC_LONG(data.count),
                              d.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        return digest
    }

    /// Length-independent, value-constant-time comparison.
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: accounts

    var accountCount: Int { Int(store.db.scalarInt("SELECT COUNT(*) FROM accounts")) }

    func accounts() -> [Account] {
        var out: [Account] = []
        try? store.db.query("SELECT id, username, is_owner, created_at FROM accounts ORDER BY is_owner DESC, username") { s in
            out.append(Account(id: s.int(0), username: s.string(1), isOwner: s.int(2) != 0,
                               createdAt: Date(timeIntervalSince1970: s.double(3))))
        }
        return out
    }

    enum AuthError: LocalizedError {
        case usernameTaken, weakPassword, notFound
        var errorDescription: String? {
            switch self {
            case .usernameTaken: return "That username is already taken."
            case .weakPassword: return "Use at least 8 characters."
            case .notFound: return "No such account."
            }
        }
    }

    @discardableResult
    func createAccount(username: String, password: String, isOwner: Bool) throws -> Int64 {
        let name = username.trimmed
        guard password.count >= 8 else { throw AuthError.weakPassword }
        guard !name.isEmpty else { throw AuthError.notFound }
        if store.db.scalarInt("SELECT COUNT(*) FROM accounts WHERE username = ?", [name]) > 0 {
            throw AuthError.usernameTaken
        }
        let salt = Self.randomBytes(16)
        let hash = Self.pbkdf2(password: password, salt: salt, iterations: Self.iterations)
        try store.db.run("""
            INSERT INTO accounts(username, salt, hash, iterations, is_owner, created_at)
            VALUES(?,?,?,?,?,?)
            """, [name, salt, hash, Int(Self.iterations), isOwner, Date().timeIntervalSince1970])
        return store.db.lastInsertRowID
    }

    func setPassword(accountID: Int64, password: String) throws {
        guard password.count >= 8 else { throw AuthError.weakPassword }
        let salt = Self.randomBytes(16)
        let hash = Self.pbkdf2(password: password, salt: salt, iterations: Self.iterations)
        try store.db.run("UPDATE accounts SET salt = ?, hash = ?, iterations = ? WHERE id = ?",
                         [salt, hash, Int(Self.iterations), accountID])
        // Changing a password invalidates that account's existing sessions.
        try store.db.run("DELETE FROM sessions WHERE account_id = ?", [accountID])
    }

    func deleteAccount(_ id: Int64) {
        try? store.db.run("DELETE FROM sessions WHERE account_id = ?", [id])
        try? store.db.run("DELETE FROM accounts WHERE id = ?", [id])
    }

    // MARK: login

    /// Returns a session token on success. Throttles repeated failures per username.
    func login(username: String, password: String, clientKey: String) -> String? {
        let name = username.trimmed
        let throttleKey = "\(name.lowercased())|\(clientKey)"
        let now = Date().timeIntervalSince1970

        var lockedUntil = 0.0
        try? store.db.query("SELECT locked_until FROM login_attempts WHERE key = ?", [throttleKey]) {
            lockedUntil = $0.double(0)
        }
        if lockedUntil > now { return nil }

        var accountID: Int64 = 0
        var salt = Data(), expected = Data()
        var iters: UInt32 = Self.iterations
        try? store.db.query("SELECT id, salt, hash, iterations FROM accounts WHERE username = ?", [name]) { s in
            accountID = s.int(0); salt = s.blob(1); expected = s.blob(2); iters = UInt32(s.int(3))
        }

        // Always run the KDF so a missing username costs the same as a wrong password.
        let probeSalt = salt.isEmpty ? Self.randomBytes(16) : salt
        let candidate = Self.pbkdf2(password: password, salt: probeSalt, iterations: iters)
        let ok = accountID > 0 && Self.constantTimeEquals(candidate, expected)

        guard ok else {
            recordFailure(throttleKey, now: now)
            return nil
        }
        try? store.db.run("DELETE FROM login_attempts WHERE key = ?", [throttleKey])

        let token = Self.randomBytes(32)
        try? store.db.run("INSERT INTO sessions(token_hash, account_id, created_at, expires_at) VALUES(?,?,?,?)",
                          [Self.sha256(token), accountID, now, now + Self.sessionLifetime])
        return token.base64URLEncoded
    }

    private func recordFailure(_ key: String, now: TimeInterval) {
        var failures = 0
        try? store.db.query("SELECT failures FROM login_attempts WHERE key = ?", [key]) { failures = Int($0.int(0)) }
        failures += 1
        // Back off hard after 5 bad attempts: 30s, doubling to a 15-minute cap.
        let lockFor = failures >= 5 ? min(900.0, 30.0 * pow(2.0, Double(failures - 5))) : 0
        try? store.db.run("""
            INSERT INTO login_attempts(key, failures, locked_until) VALUES(?,?,?)
            ON CONFLICT(key) DO UPDATE SET failures = excluded.failures, locked_until = excluded.locked_until
            """, [key, failures, now + lockFor])
    }

    func account(forToken token: String) -> Account? {
        guard let raw = Data(base64URLEncoded: token) else { return nil }
        let digest = Self.sha256(raw)
        var found: Account?
        try? store.db.query("""
            SELECT a.id, a.username, a.is_owner, a.created_at, s.expires_at
            FROM sessions s JOIN accounts a ON a.id = s.account_id
            WHERE s.token_hash = ?
            """, [digest]) { s in
            guard s.double(4) > Date().timeIntervalSince1970 else { return }
            found = Account(id: s.int(0), username: s.string(1), isOwner: s.int(2) != 0,
                            createdAt: Date(timeIntervalSince1970: s.double(3)))
        }
        return found
    }

    func logout(token: String) {
        guard let raw = Data(base64URLEncoded: token) else { return }
        try? store.db.run("DELETE FROM sessions WHERE token_hash = ?", [Self.sha256(raw)])
    }

    func revokeAllSessions() {
        try? store.db.run("DELETE FROM sessions")
    }

    func purgeExpired() {
        try? store.db.run("DELETE FROM sessions WHERE expires_at < ?", [Date().timeIntervalSince1970])
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        self = d
    }
}
