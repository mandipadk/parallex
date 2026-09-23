import Foundation
import Security
import ParallexKit

/// The app frameworks Parallex knows isolation recipes for.
public enum AppFramework: String, Sendable {
    case electron
    case vscodeFamily = "vscode-family"
    case chromiumBrowser = "chromium-browser"
    case firefox
    case cef
    case native

    public var displayName: String {
        switch self {
        case .electron: "Electron app"
        case .vscodeFamily: "VS Code-family editor (Electron)"
        case .chromiumBrowser: "Chromium-based browser"
        case .firefox: "Firefox-based browser"
        case .cef: "Chromium Embedded Framework app"
        case .native: "native/other app"
        }
    }

    /// Whether tier-1 (app-aware) isolation flags exist for this framework.
    /// CEF apps embed Chromium but generally don't honor --user-data-dir, so
    /// they fall through to HOME override like native apps.
    public var hasAppAwarePreset: Bool {
        switch self {
        case .electron, .vscodeFamily, .chromiumBrowser, .firefox: true
        case .cef, .native: false
        }
    }
}

/// Everything `create` and `doctor` need to know about a target app.
public struct AppInfo {
    public let url: URL
    public let bundleID: String
    public let name: String
    public let executableURL: URL
    let infoPlist: [String: Any]
    public let signingIdentifier: String?
    public let isSandboxed: Bool
    public let framework: AppFramework
    public let iconFileURL: URL?
    public let isParallexWrapper: Bool
}

