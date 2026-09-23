import Foundation
import ParallexKit

/// Everything needed to assemble one wrapper .app.
///
/// The wrapper execs the target's own binary (it does not copy it). After exec
/// the running process re-registers under the target app's Launch Services
/// identity — that's inherent to the technique and unavoidable for Electron
/// apps, which relocate themselves to their original bundle anyway. See
/// `InstanceLauncher.launchOriginal` for the consequence (launching the
/// original while an instance runs needs "new instance" semantics).
struct WrapperSpec {
    var name: String
    var slug: String
    var bundleIdentifier: String
    var targetAppPath: String
    var targetBinaryPath: String
    var targetBundleID: String? = nil
    var arguments: [String]
    var environment: [String: String]
    var homeOverride: String?
    var homeSymlinks: [String]
    var createDirectories: [String]
    var applicationCategory: String?
    var outputDirectory: URL
    var launcherBinary: URL
    var iconSource: IconBuilder.IconSource?
    var badge: IconBuilder.Badge?
    var pidFile: String? = nil
}

/// Assembles, signs, and registers wrapper bundles. The bundle is built in a
/// same-volume staging directory and moved into place so a failure never
/// leaves a half-written .app in /Applications.
public struct BundleBuilder {
    public struct Options: Sendable {
        public var sign: Bool
        public var clearQuarantine: Bool
        public var registerWithLaunchServices: Bool

        public init(
            sign: Bool = true,
            clearQuarantine: Bool = true,
            registerWithLaunchServices: Bool = true
        ) {
            self.sign = sign
            self.clearQuarantine = clearQuarantine
            self.registerWithLaunchServices = registerWithLaunchServices
        }
    }

    struct BuildOutput {
        let url: URL
        /// Non-fatal problems (e.g. icon rendering failed) for the caller to surface.
        let warnings: [String]
    }

    var options: Options

    init(options: Options = Options()) {
        self.options = options
    }

    /// True if the bundle at `url` was created by Parallex. Guards every
    /// destructive operation on existing bundles: we never delete or replace
    /// an .app we didn't make.
    static func isParallexWrapper(_ url: URL) -> Bool {
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else {
            return false
        }
        return plist[ParallexConfig.rootKey] != nil
    }

    func build(_ spec: WrapperSpec) throws -> BuildOutput {
        let fm = FileManager.default
        var warnings: [String] = []
        let finalURL = spec.outputDirectory.appendingPathComponent("\(spec.name).app", isDirectory: true)

        if fm.fileExists(atPath: finalURL.path) {
            guard Self.isParallexWrapper(finalURL) else {
                throw ParallexError(
                    "\(finalURL.path) exists and is not a Parallex wrapper — refusing to replace it. "
                    + "Pick a different name."
                )
            }
            try fm.trashItem(at: finalURL, resultingItemURL: nil)
        }

        // Same-volume staging so the final step is an atomic-ish rename.
        let staging = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: spec.outputDirectory,
            create: true
        )
        defer { try? fm.removeItem(at: staging) }

        let bundle = staging.appendingPathComponent("\(spec.name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let launcherDest = macOS.appendingPathComponent("launcher")
        try fm.copyItem(at: spec.launcherBinary, to: launcherDest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherDest.path)

        var hasIcon = false
        if let iconSource = spec.iconSource {
            do {
                try IconBuilder.writeIcon(
                    from: iconSource,
                    badge: spec.badge,
                    to: resources.appendingPathComponent("app.icns")
                )
                hasIcon = true
            } catch {
                // An icon is cosmetic — keep going, but tell the user.
                warnings.append("Could not build the wrapper icon (\(error)); the instance will use a generic one.")
            }
        }

        let infoPlist = makeInfoPlist(spec: spec, hasIcon: hasIcon)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        try fm.moveItem(at: bundle, to: finalURL)

        if options.sign {
            try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", finalURL.path])
        }
        if options.clearQuarantine {
            Shell.runAllowingFailure("/usr/bin/xattr", ["-dr", "com.apple.quarantine", finalURL.path])
        }
        if options.registerWithLaunchServices, let lsregister = Self.lsregisterPath {
            // Best-effort: first `open` registers the bundle anyway.
            Shell.runAllowingFailure(lsregister, ["-f", finalURL.path])
        }
        return BuildOutput(url: finalURL, warnings: warnings)
    }

    private func makeInfoPlist(spec: WrapperSpec, hasIcon: Bool) -> [String: Any] {
        var config: [String: Any] = [
            ParallexConfig.Key.targetBinary: spec.targetBinaryPath,
            ParallexConfig.Key.targetApp: spec.targetAppPath,
            ParallexConfig.Key.slug: spec.slug,
        ]
        if let targetBundleID = spec.targetBundleID {
            config[ParallexConfig.Key.targetBundleID] = targetBundleID
        }
        if !spec.arguments.isEmpty {
            config[ParallexConfig.Key.arguments] = spec.arguments
        }
        if !spec.environment.isEmpty {
            config[ParallexConfig.Key.environment] = spec.environment
        }
        if let homeOverride = spec.homeOverride {
            config[ParallexConfig.Key.homeOverride] = homeOverride
            if !spec.homeSymlinks.isEmpty {
                config[ParallexConfig.Key.homeSymlinks] = spec.homeSymlinks
            }
        }
        if !spec.createDirectories.isEmpty {
            config[ParallexConfig.Key.createDirectories] = spec.createDirectories
        }
        if let pidFile = spec.pidFile {
            config[ParallexConfig.Key.pidFile] = pidFile
        }

        var info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": spec.bundleIdentifier,
            "CFBundleName": spec.name,
            "CFBundleDisplayName": spec.name,
            "CFBundleExecutable": "launcher",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": ParallexConfig.version,
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "11.0",
            "NSHighResolutionCapable": true,
            ParallexConfig.rootKey: config,
        ]
        if hasIcon {
            info["CFBundleIconFile"] = "app"
        }
        if let category = spec.applicationCategory {
            info["LSApplicationCategoryType"] = category
        }
        return info
    }

    private static var lsregisterPath: String? {
        let candidates = [
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
