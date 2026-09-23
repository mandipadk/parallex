import Foundation
import ParallexKit

/// Clone mode: the instance is a full copy of the target app with its own
/// bundle identifier, re-signed ad hoc. Because macOS derives a running
/// process's identity from its executable, the copy runs under its *own*
/// identity — its own Dock icon and name, ⌘-Tab entry, notifications,
/// privacy permissions, preferences domain, and (for sandboxed apps) its own
/// container. The copy is an APFS clone, so it takes almost no disk space.
///
/// For apps that need launch flags or environment (Electron data-dir flags,
/// recipes), the copy's main executable becomes the Parallex launcher and the
/// app's real binary stays next to it; every way of opening the copy (Dock,
/// notifications, login restore) goes through the launcher. Sandboxed apps
/// keep their own executable: the launcher couldn't run inside their sandbox,
/// and their isolation comes from the container anyway.
public enum AppCloner {
    /// The app's version as recorded for staleness checks.
    public static func version(of app: URL) -> String {
        let url = app.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: url)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        let short = plist["CFBundleShortVersionString"] as? String ?? "?"
        let build = plist["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Whether and how well an app can be cloned.
    public struct Assessment: Sendable {
        public let possible: Bool
        /// Why cloning is impossible, or what to expect from the copy.
        public let notes: [String]
    }

    /// Entitlement keys that need an Apple-issued provisioning profile; an
    /// ad hoc signature carrying them is killed at launch, so they're removed
    /// from the copy (and the features behind them stop working there).
    static func isRestricted(_ key: String) -> Bool {
        key.hasPrefix("com.apple.developer.")
            || key.hasPrefix("com.apple.private.")
            || ["application-identifier", "com.apple.application-identifier",
                "keychain-access-groups", "aps-environment"].contains(key)
    }

    public static func assess(_ app: AppInfo) -> Assessment {
        if app.bundleID.hasPrefix("com.apple.") {
            return Assessment(possible: false, notes: [
                "\(app.name) is part of macOS; Apple's apps rely on entitlements only Apple can sign, so a copy can't run.",
            ])
        }
        var notes: [String] = [
            "Parallex makes a copy of \(app.name) (an APFS clone — almost no extra disk space) with its own "
            + "identity, so the instance gets its own Dock icon, name, notifications, and permissions.",
            "The copy doesn't update itself: when \(app.name) updates, Parallex shows “repair to refresh the copy”.",
        ]
        let entitlements = AppInspector.signingInfo(of: app.url).entitlements ?? [:]
        let dropped = entitlements.keys.filter(isRestricted).sorted()
        if dropped.contains(where: { $0.contains("icloud") || $0.contains("ubiquity") }) {
            notes.append("iCloud features won't work in the copy (they need \(app.name)'s own signature).")
        }
        if dropped.contains(where: { $0 == "aps-environment" || $0.contains("usernotifications") }) {
            notes.append("Push-delivered notifications may not arrive in the copy.")
        }
        if dropped.contains("keychain-access-groups") {
            notes.append("Keychain sharing is off in the copy; it may ask to use keychain items the original created.")
        }
        if app.isSandboxed {
            if let groups = entitlements["com.apple.security.application-groups"] as? [String], !groups.isEmpty {
                notes.append(
                    "\(app.name) keeps data in shared app-group containers (\(groups.first!)…), which are keyed by "
                    + "group, not by app — the copy will likely see the original's data there, and macOS may ask "
                    + "permission. Isolation is only certain for data in the app's own container."
                )
            } else {
                notes.append("Sandboxed: the copy gets its own container, so its data is separate from the original's.")
            }
        } else {
            notes.append(
                "The copy may ask for access to keychain items \(app.name) created (e.g. “\(app.name) Safe "
                + "Storage”) — allow it, or it starts without saved sign-ins."
            )
        }
        if FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Contents/_MASReceipt").path) {
            notes.append("App Store apps sometimes check their receipt and refuse to run as a copy; if so, remove the instance.")
        }
        return Assessment(possible: true, notes: notes)
    }

    /// Where an instance's copy lives: next to the wrapper, replacing it —
    /// the copy *is* the instance app.
    struct CloneSpec {
        var source: AppInfo
        var destination: URL
        var bundleIdentifier: String
        var displayName: String
        /// Install the Parallex launcher as the main executable.
        var useLauncher: Bool
        var launcherBinary: URL
        var launcherConfig: [String: Any]
        var iconICNS: URL?
    }

    /// Put the home-redirect library at its shared location (replaced
    /// atomically — running copies have it mapped) and return that path.
    static func installHomeLibrary(from source: URL) throws -> URL {
        let fm = FileManager.default
        let destination = Paths.homeLibrary
        if let current = try? Data(contentsOf: destination), let new = try? Data(contentsOf: source), current == new {
            return destination
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".libparallexhome-\(UUID().uuidString).dylib")
        try fm.copyItem(at: source, to: staged)
        guard rename(staged.path, destination.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw ParallexError("Couldn't install \(destination.path) (\(String(cString: strerror(errno)))).")
        }
        return destination
    }

