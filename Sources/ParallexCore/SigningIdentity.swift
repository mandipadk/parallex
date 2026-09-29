import Foundation
import Security

/// The code-signing identity this Mac signs its copies with.
///
/// macOS remembers what an app may do (camera, microphone, screen
/// recording, files and folders, Accessibility, keychain items) against its
/// designated requirement. For an app signed ad hoc that's its exact code
/// hash, which changes every time Parallex refreshes the copy — so each app
/// update used to cost every permission and keychain grant the copy had.
/// Signed with a certificate of its own, a copy's requirement is its bundle
/// ID plus that certificate, which survives refreshes.
///
/// The identity is made here, the first time a copy is signed: a
/// self-signed code-signing certificate in a keychain of Parallex's own
/// (never the login keychain, never on the keychain search list), whose
/// random password sits next to it, readable only by you. It needs no Apple
/// Developer ID; nothing outside this Mac trusts it, and nothing needs to.
public enum SigningIdentity {
    public struct Identity: Sendable, Equatable {
        /// SHA-1 of the certificate, as `codesign --sign` takes it.
        public let hash: String
        public let keychain: URL
    }

    static let commonName = "Parallex Local Signing"

    /// PARALLEX_SIGNING_DIR moves it (tests share one); PARALLEX_SIGNING=adhoc
    /// turns it off, so copies are signed ad hoc as before.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["PARALLEX_SIGNING_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Paths.supportRoot.appendingPathComponent("signing", isDirectory: true)
    }

    static var keychainURL: URL { directory.appendingPathComponent("Parallex Signing.keychain-db") }
    static var passwordURL: URL { directory.appendingPathComponent("keychain-password") }
    static var identityURL: URL { directory.appendingPathComponent("identity") }

    public static var isDisabled: Bool {
        ProcessInfo.processInfo.environment["PARALLEX_SIGNING"] == "adhoc"
    }

    /// The identity copies are signed with, made the first time it's
    /// needed. `nil` (sign ad hoc instead) when it's turned off or can't be
    /// made. Its keychain stays locked except while signing.
    public static func forSigning() -> Identity? {
        guard !isDisabled else { return nil }
        do {
            return try loadOrCreate()
        } catch {
            FileHandle.standardError.write(Data(
                "parallex: signing copies ad hoc — couldn't use this Mac's signing identity: \(error)\n".utf8
            ))
            return nil
        }
    }

    /// Run `body` with the identity unlocked for `codesign` (nil when there
    /// is none), then lock it again. One signing at a time across Parallex
    /// and the command line, so neither locks it under the other.
    static func whileSigning<T>(_ body: (Identity?) throws -> T) throws -> T {
        guard let identity = forSigning() else { return try body(nil) }
        let session = try FileLock(directory.appendingPathComponent(".signing.lock"))
        defer { session.release() }
        guard (try? unlock()) != nil else { return try body(nil) }
        defer { lock() }
        return try body(identity)
    }

    /// Lock the signing keychain: only a signing Parallex does may use it.
    static func lock() {
        var keychain: SecKeychain?
        if SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain {
            SecKeychainLock(keychain)
        }
    }

    /// The identity if one was made already (never makes one).
    public static func existing() -> Identity? {
        guard !isDisabled,
              FileManager.default.fileExists(atPath: keychainURL.path),
              let hash = try? String(contentsOf: identityURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              hash.count == 40
        else {
            return nil
        }
        return Identity(hash: hash, keychain: keychainURL)
    }

    static func loadOrCreate() throws -> Identity {
        if let identity = existing() {
            return identity
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The app and the command line may both sign a first copy at once.
        let lock = try FileLock(directory.appendingPathComponent(".lock"))
        defer { lock.release() }
        if let identity = existing() {
            return identity
        }
        return try create()
    }

    private static func create() throws -> Identity {
        let fm = FileManager.default
        // Start clean: a half-made identity from an interrupted attempt.
        for url in [keychainURL, passwordURL, identityURL] {
            try? fm.removeItem(at: url)
        }
        let password = randomToken()
        guard fm.createFile(atPath: passwordURL.path, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ParallexError("Couldn't write \(passwordURL.path).")
        }

        // Made here rather than with `security create-keychain`, which also
        // puts it on your keychain search list.
        var keychain: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(keychainURL.path, UInt32(strlen($0)), $0, false, nil, &keychain)
        }
        guard status == errSecSuccess else {
            throw ParallexError("Couldn't create the signing keychain (\(status)).")
        }
        // Never locks by itself: copies are signed whenever an app updates.
        try Shell.run("/usr/bin/security", ["set-keychain-settings", keychainURL.path])
        try unlock()

        // The certificate and its key, handed to the keychain in one file
        // (the system's own tools; nothing is downloaded or installed).
        let work = directory.appendingPathComponent(".new-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let key = work.appendingPathComponent("key.pem").path
        let certificate = work.appendingPathComponent("certificate.pem").path
        let bundle = work.appendingPathComponent("identity.p12").path
        try Shell.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", certificate,
            "-days", "10950", "-subj", "/CN=\(commonName)",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-addext", "basicConstraints=critical,CA:false",
        ])
        let transfer = randomToken()
        try Shell.run(
            "/usr/bin/openssl",
            ["pkcs12", "-export", "-inkey", key, "-in", certificate, "-out", bundle, "-passout", "env:PARALLEX_TRANSFER"],
            environment: ProcessInfo.processInfo.environment.merging(["PARALLEX_TRANSFER": transfer]) { _, new in new }
        )
        // Only codesign may use the key, and without asking.
        try Shell.run("/usr/bin/security", ["import", bundle, "-k", keychainURL.path, "-P", transfer, "-T", "/usr/bin/codesign"])
        try Shell.run("/usr/bin/security", [
            "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychainURL.path,
        ])

        let listing = try Shell.run("/usr/bin/security", ["find-certificate", "-a", "-Z", keychainURL.path])
        guard let hash = listing.split(separator: "\n")
            .first(where: { $0.hasPrefix("SHA-1 hash:") })?
            .split(separator: " ").last.map(String.init),
            hash.count == 40
        else {
            throw ParallexError("The signing certificate wasn't found in its keychain.")
        }
        try Data(hash.utf8).write(to: identityURL, options: .atomic)
        lock()
        return Identity(hash: hash, keychain: keychainURL)
    }

    /// `codesign` can use the key only while its keychain is unlocked
    /// (it fails with errSecInternalComponent otherwise).
    private static func unlockKeychain(_ password: String) throws {
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain else {
            throw ParallexError("Couldn't open the signing keychain.")
        }
        let status = password.withCString { SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true) }
        guard status == errSecSuccess else {
            throw ParallexError("Couldn't unlock the signing keychain (\(status)).")
        }
    }

    static func unlock() throws {
        let password = try String(contentsOf: passwordURL, encoding: .utf8)
        try unlockKeychain(password)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