public enum AppInspector {
    public static func inspect(_ appURL: URL) throws -> AppInfo {
        let url = appURL.standardizedFileURL
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        let infoPlistURL = contents.appendingPathComponent("Info.plist")

        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            throw ParallexError("\(url.path) does not look like an app bundle (no readable Contents/Info.plist).")
        }
        guard let bundleID = plist["CFBundleIdentifier"] as? String else {
            throw ParallexError("\(url.path) has no CFBundleIdentifier — cannot wrap it.")
        }
        guard let executableName = plist["CFBundleExecutable"] as? String else {
            throw ParallexError("\(url.path) has no CFBundleExecutable — cannot wrap it.")
        }
        let executableURL = contents.appendingPathComponent("MacOS").appendingPathComponent(executableName)
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            throw ParallexError("Main executable not found at \(executableURL.path) — the app bundle looks broken.")
        }

        // Some apps pad their name with invisible bidi marks (U+200E …);
        // they'd end up in instance names and file names.
        let rawName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let name = String(String.UnicodeScalarView(rawName.unicodeScalars.filter {
            !(0x200E...0x200F).contains($0.value) && !(0x202A...0x202E).contains($0.value)
                && !(0x2066...0x2069).contains($0.value)
        })).trimmingCharacters(in: .whitespaces)

        let signing = signingInfo(of: url)
        // Entitlement values arrive as NSNumber regardless of plist vs DER form.
        let sandboxed = (signing.entitlements?["com.apple.security.app-sandbox"] as? NSNumber)?.boolValue == true

        return AppInfo(
            url: url,
            bundleID: bundleID,
            name: name,
            executableURL: executableURL,
            infoPlist: plist,
            signingIdentifier: signing.identifier,
            isSandboxed: sandboxed,
            framework: detectFramework(appURL: url, bundleID: bundleID),
            iconFileURL: resolveIconFile(appURL: url, infoPlist: plist),
            isParallexWrapper: plist[ParallexConfig.rootKey] != nil
        )
    }

    // MARK: - Code signing / entitlements

    /// Read the signing identifier and entitlements via the Security framework
    /// (no codesign subprocess, no text parsing). Unsigned code → (nil, nil).
    static func signingInfo(of url: URL) -> (identifier: String?, entitlements: [String: Any]?) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else {
            return (nil, nil)
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any]
        else {
            return (nil, nil)
        }
        return (
            info[kSecCodeInfoIdentifier as String] as? String,
            info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        )
    }

    // MARK: - Framework detection

    /// Chromium-based browsers all honor --user-data-dir but carry no common
    /// bundle marker, so they're recognized by bundle ID prefix. Data, easy to
    /// extend — matches the plan's "preset table is data" intent.
    private static let chromiumBundleIDPrefixes = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser", // Arc
        "net.imput.helium",
        "ru.yandex.desktop.yandex-browser",
        "com.naver.Whale",
    ]

    static func detectFramework(appURL: URL, bundleID: String) -> AppFramework {
        let fm = FileManager.default
        let contents = appURL.appendingPathComponent("Contents")
        func exists(_ relative: String) -> Bool {
            fm.fileExists(atPath: contents.appendingPathComponent(relative).path)
        }

        let isElectron = exists("Frameworks/Electron Framework.framework")
        if isElectron && exists("Resources/app/product.json") {
            return .vscodeFamily
        }
        if isElectron {
            return .electron
        }
        // Firefox and forks: legacy application.ini, or the XUL library.
        if exists("Resources/application.ini") || exists("MacOS/XUL") {
            return .firefox
        }
        if chromiumBundleIDPrefixes.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) {
            return .chromiumBrowser
        }
        if exists("Frameworks/Chromium Embedded Framework.framework") {
            return .cef
        }
        return .native
    }

    // MARK: - Icon

    /// Resolve the target's .icns on disk, if it has one. Apps that ship icons
    /// only in Assets.car return nil; callers fall back to NSWorkspace.
    static func resolveIconFile(appURL: URL, infoPlist: [String: Any]) -> URL? {
        let fm = FileManager.default
        let resources = appURL.appendingPathComponent("Contents/Resources")
        var candidates: [String] = []
        if var iconFile = infoPlist["CFBundleIconFile"] as? String {
            if !iconFile.hasSuffix(".icns") {
                iconFile += ".icns"
            }
            candidates.append(iconFile)
        }
        candidates += ["AppIcon.icns", "app.icns", "icon.icns", "electron.icns"]
        for candidate in candidates {
            let url = resources.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    // MARK: - Isolation switch discovery

    /// Environment variables an Electron app's own code reads that look like
    /// data-location switches (`process.env.FOO_USER_DATA_DIR`, `…_HOME`, …).
    /// Apps that ignore `--user-data-dir` often honor one of these — this is
    /// how per-app recipes are found. Heuristic: it lists candidates, it
    /// doesn't prove they work.
    public static func candidateEnvironmentSwitches(appURL: URL) -> [String] {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        let archive = resources.appendingPathComponent("app.asar")
        guard let data = try? Data(contentsOf: archive, options: .alwaysMapped) else {
            return []
        }
        let needle = Array("process.env.".utf8)
        let keywords = ["USER_DATA", "DATA_DIR", "DATA_PATH", "CONFIG_DIR", "CONFIG_HOME", "_HOME", "PROFILE", "APPDATA"]
        // Generic variables every app reads; not app-specific switches.
        let generic: Set<String> = [
            "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "APPDATA",
            "LOCALAPPDATA", "USERPROFILE", "JAVA_HOME", "GOPATH", "CARGO_HOME", "NVM_HOME", "PYENV_ROOT",
            "npm_config_userconfig", "BUN_INSTALL", "CODESPACES", "ANDROID_HOME",
        ]
        var found = Set<String>()
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            var index = 0
            while index + needle.count < count {
                // Cheap first-byte filter before the full comparison.
                if bytes[index] == needle[0], bytes[index + 1] == needle[1] {
                    var matched = true
                    for offset in 2..<needle.count where bytes[index + offset] != needle[offset] {
                        matched = false
                        break
                    }
                    if matched {
                        var end = index + needle.count
                        while end < count {
                            let byte = bytes[end]
                            let isName = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5F
                            guard isName else { break }
                            end += 1
                        }
                        if end - (index + needle.count) >= 4 {
                            let name = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[(index + needle.count)..<end]), as: UTF8.self)
                            // Endpoints and secrets aren't locations.
                            let nonLocation = ["URL", "HOST", "PORT", "TOKEN", "KEY", "SECRET", "ID"]
                                .contains { name.hasSuffix($0) }
                            if !generic.contains(name), !nonLocation, keywords.contains(where: name.contains) {
                                found.insert(name)
                            }
                        }
                        index = end
                        continue
                    }
                }
                index += 1
            }
        }
        return found.sorted()
    }
}