    /// Build the copy in a staging directory next to the destination, then
    /// move it into place (never leaving a half-built app behind).
    static func build(_ spec: CloneSpec, sign: Bool = true) throws -> URL {
        let fm = FileManager.default
        let outDir = spec.destination.deletingLastPathComponent()
        let staging = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: outDir, create: true
        )
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(spec.destination.lastPathComponent, isDirectory: true)

        // Copy the real bundle, never a symlink to it: every later step
        // writes into the copy, and writing through a link would modify
        // (and re-sign) the user's original app.
        let source = spec.source.url.resolvingSymlinksInPath()
        // APFS clone (-c): shares blocks with the original until modified.
        try Shell.run("/bin/cp", ["-cRp", source.path, copy.path])
        let copyValues = try copy.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard copyValues.isSymbolicLink != true, copyValues.isDirectory == true else {
            throw ParallexError("Copying \(source.path) didn't produce a real app bundle; not continuing.")
        }
        // Only the download-provenance attributes; others (e.g. script
        // signatures) must survive.
        Shell.runAllowingFailure("/usr/bin/xattr", ["-dr", "com.apple.quarantine", copy.path])
        Shell.runAllowingFailure("/usr/bin/xattr", ["-dr", "com.apple.provenance", copy.path])

        let contents = copy.appendingPathComponent("Contents")
        let infoURL = contents.appendingPathComponent("Info.plist")
        var info = spec.source.infoPlist
        info["CFBundleIdentifier"] = spec.bundleIdentifier
        // CFBundleName stays: apps use it internally (Electron finds its
        // "<Name> Helper.app" helpers by it). The Dock and ⌘-Tab show the
        // display name.
        info["CFBundleDisplayName"] = spec.displayName
        // Don't let a self-updater (Sparkle) replace the copy with the
        // vendor's build — that would restore the original identity.
        info["SUEnableAutomaticChecks"] = false
        info["SUAutomaticallyUpdate"] = false
        if let icon = spec.iconICNS {
            let iconName = "parallex-icon"
            try? fm.removeItem(at: contents.appendingPathComponent("Resources/\(iconName).icns"))
            try fm.copyItem(at: icon, to: contents.appendingPathComponent("Resources/\(iconName).icns"))
            info["CFBundleIconFile"] = iconName
            // An asset-catalog icon name would win over the file.
            info["CFBundleIconName"] = nil
        }
        if spec.useLauncher {
            let launcherName = "parallex-launcher"
            let launcherDest = contents.appendingPathComponent("MacOS/\(launcherName)")
            try? fm.removeItem(at: launcherDest)
            try fm.copyItem(at: spec.launcherBinary, to: launcherDest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherDest.path)
            info["CFBundleExecutable"] = launcherName
        }
        if let home = spec.launcherConfig[ParallexConfig.Key.redirectHome] as? String,
           let library = spec.launcherConfig[ParallexConfig.Key.redirectLibrary] as? String,
           let scope = spec.launcherConfig[ParallexConfig.Key.redirectScope] as? String {
            try injectEnvironment(into: copy, source: spec.source.url, [
                "DYLD_INSERT_LIBRARIES": library,
                "PARALLEX_HOME_REDIRECT": home,
                "PARALLEX_HOME_SCOPE": scope,
            ])
        }
        info[ParallexConfig.rootKey] = spec.launcherConfig
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: infoURL)

        // The receipt is bound to the original's identity.
        try? fm.removeItem(at: contents.appendingPathComponent("_MASReceipt"))

        if sign {
            try resign(copy, source: spec.source, within: staging)
        }

        // Swap in the new copy; if that fails, put the old one back.
        if fm.fileExists(atPath: spec.destination.path) {
            let previous = staging.appendingPathComponent("previous-\(UUID().uuidString).app")
            try fm.moveItem(at: spec.destination, to: previous)
            do {
                try fm.moveItem(at: copy, to: spec.destination)
            } catch {
                try? fm.moveItem(at: previous, to: spec.destination)
                throw error
            }
            try? fm.trashItem(at: previous, resultingItemURL: nil)
        } else {
            try fm.moveItem(at: copy, to: spec.destination)
        }
        return spec.destination
    }

    /// Parts of an app that macOS starts itself — XPC services, helper apps
    /// opened through Launch Services — don't inherit the launcher's
    /// environment. Their own Info.plist can carry environment variables
    /// (`XPCService.EnvironmentVariables`, `LSEnvironment`), so the home
    /// redirect is written there too. Runs before re-signing.
    /// Sandboxed services are skipped: the redirected home would be outside
    /// their container, where the sandbox denies access.
    static func injectEnvironment(into app: URL, source: URL, _ environment: [String: String]) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        guard let enumerator = fm.enumerator(at: contents, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator where ["xpc", "app"].contains(url.pathExtension) {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            let relative = String(url.path.dropFirst(app.path.count))
            let entitlements = AppInspector.signingInfo(of: source.appendingPathComponent(relative)).entitlements ?? [:]
            if entitlements["com.apple.security.app-sandbox"] as? Bool == true { continue }
            let plistURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { continue }
            if url.pathExtension == "xpc" {
                var service = plist["XPCService"] as? [String: Any] ?? [:]
                var variables = service["EnvironmentVariables"] as? [String: String] ?? [:]
                variables.merge(environment) { _, new in new }
                service["EnvironmentVariables"] = variables
                plist["XPCService"] = service
            } else {
                var variables = plist["LSEnvironment"] as? [String: String] ?? [:]
                variables.merge(environment) { _, new in new }
                plist["LSEnvironment"] = variables
            }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        }
    }

    /// Re-sign the copy ad hoc, inside out. Nested code (frameworks, helper
    /// apps, extensions, XPC services) keeps its own entitlements minus the
    /// restricted ones; the hardened runtime is dropped, which also lifts
    /// library validation between the re-signed pieces.
    static func resign(_ bundle: URL, source: AppInfo, within workArea: URL) throws {
        let fm = FileManager.default
        // Resolve symlinked prefixes (/var → /private/var) so enumerated
        // paths and the bundle path share one spelling; relative paths map
        // each nested item to its original for entitlements.
        let app = bundle.resolvingSymlinksInPath()
        // Never re-sign anything outside the staging area — above all not
        // the original app.
        guard app.path.hasPrefix(workArea.resolvingSymlinksInPath().path + "/") else {
            throw ParallexError("Refusing to re-sign \(app.path): it isn't the copy being built.")
        }
        let workDir = fm.temporaryDirectory.appendingPathComponent("parallex-sign-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        func sign(_ url: URL, entitlementsFrom original: URL?) throws {
            var arguments = ["--force", "--sign", "-", "--timestamp=none"]
            if let original,
               var entitlements = AppInspector.signingInfo(of: original).entitlements {
                entitlements = entitlements.filter { !isRestricted($0.key) }
                if !entitlements.isEmpty {
                    let file = workDir.appendingPathComponent("\(UUID().uuidString).plist")
                    try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
                        .write(to: file)
                    arguments += ["--entitlements", file.path]
                }
            }
            arguments.append(url.path)
            try Shell.run("/usr/bin/codesign", arguments)
        }

        // Nested bundles and loose Mach-O files, deepest first.
        let contents = app.appendingPathComponent("Contents")
        var nestedBundles: [URL] = []
        var looseBinaries: [URL] = []
        let bundleExtensions: Set<String> = ["framework", "app", "xpc", "appex", "bundle", "plugin", "systemextension"]
        if let enumerator = fm.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let found as URL in enumerator {
                let values = try? found.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                // Not a symlink itself, so resolving only normalizes the
                // prefix (the enumerator doesn't descend through links).
                let url = found.resolvingSymlinksInPath()
                if bundleExtensions.contains(url.pathExtension) {
                    // Folders that merely end in .framework etc. (no Info.plist
                    // anywhere a bundle keeps one) aren't code bundles.
                    let plists = ["Contents/Info.plist", "Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Info.plist"]
                    if plists.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) {
                        nestedBundles.append(url)
                    }
                } else if values?.isRegularFile == true, !isInsideBundleMacOS(url, of: app),
                          isMachO(url) || url.deletingLastPathComponent().lastPathComponent == "MacOS" {
                    // Mach-O anywhere, plus anything (scripts) in a nested
                    // bundle's MacOS/, which codesign treats as nested code.
                    looseBinaries.append(url)
                }
            }
        }
        let depth: (URL) -> Int = { $0.pathComponents.count }
        // Loose binaries (dylibs, helper tools) before the bundles holding them.
        for binary in looseBinaries.sorted(by: { depth($0) > depth($1) }) {
            let relative = String(binary.path.dropFirst(app.path.count))
            try sign(binary, entitlementsFrom: isMachO(binary) ? source.url.appendingPathComponent(relative) : nil)
        }
        for bundle in nestedBundles.sorted(by: { depth($0) > depth($1) }) {
            let relative = String(bundle.path.dropFirst(app.path.count))
            try sign(bundle, entitlementsFrom: source.url.appendingPathComponent(relative))
        }
        // Everything else in the main bundle's MacOS/ (the app's real binary
        // next to the launcher, helper scripts) is nested code: codesign
        // requires it signed before the bundle.
        let macOS = contents.appendingPathComponent("MacOS")
        let mainName = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: contents.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any])?["CFBundleExecutable"] as? String
        for name in (try? fm.contentsOfDirectory(atPath: macOS.path)) ?? [] where name != mainName {
            let url = macOS.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            // Only the app's own binary carries the app's entitlements.
            let isAppBinary = name == source.executableURL.lastPathComponent
            try sign(url, entitlementsFrom: isAppBinary && isMachO(url) ? source.url : nil)
        }
        // The main bundle last, with the app's (filtered) entitlements.
        try sign(app, entitlementsFrom: source.url)
    }

    private static func isInsideBundleMacOS(_ url: URL, of app: URL) -> Bool {
        url.deletingLastPathComponent().path == app.appendingPathComponent("Contents/MacOS").path
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }
}
