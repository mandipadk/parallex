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
/// unlocks it every time. Its random password is kept next to it, readable
/// only by you. (Not in the login keychain: macOS ties what a program may
/// read there to its exact code, which changes every time the copy is
/// refreshed. And a copy runs without the hardened runtime, so anything
/// running as you could read its sign-ins through the copy anyway.)
public enum InstanceKeychain {
    /// The file holding the password of the keychain at `path`.
    public static func passwordFile(for path: String) -> String {
        (path as NSString).deletingPathExtension + ".keychain-password"
    }

    /// Make (the first time) and unlock the keychain at `path`. False when
    /// it can't be used; the launcher then doesn't open the copy (it would
    /// otherwise use your keychain).
    public static func prepare(path: String) -> Bool {
        let fm = FileManager.default
        let passwordPath = passwordFile(for: path)
        if fm.fileExists(atPath: path) {
            if let password = try? String(contentsOfFile: passwordPath, encoding: .utf8), !password.isEmpty {
                return unlock(path: path, password: password)
            }
            // Its password is there but can't be read: leave everything be.
            guard !fm.fileExists(atPath: passwordPath) else {
                report("couldn't read \(passwordPath)")
                return false
            }
            // A keychain without its password can never be opened; set it
            // aside (nothing is lost that wasn't already) and start anew.
            let aside = path + ".unusable-\(Int(Date().timeIntervalSince1970))"
            guard (try? fm.moveItem(atPath: path, toPath: aside)) != nil else { return false }
        }
        let password = randomPassword()
        // The password first, only yours, so a keychain never exists
        // without it.
        guard fm.createFile(atPath: passwordPath, contents: Data(password.utf8), attributes: [.posixPermissions: 0o600]) else {
            report("couldn't write \(passwordPath)")
            return false
        }
        var keychain: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(path, UInt32(strlen($0)), $0, false, nil, &keychain)
        }
        guard status == errSecSuccess else {
            report("couldn't create \(path) (\(status))")
            try? fm.removeItem(atPath: passwordPath)
            return false
        }
        // It never locks by itself: the app may reach for a sign-in at any
        // time, and nobody knows this keychain's password to type it in.
        let settings = Process()
        settings.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        settings.arguments = ["set-keychain-settings", path]
        try? settings.run()
        settings.waitUntilExit()
        return unlock(path: path, password: password)
    }

    static func unlock(path: String, password: String) -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return false }
        let status = password.withCString { SecKeychainUnlock(keychain, UInt32(strlen($0)), $0, true) }
        if status != errSecSuccess {
            report("couldn't unlock \(path) (\(status))")
        }
        return status == errSecSuccess
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("parallex-launcher: \(message)\n".utf8))
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
