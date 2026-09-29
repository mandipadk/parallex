import Foundation
import Security

/// A keychain of an own-identity copy's own.
///
/// Apps keep sign-ins in the keychain as items named after themselves, so
/// a copy looking up "its" item finds the original's, and signing in to a
/// second account there can overwrite the original's. A copy with its own
/// Library therefore keeps every password item in a keychain file of its
/// own, in its instance folder (its home redirect library sends them there;
/// see home.c).
///
/// The launcher makes that keychain the first time the copy opens, and
/// unlocks it every time. Its random password is kept in your login
/// keychain, as an item the copy's launcher made, so only that copy can read
/// it without asking. (A password file would let anything running as you
/// read the copy's secrets.)
public enum InstanceKeychain {
    /// The login-keychain item holding an instance keychain's password; its
    /// account is the instance keychain's path.
    public static let passwordService = "Parallex instance keychain"

    /// PARALLEX_PASSWORD_KEYCHAIN: keep the passwords in this keychain file
    /// instead of the login keychain (tests).
    static var passwordKeychain: SecKeychain? {
        guard let path = ProcessInfo.processInfo.environment["PARALLEX_PASSWORD_KEYCHAIN"], !path.isEmpty else {
            return nil
        }
        var keychain: SecKeychain?
        return SecKeychainOpen(path, &keychain) == errSecSuccess ? keychain : nil
    }

    /// Make (the first time) and unlock the keychain at `path`. False when
    /// it can't be used; the copy then keeps using the shared keychain.
    public static func prepare(path: String, label: String) -> Bool {
        // PARALLEX_LAUNCHER_NO_UI (tests): never ask; what would ask fails.
        if ProcessInfo.processInfo.environment["PARALLEX_LAUNCHER_NO_UI"] == "1" {
            SecKeychainSetUserInteractionAllowed(false)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let password = storedPassword(for: path) {
                return unlock(path: path, password: password)
            }
            // Its password is there but may not be read (asked, and
            // declined): leave everything as it is.
            guard !hasStoredPassword(for: path) else {
                FileHandle.standardError.write(Data("parallex-launcher: couldn't read the password for \(path)\n".utf8))
                return false
            }
            // A keychain nobody has the password to can never be opened;
            // set it aside and start a new one.
            let aside = path + ".unusable-\(Int(Date().timeIntervalSince1970))"
            guard (try? fm.moveItem(atPath: path, toPath: aside)) != nil else { return false }
        }
        let password = randomPassword()
        var keychain: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(path, UInt32(strlen($0)), $0, false, nil, &keychain)
        }
        guard status == errSecSuccess else {
            FileHandle.standardError.write(Data("parallex-launcher: couldn't create \(path) (\(status))\n".utf8))
            return false
        }
        // It never locks by itself: the app may reach for a sign-in at any
        // time, and nobody knows this keychain's password to type it in.
        let settings = Process()
        settings.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        settings.arguments = ["set-keychain-settings", path]
        try? settings.run()
        settings.waitUntilExit()
        guard storePassword(password, for: path, label: label) else {
            // Without its password it could never be opened again.
            try? fm.removeItem(atPath: path)
            return false
        }
        return unlock(path: path, password: password)
    }

    /// Forget an instance keychain's password (the instance is gone). Only
    /// the copy's launcher, which made the item, may delete it without
    /// asking, so Parallex runs the copy's launcher with
    /// `ParallexConfig.forgetKeychainArgument` to do it.
    public static func forget(path: String) {
        var query = baseQuery(for: path)
        if let keychain = passwordKeychain {
            query[kSecMatchSearchList] = [keychain] as CFArray
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Whether a password is kept for the keychain at `path`. Reads only
    /// the item's attributes, which never asks (its password is the copy's).
    public static func hasStoredPassword(for path: String) -> Bool {
        var query = baseQuery(for: path)
        query[kSecReturnAttributes] = true
        if let keychain = passwordKeychain {
            query[kSecMatchSearchList] = [keychain] as CFArray
        }
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func unlock(path: String, password: String) -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return false }
        let status = password.withCString { SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true) }
        if status != errSecSuccess {
            FileHandle.standardError.write(Data("parallex-launcher: couldn't unlock \(path) (\(status))\n".utf8))
        }
        return status == errSecSuccess
    }

    private static func baseQuery(for path: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: passwordService, kSecAttrAccount: path]
    }

    static func storedPassword(for path: String) -> String? {
        var query = baseQuery(for: path)
        query[kSecReturnData] = true
        if let keychain = passwordKeychain {
            query[kSecMatchSearchList] = [keychain] as CFArray
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func storePassword(_ password: String, for path: String, label: String) -> Bool {
        // A leftover from a keychain file that's gone (it can't open anything).
        forget(path: path)
        var item = baseQuery(for: path)
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrLabel] = label
        if let keychain = passwordKeychain {
            item[kSecUseKeychain] = keychain
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            FileHandle.standardError.write(Data("parallex-launcher: couldn't keep the password for \(path) (\(status))\n".utf8))
        }
        return status == errSecSuccess
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
