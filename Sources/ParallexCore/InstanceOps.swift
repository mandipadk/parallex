import AppKit
import Foundation
import ParallexKit

// The high-level operations shared by the CLI and the GUI: probe an app,
// create an instance, remove an instance. All results are Sendable so UIs can
// run them off the main actor and hop back with the outcome.

// MARK: - Probe

/// A doctor-style summary of a target app, for display before creating an
/// instance.
public struct AppProbe: Sendable {
    public let appPath: String
    public let name: String
    public let bundleIdentifier: String
    public let frameworkDisplayName: String
    public let sandboxed: Bool
    public let isParallexWrapper: Bool
    public let recommendedMode: InstanceMode
    public let notes: [String]
    /// First free "<App> 2", "<App> 3", … name for the default output directory.
    public let suggestedName: String
    /// Optional isolation toggles the app's recipe offers.
    public let recipeOptions: [RecipeOption]
    /// Whether clone mode (own identity) is possible, and what to expect.
    public let cloneAssessment: AppCloner.Assessment
}

// MARK: - Create

public struct CreateRequest: Sendable {
    public var appReference: String
    public var name: String?
    public var mode: RequestedMode
    public var outputDirectory: URL
    public var badgeText: String?
    public var badgeColorHex: String?
    public var customIcon: URL?
    public var environment: [String: String]
    public var extraSharedItems: [String]
    public var includeDefaultSharedItems: Bool
    public var extraArguments: [String]
    /// Recipe option IDs to enable; `nil` → the recipe's defaults.
    public var enabledOptions: [String]?
    /// An existing profile folder to move in as the instance's data (e.g. a
    /// `--user-data-dir` made by hand or by another launcher), so the
    /// instance starts signed in with its history.
    public var adoptData: URL?
    /// Make the instance a re-signed copy of the app with its own identity.
    public var cloneApp: Bool
    /// For a copy: keep its ~/Library separate (`nil` = the default, on).
    public var separateLibrary: Bool?
    /// For a copy with its own Library: keep the app's hidden folders in the
    /// instance too (`nil` = the default, on).
    public var separateHiddenFolders: Bool?
    /// A web instance of this site (`appReference` is then ignored).
    public var webURL: String?
    /// Moved to the Trash, with its data, once it has run and quit.
    public var throwaway = false
    /// Use this keychain name suffix instead of a new one (a duplicate with
    /// data needs its source's key to read what it copied).
    var keychainSuffix: String??
    public var force: Bool

    public init(
        appReference: String,
        name: String? = nil,
        mode: RequestedMode = .auto,
        outputDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        badgeText: String? = nil,
        badgeColorHex: String? = nil,
        customIcon: URL? = nil,
        environment: [String: String] = [:],
        extraSharedItems: [String] = [],
        includeDefaultSharedItems: Bool = true,
        extraArguments: [String] = [],
        enabledOptions: [String]? = nil,
        adoptData: URL? = nil,
        cloneApp: Bool = false,
        force: Bool = false
    ) {
        self.appReference = appReference
        self.name = name
        self.mode = mode
        self.outputDirectory = outputDirectory
        self.badgeText = badgeText
        self.badgeColorHex = badgeColorHex
        self.customIcon = customIcon
        self.environment = environment
        self.extraSharedItems = extraSharedItems
        self.includeDefaultSharedItems = includeDefaultSharedItems
        self.extraArguments = extraArguments
        self.enabledOptions = enabledOptions
        self.adoptData = adoptData
        self.cloneApp = cloneApp
        self.force = force
    }
}

/// Refreshing a copy while it runs. When its app updates, the refreshed
/// copy is built beside it (`Paths.stagedCopy`) and takes its place in two
/// renames once it quits — by Parallex, or by the copy's own launcher if
/// the copy is opened first. So a copy is never kept out of date just
/// because it was in use.
extension InstanceCreator {
    /// Build the refreshed copy of a running (or any) own-identity copy
    /// without touching it. Its settings and name stay as they are.
    public static func stageRefresh(
        _ manifest: InstanceManifest,
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws {
        guard manifest.clone != nil else {
            throw ParallexError("Only an own-identity copy is refreshed while it runs.")
        }
        let original = try locateTarget(of: manifest)
        let pinned = pinnedSource(manifest.effectiveSettings, slug: manifest.slug)
        if let version = manifest.effectiveSettings.pinnedVersion, pinned == nil {
            throw ParallexError("“\(manifest.name)” stays on \(version), which isn't kept anymore; it's rebuilt once it quits.")
        }
        let target = try AppInspector.inspect(pinned ?? original)
        if let expected = manifest.knownTargetBundleID, expected != target.bundleID {
            throw ParallexError("\(target.url.path) is \(target.bundleID), but this instance was made for \(expected).")
        }
        // It takes the copy's place by renaming, so it must wait on the
        // same disk as the copy.
        let copyFolder = URL(fileURLWithPath: manifest.wrapperPath).deletingLastPathComponent()
        let instanceFolder = Paths.instanceDir(slug: manifest.slug)
        let volume = { (url: URL) in (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        guard let copyVolume = volume(copyFolder), copyVolume.isEqual(volume(instanceFolder)) else {
            throw ParallexError("“\(manifest.name)” is on another disk than Parallex's data; it's refreshed once it quits.")
        }
        var settings = manifest.effectiveSettings
        Throwaway.normalize(&settings, was: settings)
        _ = try assemble(
            target: target,
            original: pinned != nil ? original : nil,
            name: manifest.name,
            slug: manifest.slug,
            outputDirectory: copyFolder,
            settings: settings,
            previous: manifest,
            stage: true,
            builderOptions: builderOptions
        )
        // Changed (or rebuilt) while this was being built: it's already out
        // of date, and would bring the old instance back.
        if InstanceStore.load(slug: manifest.slug).map({ !sameRecord($0, manifest) }) ?? true {
            discardStagedRefresh(slug: manifest.slug)
        }
    }

    /// The same instance record, as stored.
    static func sameRecord(_ lhs: InstanceManifest, _ rhs: InstanceManifest) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(lhs)) == (try? encoder.encode(rhs))
    }

    /// The instance record of a refresh waiting to take over, if there is one.
    public static func stagedRefresh(of manifest: InstanceManifest) -> InstanceManifest? {
        guard FileManager.default.fileExists(atPath: Paths.stagedCopy(slug: manifest.slug).path) else { return nil }
        return InstanceStore.load(from: Paths.stagedManifest(slug: manifest.slug))
    }

    /// Whether the waiting refresh is of the app as it is now, and made by
    /// this Parallex (otherwise it's worth building again).
    public static func stagedRefreshIsCurrent(for manifest: InstanceManifest) -> Bool {
        guard let staged = stagedRefresh(of: manifest), let clone = staged.clone else { return false }
        let target = pinnedSource(manifest.effectiveSettings, slug: manifest.slug) ?? URL(fileURLWithPath: manifest.targetApp)
        return clone.sourceVersion == AppCloner.version(of: target) && staged.parallexVersion == ParallexConfig.version
            && staged.wrapperPath == manifest.wrapperPath
    }

    /// What became of a waiting refresh.
    public enum StagedInstall: Sendable {
        /// It took the copy's place.
        case installed(InstanceManifest)
        /// None waiting (or it was out of date and dropped).
        case nothing
        /// The copy, or something from it, is running: try again later
        /// (and don't rebuild it now either).
        case notNow
    }

    /// Put a waiting refresh in place of the copy, which must not be
    /// running. Returns the instance as it now is, or nil when nothing
    /// took its place (see `installStagedRefreshNow` for why).
    @discardableResult
    public static func installStagedRefresh(
        _ manifest: InstanceManifest,
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws -> InstanceManifest? {
        if case .installed(let installed) = try installStagedRefreshNow(manifest, builderOptions: builderOptions) {
            return installed
        }
        return nil
    }

    public static func installStagedRefreshNow(
        _ manifest: InstanceManifest,
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws -> StagedInstall {
        let fm = FileManager.default
        let staged = Paths.stagedCopy(slug: manifest.slug)
        defer { clearLeftovers(slug: manifest.slug) }
        guard var refreshed = stagedRefresh(of: manifest) else { return .nothing }
        let live = InstanceStore.load(slug: manifest.slug) ?? manifest
        // Built for another place or name, or with settings that have
        // changed since in a way a rebuild would show: out of date.
        guard refreshed.wrapperPath == live.wrapperPath, refreshed.name == live.name,
              !live.effectiveSettings.requiresRebuild(toReach: refreshed.effectiveSettings)
        else {
            discardStagedRefresh(slug: manifest.slug)
            return .nothing
        }
        // The refresh keeps the settings it was built with (for an older
        // record, the ones it's been using all along, like its shared
        // keychain); what the user changed since that needs no rebuild (a
        // shortcut, throwaway, …) comes from now.
        var settings = refreshed.effectiveSettings
        let current = live.effectiveSettings
        settings.openAtLaunch = current.openAtLaunch
        settings.shortcut = current.shortcut
        settings.menuBarIcon = current.menuBarIcon
        settings.throwaway = current.throwaway
        settings.throwawaySince = current.throwawaySince
        settings.quitWhenUnused = current.quitWhenUnused
        if settings.badgeText == nil {
            settings.badgeColorHex = current.badgeColorHex
        }
        refreshed.settings = settings
        // Not while it runs, or a launch of it is under way (the launcher
        // holds this until it becomes the app), or anything runs from it.
        let lock = try FileLock(URL(fileURLWithPath: Paths.pidFile(slug: manifest.slug).path + ".lock"))
        defer { lock.release() }
        guard !Running.isRunning(live), !Running.anythingRunning(inside: live.wrapperPath) else { return .notNow }
        // Its data as the version it's leaving left it.
        if let from = live.clone?.sourceVersion, !from.isEmpty, let to = refreshed.clone?.sourceVersion, from != to,
           live.redirectedHome != nil, live.effectiveSettings.keepPreviousVersion != false {
            let app = URL(fileURLWithPath: live.targetApp).deletingPathExtension().lastPathComponent
            _ = try? Snapshots.takeWhileLocked(live, label: "Before moving to \(app) \(to)", reason: .beforeRefresh)
        }
        // Items shared again while it ran (the refresh was built for that).
        if let home = refreshed.redirectedHome, home == live.redirectedHome {
            let released = Set(live.effectiveSettings.extraPrivateItems ?? [])
                .subtracting(refreshed.effectiveSettings.extraPrivateItems ?? [])
                .union(refreshed.pendingRelease ?? []).union(live.pendingRelease ?? [])
                .subtracting(refreshed.privateHomeItems ?? [])
            releasePrivateItems(released.sorted(), home: URL(fileURLWithPath: home, isDirectory: true))
        }
        refreshed.pendingRelease = nil
        let copy = URL(fileURLWithPath: manifest.wrapperPath)
        let previous = Paths.stagingDir(slug: manifest.slug).appendingPathComponent("previous-\(UUID().uuidString).app")
        let hadCopy = fm.fileExists(atPath: copy.path)
        if hadCopy {
            BundleBuilder.unregister(copy)
            try fm.moveItem(at: copy, to: previous)
        }
        do {
            try fm.moveItem(at: staged, to: copy)
        } catch {
            if hadCopy {
                try? fm.moveItem(at: previous, to: copy)
            }
            throw error
        }
        try InstanceStore.save(refreshed)
        try? fm.removeItem(at: Paths.stagedManifest(slug: manifest.slug))
        if builderOptions.registerWithLaunchServices, let lsregister = BundleBuilder.lsregisterPath {
            Shell.runAllowingFailure(lsregister, ["-f", copy.path])
        }
        return .installed(refreshed)
    }

    /// Drop a waiting refresh (a rebuild supersedes it).
    static func discardStagedRefresh(slug: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.stagedCopy(slug: slug))
        try? fm.removeItem(at: Paths.stagedManifest(slug: slug))
        clearLeftovers(slug: slug)
    }

    /// Copies a refresh replaced (the launcher leaves them here) go to the
    /// Trash; an empty staging folder goes.
    static func clearLeftovers(slug: String) {
        let fm = FileManager.default
        let folder = Paths.stagingDir(slug: slug)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("previous-") {
            try? Trash.move(folder.appendingPathComponent(name))
        }
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }
}

/// Duplicating an instance: the same app and settings under a new name,
/// optionally with a copy of its data.
extension InstanceCreator {
    public static func duplicate(
        _ manifest: InstanceManifest,
        name: String? = nil,
        includeData: Bool = false,
        throwaway: Bool = false,
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws -> CreateResult {
        if includeData, Running.isRunning(manifest) {
            throw ParallexError("Quit “\(manifest.name)” first, so its data is copied in a consistent state.")
        }
        if includeData, let clone = manifest.clone, !clone.usesLauncher {
            throw ParallexError(
                "“\(manifest.name)” keeps its data in its own sandbox container, which can't be copied. "
                + "Duplicate it without data instead."
            )
        }
        let settings = manifest.effectiveSettings
        let target = try locateTarget(of: manifest)
        let sourceDir = Paths.instanceDir(slug: manifest.slug)
        var request = CreateRequest(
            appReference: target.path,
            name: name ?? duplicateName(for: manifest.name, suffix: throwaway ? "Throwaway" : "Copy"),
            mode: settings.mode,
            outputDirectory: URL(fileURLWithPath: manifest.wrapperPath).deletingLastPathComponent(),
            badgeText: settings.badgeText,
            badgeColorHex: settings.badgeColorHex,
            customIcon: settings.customIconFile.map { sourceDir.appendingPathComponent($0) },
            environment: settings.extraEnvironment,
            extraSharedItems: settings.extraSharedItems,
            includeDefaultSharedItems: settings.includeDefaultSharedItems,
            extraArguments: settings.extraArguments,
            enabledOptions: settings.enabledOptions,
            cloneApp: settings.isClone
        )
        request.separateLibrary = settings.separateLibrary
        request.separateHiddenFolders = settings.separateHiddenFolders
        request.webURL = settings.webURL
        request.throwaway = throwaway
        // What's copied was encrypted with the source's key; the duplicate
        // uses it where it is. (A key in the source's own keychain can't be
        // shared: then the duplicate gets one of its own.)
        if includeData, manifest.safeStorageInKeychain != true {
            request.keychainSuffix = .some(manifest.keychainSuffix)
        }
        let result = try create(request, builderOptions: builderOptions)
        if includeData {
            // Building a copy takes a moment; the original may have been opened since.
            if Running.isRunning(manifest) {
                throw ParallexError(
                    "Created “\(result.manifest.name)”, but “\(manifest.name)” was opened meanwhile, so its data "
                    + "wasn't copied. Quit it and duplicate again, or use the new instance as it is."
                )
            }
            try copyData(from: manifest, to: result.manifest)
            if manifest.safeStorageInKeychain == true {
                // Its key is in its own keychain, which opens only for it.
                return CreateResult(
                    manifest: result.manifest, wrapperURL: result.wrapperURL,
                    frameworkDisplayName: result.frameworkDisplayName, dataDirectories: result.dataDirectories,
                    homeDirectory: result.homeDirectory, notes: result.notes,
                    warnings: result.warnings + [
                        "What “\(manifest.name)” keeps encrypted with its own key (cookies, saved sign-ins) can't be "
                        + "read by the duplicate; sign in there again.",
                    ]
                )
            }
        }
        return result
    }

    /// Files that only mean something to a running app — its single-instance
    /// locks and sockets (Chromium/Electron, Firefox) — plus VS Code's
    /// extension index, which records absolute paths into the source
    /// instance (VS Code rebuilds it). A copy starting with these would hand
    /// itself to the original or point back into it.
    static let runStateNames: Set<String> = [
        "SingletonLock", "SingletonSocket", "SingletonCookie", "lock", ".parentlock", "parent.lock", "extensions.json",
    ]

    static func removeRunState(in directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: []) else { return }
        var doomed: [URL] = []
        for case let url as URL in enumerator where runStateNames.contains(url.lastPathComponent) {
            // extensions.json only where VS Code keeps it.
            if url.lastPathComponent == "extensions.json", url.deletingLastPathComponent().lastPathComponent != "extensions" {
                continue
            }
            doomed.append(url)
        }
        for url in doomed {
            try? fm.removeItem(at: url)
        }
    }

    /// "Claude Work Copy", then "Claude Work Copy 2", …
    static func duplicateName(for name: String, suffix: String = "Copy") -> String {
        let names = Set(InstanceStore.loadAll().map { $0.name.lowercased() })
        var candidate = "\(name) \(suffix)"
        var index = 2
        while names.contains(candidate.lowercased()) {
            candidate = "\(name) \(suffix) \(index)"
            index += 1
        }
        return candidate
    }

    /// Clone (APFS, near-free) the instance's data folders into another
    /// instance's folder, plus a copy's preferences.
    static func copyData(from source: InstanceManifest, to destination: InstanceManifest) throws {
        let fm = FileManager.default
        let from = Paths.instanceDir(slug: source.slug)
        let to = Paths.instanceDir(slug: destination.slug)
        let skipped: Set<String> = ["instance.json", "instance.pid", "instance.pid.lock"]
        // Not its keychain: only the copy it belongs to can open that, so a
        // duplicate starts with a keychain of its own.
        for item in (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
        where !skipped.contains(item) && !item.hasPrefix("custom-icon.") && !item.hasPrefix("Instance.keychain")
            && item != ParallexConfig.stagingFolder && !AccessRecord.fileNames.contains(item)
            && item != "signin.log" && item != Snapshots.folderName && item != AppVersions.folderName
            && item != Personas.markerFile && item != SettingsLinks.markerFile {
            let target = to.appendingPathComponent(item)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try Shell.run("/bin/cp", ["-cRp", from.appendingPathComponent(item).path, target.path])
        }
        removeRunState(in: to)
        if let old = source.clone?.bundleIdentifier, let new = destination.clone?.bundleIdentifier {
            let exported = fm.temporaryDirectory.appendingPathComponent("parallex-prefs-\(UUID().uuidString).plist")
            defer { try? fm.removeItem(at: exported) }
            if (try? Shell.run("/usr/bin/defaults", ["export", old, exported.path])) != nil {
                Shell.runAllowingFailure("/usr/bin/defaults", ["import", new, exported.path])
            }
        }
    }
}

public struct CreateResult: Sendable {
    public let manifest: InstanceManifest
    public let wrapperURL: URL
    public let frameworkDisplayName: String
    /// Directories holding the instance's isolated data (data-dir mode).
    public let dataDirectories: [String]
    /// The instance home (home mode).
    public let homeDirectory: String?
    /// Informational notes from the isolation plan (sandbox caveats, TCC, …).
    public let notes: [String]
    /// Non-fatal problems encountered while building (e.g. icon failure).
    public let warnings: [String]
}

/// A change to an existing instance. `nil` fields keep the current value.
public struct InstanceUpdate: Sendable {
    public var name: String?
    public var settings: InstanceSettings?
    /// A new icon to copy in (replaces any custom icon).
    public var newCustomIcon: URL?
    /// Point the instance at a different copy of its app (e.g. after moving it).
    public var targetApp: URL?
    /// Go back to the app's own icon. Needed for instances made before 0.5,
    /// whose badge is baked into the wrapper icon rather than recorded.
    public var resetIcon: Bool

    public init(
        name: String? = nil,
        settings: InstanceSettings? = nil,
        newCustomIcon: URL? = nil,
        targetApp: URL? = nil,
        resetIcon: Bool = false
    ) {
        self.name = name
        self.settings = settings
        self.newCustomIcon = newCustomIcon
        self.targetApp = targetApp
        self.resetIcon = resetIcon
    }
}

public enum InstanceCreator {
    /// Inspect an app and report what `create` would do with it.
    public static func probe(
        appAt url: URL,
        outputDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) throws -> AppProbe {
        let info = try AppInspector.inspect(url)
        let plan = Presets.plan(
            for: info,
            requested: .auto,
            instanceDir: Paths.instanceDir(slug: "<instance>"),
            sharedItems: Presets.defaultSharedItems
        )
        return AppProbe(
            appPath: info.url.path,
            name: info.name,
            bundleIdentifier: info.bundleID,
            frameworkDisplayName: info.framework.displayName,
            sandboxed: info.isSandboxed,
            isParallexWrapper: info.isParallexWrapper,
            recommendedMode: plan.mode,
            notes: plan.notes,
            suggestedName: suggestName(targetName: info.name, outputDirectory: outputDirectory),
            recipeOptions: plan.availableOptions,
            cloneAssessment: AppCloner.assess(info)
        )
    }

    public static func create(
        _ request: CreateRequest,
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws -> CreateResult {
        var facts = [
            "kind": request.webURL != nil ? "web" : request.cloneApp ? "copy" : "wrapper",
            "source": Telemetry.source, "step": "inspect",
        ]
        do {
            let result = try create(request, builderOptions: builderOptions, facts: &facts)
            facts["kind"] = Telemetry.kind(of: result.manifest)
            facts["step"] = nil
            Telemetry.record("instance.created", facts.merging(["result": "ok"]) { $1 })
            return result
        } catch {
            Telemetry.record("instance.created", facts.merging(["result": "failed"]) { $1 })
            throw error
        }
    }

    /// `facts`: what's known so far, for the count of instances made (kind,
    /// framework, a well-known app's bundle ID, and how far it got).
    private static func create(
        _ request: CreateRequest,
        builderOptions: BundleBuilder.Options,
        facts: inout [String: String]
    ) throws -> CreateResult {
        let fm = FileManager.default
        var request = request
        if let web = request.webURL {
            // A website: a copy of Parallex Web, with its own Library.
            guard let url = WebShell.normalizedURL(web) else {
                throw ParallexError("“\(web)” isn't a web address. Use one like https://web.whatsapp.com.")
            }
            request.webURL = url.absoluteString
            request.cloneApp = true
            request.mode = .launchOnly
            request.separateLibrary = nil
            if request.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                request.name = WebShell.freeName(for: url, outputDirectory: request.outputDirectory)
            }
        }
        let appURL = try request.webURL != nil ? WebShell.templateApp() : AppResolver.resolve(request.appReference)
        let target = try AppInspector.inspect(appURL)
        facts["framework"] = target.framework.rawValue
        facts["app"] = request.webURL == nil && UsageReport.isPublic(target.url.path, bundleID: target.bundleID)
            ? target.bundleID : "other"
        if request.throwaway, request.cloneApp, target.isSandboxed {
            throw ParallexError("A copy of a sandboxed app can't be a throwaway: it starts without Parallex's launcher, so Parallex can't tell when it has run.")
        }
        guard !target.isParallexWrapper else {
            throw ParallexError(
                "'\(target.name)' is itself a Parallex wrapper — point create at the original app instead."
            )
        }

        let outDir = request.outputDirectory.standardizedFileURL
        try ensureWritableDirectory(outDir)

        // Choosing a name and slug, then claiming them, must not interleave
        // with another create (a second `parallex create`, or the app).
        let lock = try InstanceStore.creationLock()
        defer { lock.release() }

        let instanceName = try resolveName(request.name, targetName: target.name, outDir: outDir)
        var slug = Slug.forInstance(named: instanceName)
        // Different names can reduce to the same slug ("Claude—Work",
        // "Claude Work"); only the same name counts as "already exists".
        if let taken = InstanceStore.load(slug: slug),
           taken.name.localizedCaseInsensitiveCompare(instanceName) != .orderedSame {
            let base = slug
            var index = 2
            while InstanceStore.load(slug: slug) != nil || fm.fileExists(atPath: Paths.instanceDir(slug: slug).path) {
                slug = "\(base)-\(index)"
                index += 1
            }
        }

        let wrapperURL = outDir.appendingPathComponent("\(instanceName).app")
        // The same instance, whatever its slug: a throwaway's isn't derived
        // from its name.
        let existing = InstanceStore.load(slug: slug) ?? InstanceStore.loadAll().first {
            $0.name.localizedCaseInsensitiveCompare(instanceName) == .orderedSame
                || URL(fileURLWithPath: $0.wrapperPath).standardizedFileURL == wrapperURL.standardizedFileURL
        }
        if let existing {
            slug = existing.slug
        }
        // However it's asked for (New Instance, a link, Duplicate, the CLI):
        // a new instance of an app nothing keeps apart yet isn't made. One
        // made before can still be rebuilt.
        if existing == nil, request.webURL == nil, let reason = AppCatalog.cantKeepApart[target.bundleID] {
            throw ParallexError(reason)
        }
        if existing != nil && !request.force {
            throw ParallexError(
                "An instance named '\(instanceName)' already exists. Rebuild it with force, or pick another name."
            )
        }
        if let owner = registryOwning(wrapperURL),
           owner.standardizedFileURL.resolvingSymlinksInPath().path
            != Paths.instancesRoot.standardizedFileURL.resolvingSymlinksInPath().path {
            throw ParallexError(
                "\(wrapperURL.path) belongs to another Parallex library (\(Paths.abbreviate(owner.path))) — pick another name."
            )
        }
        if fm.fileExists(atPath: wrapperURL.path) && !request.force {
            throw ParallexError(
                "\(wrapperURL.path) already exists. Rebuild with force (only Parallex wrappers are replaced), "
                + "or pick another name."
            )
        }
        // A throwaway's identity is never handed on: macOS keeps notification
        // and privacy choices by bundle ID, so the next one with the same
        // name gets a slug (and bundle ID) of its own.
        if request.throwaway && existing == nil {
            slug += "-" + UUID().uuidString.prefix(6).lowercased()
        }

        var settings = InstanceSettings(
            requestedMode: request.mode,
            badgeText: request.badgeText.map { $0.trimmingCharacters(in: .whitespaces) },
            badgeColorHex: request.badgeColorHex,
            extraEnvironment: request.environment,
            extraArguments: request.extraArguments,
            extraSharedItems: request.extraSharedItems,
            includeDefaultSharedItems: request.includeDefaultSharedItems,
            enabledOptions: request.enabledOptions,
            cloneApp: request.cloneApp ? true : nil
        )
        settings.separateLibrary = request.separateLibrary
        settings.separateHiddenFolders = request.separateHiddenFolders
        settings.webURL = request.webURL
        settings.throwaway = request.throwaway ? true : nil
        // A throwaway from now: a pid file left in a reused folder, or from
        // the instance this rebuilds, doesn't count as a run.
        Throwaway.normalize(&settings, was: nil)
        try validateBadge(settings)
        if let adopt = request.adoptData {
            try validateAdoptable(adopt, target: target, slug: slug)
        }
        if let icon = request.customIcon {
            settings.customIconFile = try storeCustomIcon(icon, slug: slug)
        }

        facts["step"] = "build"
        let result = try assemble(
            target: target,
            name: instanceName,
            slug: slug,
            outputDirectory: outDir,
            settings: settings,
            previous: existing,
            // An adopted profile was encrypted with the original's key.
            keychainSuffix: request.adoptData != nil ? .some(nil) : request.keychainSuffix,
            builderOptions: builderOptions
        )
        if let adopt = request.adoptData {
            guard let destination = result.dataDirectories.first ?? result.homeDirectory else {
                throw ParallexError(
                    "Created “\(instanceName)”, but its isolation mode has no data folder to adopt into."
                )
            }
            try adoptData(from: adopt, into: URL(fileURLWithPath: destination))
        }
        return result
    }

    /// An adoptable folder exists, isn't Parallex's own data, and isn't the
    /// original app's live profile (moving that would empty the original).
    private static func validateAdoptable(_ source: URL, target: AppInfo, slug: String) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ParallexError("\(source.path) isn't a folder.")
        }
        let path = source.standardizedFileURL.path
        if path.hasPrefix(Paths.instancesRoot.standardizedFileURL.path + "/") {
            throw ParallexError("\(source.path) already belongs to a Parallex instance.")
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let originalProfiles = Presets.originalDataFolders(
            bundleID: target.bundleID,
            names: [target.name, target.url.deletingPathExtension().lastPathComponent],
            version: AppCloner.version(of: target.url)
        ).map { support.appendingPathComponent($0).standardizedFileURL.path }
        if originalProfiles.contains(path) {
            throw ParallexError(
                "\(Paths.abbreviate(path)) is \(target.name)'s own profile — moving it would sign the original "
                + "out. Copy it somewhere first and adopt the copy."
            )
        }
        let destination = Paths.instanceDir(slug: slug).appendingPathComponent("data")
        if let contents = try? fm.contentsOfDirectory(atPath: destination.path), !contents.isEmpty {
            throw ParallexError("This instance already has data; adopting would overwrite it.")
        }
    }

    private static func adoptData(from source: URL, into destination: URL) throws {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: destination.path) {
            guard contents.isEmpty else {
                throw ParallexError("\(destination.path) isn't empty; not adopting into it.")
            }
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            throw ParallexError(
                "The instance was created, but moving \(source.path) into it failed: \(error.localizedDescription)"
            )
        }
    }

    /// Rebuild an instance's wrapper from its settings, optionally changing
    /// them (rename, badge, icon, isolation options, …). The slug — and with
    /// it the bundle ID and data directory — never changes, so the instance
    /// keeps its data and macOS permissions. Also the repair path: it
    /// regenerates a missing or outdated wrapper.
    /// `keepingSnapshot`: a snapshot the caller means to restore next, which
    /// the one taken here mustn't push out.
    public static func update(
        _ manifest: InstanceManifest,
        _ change: InstanceUpdate = InstanceUpdate(),
        builderOptions: BundleBuilder.Options = BundleBuilder.Options(),
        keepingSnapshot: String? = nil
    ) throws -> CreateResult {
        let fm = FileManager.default
        var settings = change.settings ?? manifest.effectiveSettings
        Throwaway.normalize(&settings, was: manifest.effectiveSettings)

        // Two libraries (PARALLEX_HOME) can hold records naming the same
        // app; only the library the app was built for may rebuild it.
        if let owner = registryOwning(URL(fileURLWithPath: manifest.wrapperPath)),
           owner.standardizedFileURL.resolvingSymlinksInPath().path
            != Paths.instancesRoot.standardizedFileURL.resolvingSymlinksInPath().path {
            throw ParallexError(
                "\(manifest.wrapperPath) belongs to another Parallex library (\(Paths.abbreviate(owner.path))), "
                + "so it wasn't changed."
            )
        }

        // A clone *is* the running app: replacing it (or swapping it for a
        // wrapper) under a live process would strand that process in the
        // Trash where Parallex can no longer see it.
        if (manifest.clone != nil || settings.isClone), Running.isRunning(manifest) {
            throw ParallexError("Quit “\(manifest.name)” first — its copy of the app is replaced by this change.")
        }

        let originalURL = try change.targetApp ?? locateTarget(of: manifest)
        // Pinned to a kept version: built from that (or, if it's gone, from
        // the app as it is).
        if settings.pinnedVersion != nil, pinnedSource(settings, slug: manifest.slug) == nil {
            settings.pinnedVersion = nil
        }
        let pinned = pinnedSource(settings, slug: manifest.slug)
        let target = try AppInspector.inspect(pinned ?? originalURL)
        guard !target.isParallexWrapper else {
            throw ParallexError("'\(target.name)' is itself a Parallex wrapper — choose the original app.")
        }
        if let expected = manifest.knownTargetBundleID, expected != target.bundleID {
            throw ParallexError(
                "\(target.url.path) is \(target.bundleID), but this instance was made for \(expected)."
            )
        }

        let oldWrapper = URL(fileURLWithPath: manifest.wrapperPath)
        let outDir = oldWrapper.deletingLastPathComponent()
        let name = try change.name.map {
            try resolveName($0, targetName: target.name, outDir: outDir)
        } ?? manifest.name
        if name != manifest.name {
            let newWrapper = outDir.appendingPathComponent("\(name).app")
            // A case-only rename finds the old wrapper itself on a
            // case-insensitive volume — that's not a conflict.
            if fm.fileExists(atPath: newWrapper.path) && !sameItem(newWrapper, oldWrapper) {
                throw ParallexError("\(newWrapper.path) already exists — pick another name.")
            }
        }
        try ensureWritableDirectory(outDir)

        if change.resetIcon {
            settings.customIconFile = nil
        }
        // Schema-1 instances don't record their badge or icon; keep whatever
        // icon the current wrapper has, unless this change restyles the icon.
        if manifest.settings == nil, !change.resetIcon, change.newCustomIcon == nil,
           settings.customIconFile == nil, settings.badgeText == nil {
            let current = oldWrapper.appendingPathComponent("Contents/Resources/app.icns")
            if fm.fileExists(atPath: current.path) {
                settings.customIconFile = try storeCustomIcon(current, slug: manifest.slug)
            }
        }
        if let icon = change.newCustomIcon {
            settings.customIconFile = try storeCustomIcon(icon, slug: manifest.slug)
        }
        try validateBadge(settings)

        // Moving to another version of its app: first its data as the
        // version it leaves left it, to go back to.
        if let clone = manifest.clone, settings.isClone, manifest.redirectedHome != nil, !clone.sourceVersion.isEmpty,
           settings.keepPreviousVersion != false, AppCloner.version(of: target.url) != clone.sourceVersion {
            _ = try? Snapshots.take(
                manifest, label: "Before moving to \(target.name) \(AppCloner.version(of: target.url))",
                reason: .beforeRefresh, keeping: keepingSnapshot
            )
        }

        let result = try assemble(
            target: target,
            original: pinned != nil ? originalURL : nil,
            name: name,
            slug: manifest.slug,
            outputDirectory: outDir,
            settings: settings,
            previous: manifest,
            builderOptions: builderOptions
        )
        // Renamed: the new wrapper is in place, retire the old one (unless
        // it was a case-only rename on a case-insensitive volume, where old
        // and new are the same file).
        if result.wrapperURL.path != oldWrapper.path,
           fm.fileExists(atPath: oldWrapper.path),
           !sameItem(result.wrapperURL, oldWrapper),
           BundleBuilder.isParallexWrapper(oldWrapper) {
            BundleBuilder.unregister(oldWrapper)
            try? Trash.move(oldWrapper)
        }
        return result
    }

    /// Whether two paths name the same file on disk (true for case variants
    /// on a case-insensitive volume, false on a case-sensitive one).
    static func sameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        // Fresh URLs: resource values are cached per URL object, and the file
        // behind a path changes when a wrapper is rebuilt.
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? URL(fileURLWithPath: lhs.path).resourceValues(forKeys: key).fileResourceIdentifier,
              let right = try? URL(fileURLWithPath: rhs.path).resourceValues(forKeys: key).fileResourceIdentifier
        else {
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }
        return left.isEqual(right)
    }

    /// Save settings that don't change the built wrapper (see
    /// `InstanceSettings.requiresRebuild`) without rebuilding anything.
    public static func saveSettings(_ settings: InstanceSettings, for manifest: InstanceManifest) throws -> InstanceManifest {
        guard !manifest.effectiveSettings.requiresRebuild(toReach: settings) else {
            throw ParallexError("These changes need the instance to be rebuilt.")
        }
        var settings = settings
        Throwaway.normalize(&settings, was: manifest.effectiveSettings)
        // First save of a pre-0.5 instance: keep the icon its wrapper has
        // (a baked-in badge isn't recorded anywhere else).
        if manifest.settings == nil, settings.customIconFile == nil, settings.badgeText == nil {
            let current = URL(fileURLWithPath: manifest.wrapperPath).appendingPathComponent("Contents/Resources/app.icns")
            if FileManager.default.fileExists(atPath: current.path) {
                settings.customIconFile = try storeCustomIcon(current, slug: manifest.slug)
            }
        }
        var updated = manifest
        updated.settings = settings
        updated.schemaVersion = 2
        try InstanceStore.save(updated)
        return updated
    }

    /// Where the instance's target app is now: its recorded path, or wherever
    /// Launch Services finds its bundle ID.
    public static func locateTarget(of manifest: InstanceManifest) throws -> URL {
        if manifest.isWeb {
            return try WebShell.templateApp()
        }
        if FileManager.default.fileExists(atPath: manifest.targetApp) {
            return URL(fileURLWithPath: manifest.targetApp, isDirectory: true)
        }
        if let bundleID = manifest.knownTargetBundleID, let found = AppResolver.locate(bundleID: bundleID) {
            return found
        }
        throw ParallexError(
            "The original app is missing at \(manifest.targetApp). Reinstall it, or choose where it is now."
        )
    }

    /// Build the wrapper and write the manifest for fully-resolved inputs.
    /// `original`: the app in /Applications, when `target` is a kept
    /// version of it (a pinned copy is built from that).
    private static func assemble(
        target: AppInfo,
        original: URL? = nil,
        name instanceName: String,
        slug: String,
        outputDirectory outDir: URL,
        settings: InstanceSettings,
        previous: InstanceManifest?,
        keychainSuffix requestedKeychainSuffix: String?? = nil,
        stage: Bool = false,
        builderOptions: BundleBuilder.Options
    ) throws -> CreateResult {
        let instanceDir = Paths.instanceDir(slug: slug)
        // A rebuild supersedes a refresh waiting to take over.
        if !stage {
            discardStagedRefresh(slug: slug)
        }
        var sharedItems = settings.includeDefaultSharedItems ? Presets.defaultSharedItems : []
        sharedItems.append(contentsOf: settings.extraSharedItems.filter { !sharedItems.contains($0) })

        let plan = Presets.plan(
            for: target,
            requested: settings.mode,
            instanceDir: instanceDir,
            sharedItems: sharedItems,
            enabledOptions: settings.enabledOptions.map(Set.init),
            clone: settings.isClone,
            separateLibrary: settings.separatesLibrary(for: target) && !target.isSandboxed
        )
        // An own-identity copy with its own Library is shown the instance's
        // home as the user's home (the home-mode home, or a dedicated one).
        let redirectHome = settings.separatesLibrary(for: target) && !target.isSandboxed
            ? plan.homeOverride ?? instanceDir.appendingPathComponent("home").path
            : nil
        let homeSymlinks = plan.homeOverride != nil ? plan.homeSymlinks : (redirectHome != nil ? sharedItems : [])
        // A new copy with its own Library gets its own encryption key too;
        // an existing one keeps whichever it has been using, even while its
        // Library isn't separate (its data needs that key when it is again).
        let keychainSuffix: String? = {
            if let requestedKeychainSuffix { return requestedKeychainSuffix }
            if let previous { return previous.keychainSuffix }
            return redirectHome != nil ? KeychainNames.suffix(for: slug) : nil
        }()
        // Its sign-ins in a keychain of its own (see InstanceKeychain), when
        // it's signed with this Mac's identity: that's what lets its launcher
        // read the keychain's password without asking after every refresh.
        let wantsKeychain = redirectHome != nil && settings.separateKeychain != false
        let identityAvailable = wantsKeychain && builderOptions.sign && SigningIdentity.usable()
        // One that has its own keychain never loses it quietly: signed any
        // other way, it couldn't open what it keeps there.
        if wantsKeychain, previous?.instanceKeychain != nil, !identityAvailable {
            throw ParallexError(
                "“\(instanceName)” keeps its sign-ins in its own keychain, which needs this Mac's signing identity, "
                + "and that isn't available right now, so it wasn't rebuilt. Try again, or turn off Separate keychain."
            )
        }
        let instanceKeychain = wantsKeychain && identityAvailable ? Paths.instanceKeychain(slug: slug).path : nil
        // Its own encryption key goes in that keychain too, for copies that
        // had it from the start (older ones' data needs their renamed key).
        // A copy given a key to use (its data was copied from another
        // instance, or the original) finds that one where it is.
        let safeStorageInKeychain = instanceKeychain != nil && keychainSuffix != nil
            && (previous == nil ? requestedKeychainSuffix == nil : previous?.safeStorageInKeychain == true)
        // A dedicated home mirrors yours, except for the app's own folders
        // (and what the user shares explicitly). Home mode keeps its promise
        // of a home of its own, shared items aside.
        let privateHomeItems = redirectHome != nil && plan.homeOverride == nil && settings.separateHiddenFolders != false
            ? Presets.privateHomeItems(for: target, extra: settings.extraPrivateItems ?? []).filter { item in
                !sharedItems.contains { item == $0 || item.hasPrefix($0 + "/") || $0.hasPrefix(item + "/") }
            }
            : nil
        // Items the user kept to the copy and now shares again: the copy's
        // own version goes to the Trash, so its home links to yours there
        // again (not while a refresh is only being prepared: it's in use).
        var pendingRelease: [String]?
        if let redirectHome, let previousHome = previous?.redirectedHome, previousHome == redirectHome {
            let before = Set(previous?.effectiveSettings.extraPrivateItems ?? [])
            let kept = Set(privateHomeItems ?? [])
            let released = before.subtracting(settings.extraPrivateItems ?? [])
                .union(previous?.pendingRelease ?? []).subtracting(kept).sorted()
            if stage {
                // Whoever puts the refresh in place (Parallex, or the copy's
                // own launcher) leaves this for later.
                pendingRelease = released.isEmpty ? nil : released
            } else {
                releasePrivateItems(released, home: URL(fileURLWithPath: redirectHome, isDirectory: true))
            }
        }
        // The original's settings, shared on purpose (editors).
        let sharedSettings = redirectHome != nil && settings.isClone && settings.shareSettings == true
            ? SharedSettings.shareable(for: target.bundleID) : []
        if !stage, let redirectHome, let before = previous?.sharedSettings {
            let stopped = before.filter { !sharedSettings.contains($0) }
            if !stopped.isEmpty {
                SharedSettings.unlink(
                    stopped, home: URL(fileURLWithPath: redirectHome, isDirectory: true),
                    realHome: FileManager.default.homeDirectoryForCurrentUser
                )
            }
        }
        // Guard: the original's data is off limits to a copy with its own
        // Library (the copy's launcher runs it; see `Guard`).
        let guardedPaths = redirectHome != nil && settings.isClone && settings.guardOriginalData != false
            ? Guard.locations(
                for: target, privateHomeItems: privateHomeItems, sharedItems: homeSymlinks, allowed: sharedSettings,
                home: FileManager.default.homeDirectoryForCurrentUser.path
            )
            : nil

        // The app's single-instance ports, each with one of the copy's own.
        let loopbackPorts = redirectHome != nil
            ? LoopbackPorts.assign(
                known: Presets.singleInstancePorts(for: target.bundleID, version: AppCloner.version(of: target.url)), slug: slug,
                previous: previous?.loopbackPorts ?? [:]
            )
            : [:]

        // Plan recipe first, user-provided vars win, PARALLEX_INSTANCE always set.
        var environment = plan.environment
        environment.merge(settings.extraEnvironment) { _, user in user }
        environment["PARALLEX_INSTANCE"] = slug
        if let web = settings.webURL {
            guard let url = WebShell.normalizedURL(web) else {
                throw ParallexError("“\(web)” isn't a web address.")
            }
            environment[WebShell.urlVariable] = url.absoluteString
            // A throwaway site quits with its window, so it can be trashed.
            if settings.throwaway == true {
                environment[WebShell.quitOnCloseVariable] = "1"
            }
        }
        let arguments = plan.arguments + settings.extraArguments

        let customIcon = settings.customIconFile.map { instanceDir.appendingPathComponent($0) }
        var spec = WrapperSpec(
            name: instanceName,
            slug: slug,
            bundleIdentifier: "com.parallex.instance.\(slug)",
            targetAppPath: target.url.path,
            targetBinaryPath: target.executableURL.path,
            targetBundleID: target.bundleID,
            arguments: arguments,
            environment: environment,
            homeOverride: plan.homeOverride,
            homeSymlinks: homeSymlinks,
            createDirectories: plan.createDirectories,
            links: plan.links,
            settingsSync: plan.settingsSync,
            applicationCategory: target.infoPlist["LSApplicationCategoryType"] as? String,
            outputDirectory: outDir,
            launcherBinary: try LauncherLocator.locate(),
            iconSource: try resolveIconSource(custom: customIcon, target: target),
            badge: settings.badgeText.map {
                IconBuilder.Badge(text: $0, colorHex: settings.badgeColorHex, colorSeed: slug)
            },
            pidFile: Paths.pidFile(slug: slug).path,
            redirectHome: redirectHome,
            redirectPrivate: privateHomeItems,
            keychainSuffix: redirectHome != nil ? keychainSuffix : nil,
            keychainKeep: redirectHome != nil && keychainSuffix != nil ? KeychainNames.foreignServices(for: target) : [],
            instanceKeychain: instanceKeychain,
            safeStorageInKeychain: safeStorageInKeychain,
            guardedPaths: guardedPaths,
            loopbackPorts: loopbackPorts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" },
            sharedSettings: sharedSettings,
            shareableSettings: redirectHome != nil && settings.isClone ? SharedSettings.shareable(for: target.bundleID) : []
        )

        var notes = plan.notes
        var separatedGroups: [String: String]?
        let output: BundleBuilder.BuildOutput
        var cloneRecord: InstanceManifest.CloneRecord?
        if settings.isClone {
            let built = try buildClone(
                spec: spec, target: target, previous: previous,
                separateGroups: settings.separatesLibrary(for: target) && target.isSandboxed,
                hideFromDock: settings.hideFromDock == true,
                stageAt: stage ? Paths.stagedCopy(slug: slug) : nil,
                requireIdentity: instanceKeychain != nil,
                builderOptions: builderOptions
            )
            separatedGroups = built.groupMap.isEmpty ? nil : built.groupMap
            output = built.output
            cloneRecord = built.record
            spec.targetBinaryPath = built.executable
            // A web instance is Parallex's own app: nothing to warn about.
            notes = settings.webURL != nil ? [] : notes + AppCloner.assess(target).notes
            if !built.record.usesLauncher,
               !settings.extraEnvironment.isEmpty || !settings.extraArguments.isEmpty || settings.mode != .auto {
                notes.append(
                    "Extra environment, arguments, and isolation modes don't apply to a sandboxed app's copy — "
                    + "it starts directly, and its container is what keeps it separate."
                )
            }
        } else {
            guard !stage else { throw ParallexError("Only an own-identity copy is refreshed while it runs.") }
            output = try BundleBuilder(options: builderOptions).build(spec)
        }

        var manifest = InstanceManifest(
            name: instanceName,
            slug: slug,
            bundleIdentifier: spec.bundleIdentifier,
            targetApp: (original ?? target.url).path,
            targetBinary: spec.targetBinaryPath,
            // Staged, it's built elsewhere but belongs where the copy is.
            wrapperPath: stage ? outDir.appendingPathComponent("\(instanceName).app").path : output.url.path,
            mode: plan.mode,
            preset: plan.presetID,
            arguments: arguments,
            environment: environment,
            homeSymlinks: plan.homeOverride != nil || redirectHome != nil ? homeSymlinks : nil,
            createdAt: previous?.createdAt ?? Date(),
            parallexVersion: ParallexConfig.version,
            targetBundleID: target.bundleID,
            settings: settings,
            clone: cloneRecord,
            redirectedHome: cloneRecord?.usesLauncher == true ? redirectHome : nil,
            separatedGroups: separatedGroups,
            privateHomeItems: cloneRecord?.usesLauncher == true ? privateHomeItems : nil,
            links: plan.links.isEmpty ? nil : plan.links,
            keychainSuffix: cloneRecord?.usesLauncher == true || previous?.keychainSuffix != nil ? keychainSuffix : nil,
            instanceKeychain: cloneRecord?.usesLauncher == true ? instanceKeychain : nil,
            safeStorageInKeychain: cloneRecord?.usesLauncher == true && safeStorageInKeychain ? true : nil,
            guardedPaths: cloneRecord?.usesLauncher == true ? guardedPaths : nil,
            loopbackPorts: cloneRecord?.usesLauncher == true && !loopbackPorts.isEmpty
                ? Dictionary(uniqueKeysWithValues: loopbackPorts.map { ("\($0.key)", $0.value) }) : nil
        )
        manifest.pendingRelease = pendingRelease
        manifest.sharedSettings = cloneRecord?.usesLauncher == true && !sharedSettings.isEmpty ? sharedSettings : nil
        // The version it's built from, kept to go back to (built from the
        // app in /Applications; a pinned copy's is kept already).
        if settings.isClone, original == nil, settings.webURL == nil, settings.throwaway != true {
            // The version it was on is the way back: kept, unless keeping
            // them is off.
            let leaving = settings.keepPreviousVersion == false ? nil : previous?.clone?.sourceVersion
            AppVersions.keep(
                original: target.url, slug: slug, previous: settings.keepPreviousVersion == false ? 0 : 1,
                pinned: settings.pinnedVersion, leaving: leaving
            )
        }
        try InstanceStore.save(manifest, to: stage ? Paths.stagedManifest(slug: slug) : nil)

        return CreateResult(
            manifest: manifest,
            wrapperURL: output.url,
            frameworkDisplayName: target.framework.displayName,
            dataDirectories: plan.createDirectories,
            homeDirectory: plan.homeOverride,
            notes: notes,
            warnings: output.warnings
        )
    }

    /// The kept app a copy with these settings is built from, if it's pinned
    /// to one that's still there.
    static func pinnedSource(_ settings: InstanceSettings, slug: String) -> URL? {
        guard settings.isClone, let version = settings.pinnedVersion else { return nil }
        return AppVersions.app(for: version, slug: slug)
    }

    /// A refresh the copy's launcher put in place left items to release
    /// (`pendingRelease`): release them, once nothing runs from the copy.
    public static func finishPendingRelease(_ manifest: InstanceManifest) throws {
        guard let items = manifest.pendingRelease, !items.isEmpty, let home = manifest.redirectedHome else { return }
        let lock = try FileLock(URL(fileURLWithPath: Paths.pidFile(slug: manifest.slug).path + ".lock"))
        defer { lock.release() }
        guard var live = InstanceStore.load(slug: manifest.slug), live.pendingRelease == manifest.pendingRelease,
              !Running.isRunning(live), !Running.anythingRunning(inside: live.wrapperPath)
        else { return }
        releasePrivateItems(items.filter { !(live.privateHomeItems ?? []).contains($0) }, home: URL(fileURLWithPath: home, isDirectory: true))
        live.pendingRelease = nil
        try InstanceStore.save(live)
    }

    /// Undo keeping `items` (relative paths) to a copy: its own versions go
    /// to the Trash, and folders on the way that hold only links to your
    /// home are removed, so the launcher links them to yours again.
    public static func releasePrivateItems(_ items: [String], home: URL) {
        let fm = FileManager.default
        for item in items {
            let parts = item.split(separator: "/").map(String.init)
            guard !parts.isEmpty, parts.allSatisfy(OriginalData.isPlainName) else { continue }
            // Only what's really in the copy's home: a link anywhere on the
            // way (the home's link to your ~/.config, before the copy made
            // its own) leads to yours, which is never touched.
            var path = home
            var throughLink = false
            for part in parts {
                path = path.appendingPathComponent(part)
                var info = stat()
                if lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                    throughLink = true
                    break
                }
            }
            guard !throughLink,
                  path.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/")
            else { continue }
            if fm.fileExists(atPath: path.path) {
                try? Trash.move(path)
            }
            var parent = path.deletingLastPathComponent()
            while parent.path.count > home.path.count, parent.path.hasPrefix(home.path + "/") {
                let entries = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
                let onlyLinks = entries.allSatisfy {
                    $0 == ".DS_Store" || (try? fm.destinationOfSymbolicLink(atPath: parent.appendingPathComponent($0).path)) != nil
                }
                guard (try? fm.destinationOfSymbolicLink(atPath: parent.path)) == nil, onlyLinks else { break }
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
    }

    /// Clone mode: build a re-signed copy of the target (with the launcher
    /// as its main executable unless it's sandboxed) where the wrapper would
    /// go. Returns the executable the running instance will be.
    private static func buildClone(
        spec: WrapperSpec,
        target: AppInfo,
        previous: InstanceManifest?,
        separateGroups: Bool,
        hideFromDock: Bool = false,
        stageAt: URL? = nil,
        requireIdentity: Bool = false,
        builderOptions: BundleBuilder.Options
    ) throws -> (
        output: BundleBuilder.BuildOutput, record: InstanceManifest.CloneRecord, executable: String,
        groupMap: [String: String]
    ) {
        let fm = FileManager.default
        let assessment = AppCloner.assess(target)
        guard assessment.possible else {
            throw ParallexError(assessment.notes.joined(separator: " "))
        }
        if stageAt == nil, let previous {
            if Running.isRunning(previous) {
                throw ParallexError("Quit “\(previous.name)” first — its copy of the app is replaced when it's rebuilt.")
            }
            // Its app quit, but a helper of it (a login item, a menu bar
            // part) still runs from the copy: say which, to quit it.
            let helpers = Running.processNames(inside: previous.wrapperPath)
            if !helpers.isEmpty {
                throw ParallexError(
                    "“\(previous.name)” can't be rebuilt while part of it still runs: "
                    + helpers.map { "“\($0)”" }.joined(separator: ", ")
                    + ". Quit it (Activity Monitor can), then try again."
                )
            }
        }
        let destination = spec.outputDirectory.appendingPathComponent("\(spec.name).app", isDirectory: true)
        // The one foreign app this may replace: this instance's own copy,
        // which the app's updater swapped for its build (it goes to the Trash).
        let replacedCopy = previous.flatMap { previous in
            previous.clone.map { clone in
                sameItem(destination, URL(fileURLWithPath: previous.wrapperPath))
                    && InstanceStatus.isReplaced(destination, clone: clone)
                    && AppInspectorLite.bundleID(of: destination).map {
                        [clone.bundleIdentifier, previous.knownTargetBundleID].contains($0)
                    } == true
            }
        } ?? false
        if fm.fileExists(atPath: destination.path), !BundleBuilder.isParallexWrapper(destination), !replacedCopy {
            throw ParallexError(
                "\(destination.path) exists and is not a Parallex instance — refusing to replace it. Pick a different name."
            )
        }

        // Sandboxed apps keep their own executable (the launcher couldn't do
        // its work inside their sandbox); their container isolates them.
        let useLauncher = !target.isSandboxed
        let executable = destination.appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(target.executableURL.lastPathComponent).path
        var cloneSpec = spec
        cloneSpec.targetAppPath = ""
        cloneSpec.targetBundleID = nil
        cloneSpec.targetBinaryPath = executable
        if useLauncher, spec.redirectHome != nil {
            cloneSpec.redirectLibrary = try AppCloner.installHomeLibrary(from: LauncherLocator.locateHomeLibrary()).path
            cloneSpec.redirectScope = destination.standardizedFileURL.path
        } else {
            cloneSpec.redirectHome = nil
        }
        let config: [String: Any] = useLauncher
            ? BundleBuilder.launcherConfig(cloneSpec)
            : [ParallexConfig.Key.slug: spec.slug, ParallexConfig.Key.builtWith: ParallexConfig.version]

        // Only replace the app's icon when the user styled it.
        var warnings: [String] = []
        var icon: URL?
        if spec.badge != nil || isCustom(spec.iconSource), let source = spec.iconSource {
            let file = fm.temporaryDirectory.appendingPathComponent("parallex-icon-\(UUID().uuidString).icns")
            do {
                try IconBuilder.writeIcon(from: source, badge: spec.badge, to: file)
                icon = file
            } catch {
                warnings.append("Could not build the instance icon (\(error)); the copy keeps the app's icon.")
            }
        }
        defer {
            if let icon {
                _ = try? fm.removeItem(at: icon)
            }
        }

        // A sandboxed copy's own app groups (see AppCloner.renamedGroup).
        var groupMap: [String: String] = [:]
        var groupsLibrary: URL?
        if separateGroups, target.isSandboxed {
            // Keep the names a rebuild already gave (the copy's data is
            // there); new groups get this instance's tag.
            let previousMap = previous?.separatedGroups ?? [:]
            let tag = previousMap.values.first.flatMap { Self.groupTag(in: $0, slug: spec.slug) } ?? AppCloner.newGroupTag()
            for group in AppCloner.appGroups(of: target.url) {
                groupMap[group] = previousMap[group] ?? AppCloner.renamedGroup(group, slug: spec.slug, tag: tag)
            }
            if !groupMap.isEmpty {
                groupsLibrary = try LauncherLocator.locateGroupsLibrary()
            }
        }

        var buildSpec = AppCloner.CloneSpec(
            source: target,
            destination: destination,
            bundleIdentifier: spec.bundleIdentifier,
            displayName: spec.name,
            useLauncher: useLauncher,
            launcherBinary: spec.launcherBinary,
            launcherConfig: config,
            iconICNS: icon
        )
        buildSpec.groupMap = groupMap
        buildSpec.groupsLibrary = groupsLibrary
        buildSpec.hideFromDock = hideFromDock
        buildSpec.stageAt = stageAt
        buildSpec.requireIdentity = requireIdentity
        let url = try AppCloner.build(buildSpec, sign: builderOptions.sign)
        if stageAt == nil, builderOptions.registerWithLaunchServices, let lsregister = BundleBuilder.lsregisterPath {
            Shell.runAllowingFailure(lsregister, ["-f", url.path])
        }
        let record = InstanceManifest.CloneRecord(
            bundleIdentifier: spec.bundleIdentifier,
            sourceVersion: AppCloner.version(of: target.url),
            usesLauncher: useLauncher
        )
        return (BundleBuilder.BuildOutput(url: url, warnings: warnings), record, executable, groupMap)
    }

    /// The instance tag in a renamed group ("group.parallex.<slug>-<tag>.…").
    static func groupTag(in renamed: String, slug: String) -> String? {
        let prefix = "group.parallex.\(slug)-"
        guard renamed.hasPrefix(prefix) else { return nil }
        return renamed.dropFirst(prefix.count).split(separator: ".").first.map(String.init)
    }

    private static func isCustom(_ source: IconBuilder.IconSource?) -> Bool {
        if case .imageFile = source { return true }
        if case .icnsFile(let url) = source {
            return url.lastPathComponent.hasPrefix("custom-icon.")
        }
        return false
    }

    // MARK: Helpers

    /// The instances folder a built instance app reports to (from the pid
    /// file its launcher writes), or nil if it isn't a Parallex app or
    /// doesn't say.
    static func registryOwning(_ app: URL) -> URL? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let config = info[ParallexConfig.rootKey] as? [String: Any],
              let pidFile = config[ParallexConfig.Key.pidFile] as? String
        else {
            return nil
        }
        // <instances>/<slug>/instance.pid
        return URL(fileURLWithPath: pidFile).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func suggestName(targetName: String, outputDirectory: URL) -> String {
        for index in 2...999 {
            let candidate = "\(targetName) \(index)"
            let slug = Slug.make(candidate)
            let wrapperExists = FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent("\(candidate).app").path
            )
            if InstanceStore.load(slug: slug) == nil && !wrapperExists {
                return candidate
            }
        }
        return "\(targetName) \(Int.random(in: 1000...9999))"
    }

    static func resolveName(_ requested: String?, targetName: String, outDir: URL) throws -> String {
        guard let requested else {
            return suggestName(targetName: targetName, outputDirectory: outDir)
        }
        // One line, single-spaced: tabs and newlines pasted into a name
        // would otherwise end up in file names and menus.
        let trimmed = requested.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !trimmed.isEmpty else {
            throw ParallexError("The instance name must not be empty.")
        }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            throw ParallexError("The instance name must not contain '/' or ':'.")
        }
        return trimmed
    }

    private static func ensureWritableDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ParallexError("Output directory \(directory.path) does not exist and could not be created.")
            }
        } else if !isDirectory.boolValue {
            throw ParallexError("\(directory.path) is not a directory.")
        }
        guard fm.isWritableFile(atPath: directory.path) else {
            throw ParallexError(
                "No permission to write to \(directory.path). Try ~/Applications instead."
            )
        }
    }

    private static func validateBadge(_ settings: InstanceSettings) throws {
        if let colorHex = settings.badgeColorHex, IconBuilder.color(fromHex: colorHex) == nil {
            throw ParallexError("The color must be #RRGGBB hex, got '\(colorHex)'.")
        }
        guard let text = settings.badgeText else {
            return
        }
        guard text == text.trimmingCharacters(in: .whitespaces), (1...2).contains(text.count) else {
            throw ParallexError("The badge must be 1 or 2 characters, got '\(text)'.")
        }
        if let colorHex = settings.badgeColorHex, IconBuilder.color(fromHex: colorHex) == nil {
            throw ParallexError("The badge color must be #RRGGBB hex, got '\(colorHex)'.")
        }
    }

    /// Copy a custom icon into the instance directory; returns its file name.
    private static func storeCustomIcon(_ source: URL, slug: String) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ParallexError("Icon file not found: \(source.path)")
        }
        let instanceDir = Paths.instanceDir(slug: slug)
        try fm.createDirectory(at: instanceDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let fileName = "custom-icon.\(ext)"
        let destination = instanceDir.appendingPathComponent(fileName)
        if source.standardizedFileURL.path == destination.standardizedFileURL.path {
            return fileName
        }
        // Drop any earlier custom icon (possibly another extension).
        for old in (try? fm.contentsOfDirectory(atPath: instanceDir.path)) ?? []
        where old.hasPrefix("custom-icon.") {
            try? fm.removeItem(at: instanceDir.appendingPathComponent(old))
        }
        try fm.copyItem(at: source, to: destination)
        return fileName
    }

    private static func resolveIconSource(custom: URL?, target: AppInfo) throws -> IconBuilder.IconSource {
        if let custom {
            guard FileManager.default.fileExists(atPath: custom.path) else {
                throw ParallexError("Icon file not found: \(custom.path)")
            }
            return custom.pathExtension.lowercased() == "icns" ? .icnsFile(custom) : .imageFile(custom)
        }
        // The icon macOS actually shows for the app — not the bundle's .icns,
        // which is often a legacy full-bleed image (Electron apps keep their
        // real icon in an asset catalog). macOS 26 puts legacy-shaped icons
        // on a grey plate, so building from the .icns made instances look
        // broken next to their original.
        return .appGeneric(target.url)
    }
}

// MARK: - Remove

public struct RemoveResult: Sendable {
    public let instanceName: String
    public let wrapperTrashed: Bool
    public let wrapperWasMissing: Bool
    /// The path existed but wasn't a Parallex wrapper anymore, so it was left alone.
    public let wrapperSkippedForeign: Bool
    public let dataTrashed: Bool
    /// Set when data was deliberately kept (keepData), with its location.
    public let dataKeptAt: String?
    public let wasRunning: Bool
    /// A clone's sandbox container, which macOS doesn't let other apps
    /// delete; the user can remove it in Finder.
    /// The copy's sandbox containers (its own and its services'), which
    /// macOS only lets the user delete.
    public let leftoverContainers: [String]
}

public enum InstanceRemover {
    /// Remove an instance. Everything goes through the Trash, never `rm -rf`,
    /// and bundles Parallex didn't create are never touched.
    public static func remove(_ manifest: InstanceManifest, keepData: Bool) throws -> RemoveResult {
        let fm = FileManager.default
        let wasRunning = Running.isRunning(manifest)

        // Before the copy goes to the Trash: it's how its identifier is
        // told apart from any other copy's.
        if manifest.clone != nil, !keepData, !wasRunning {
            let instanceDir = Paths.instanceDir(slug: manifest.slug)
            if fm.fileExists(atPath: instanceDir.path) {
                moveSystemState(of: manifest, into: instanceDir)
            }
        }

        var wrapperTrashed = false
        var wrapperWasMissing = false
        var wrapperSkippedForeign = false
        let wrapper = URL(fileURLWithPath: manifest.wrapperPath)
        if fm.fileExists(atPath: wrapper.path) {
            if BundleBuilder.isParallexWrapper(wrapper) {
                BundleBuilder.unregister(wrapper)
                try Trash.move(wrapper)
                wrapperTrashed = true
            } else {
                wrapperSkippedForeign = true
            }
        } else {
            wrapperWasMissing = true
        }

        var dataTrashed = false
        var dataKeptAt: String?
        let instanceDir = Paths.instanceDir(slug: manifest.slug)
        if keepData {
            // Drop just the manifest so the instance is forgotten; the data
            // stays put for later inspection or re-use.
            try? fm.removeItem(at: InstanceStore.manifestURL(slug: manifest.slug))
            dataKeptAt = instanceDir.path
        } else if fm.fileExists(atPath: instanceDir.path) {
            try Trash.move(instanceDir)
            dataTrashed = true
        }

        WorkspaceStore.forget(slug: manifest.slug)
        var leftoverGroups: [String] = []
        if !keepData {
            let groups = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers")
            for renamed in (manifest.separatedGroups ?? [:]).values.sorted() where renamed.hasPrefix("group.parallex.") {
                let container = groups.appendingPathComponent(renamed)
                if fm.fileExists(atPath: container.path), (try? Trash.move(container)) == nil {
                    leftoverGroups.append(container.path)
                }
            }
        }

        return RemoveResult(
            instanceName: manifest.name,
            wrapperTrashed: wrapperTrashed,
            wrapperWasMissing: wrapperWasMissing,
            wrapperSkippedForeign: wrapperSkippedForeign,
            dataTrashed: dataTrashed,
            dataKeptAt: dataKeptAt,
            wasRunning: wasRunning,
            leftoverContainers: (manifest.clone.map { clone in
                let containers = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
                return ((try? fm.contentsOfDirectory(atPath: containers.path)) ?? [])
                    .filter { $0 == clone.bundleIdentifier || $0.hasPrefix(clone.bundleIdentifier + ".") }
                    .sorted()
                    .map { containers.appendingPathComponent($0).path }
            } ?? []) + leftoverGroups
        )
    }

    /// An own-identity copy's preferences and saved window state live where
    /// macOS keeps them for its bundle ID (the preferences daemon isn't
    /// redirected). Move them in with the instance's data, so they go to the
    /// Trash together and nothing is left behind.
    static func moveSystemState(of manifest: InstanceManifest, into instanceDir: URL) {
        guard let identifier = manifest.clone?.bundleIdentifier, identifier.hasPrefix("com.parallex.instance.") else {
            return
        }
        let fm = FileManager.default
        // Another copy with the same identifier (an instance of the same
        // name in another Parallex library) shares the preferences domain.
        // (Launch Services queries are safe off the main thread.)
        let others = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
            .filter { $0.standardizedFileURL.path != URL(fileURLWithPath: manifest.wrapperPath).standardizedFileURL.path }
            .filter { !$0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) }
        guard others.isEmpty else { return }
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let preferences = library.appendingPathComponent("Preferences/\(identifier).plist")
        if fm.fileExists(atPath: preferences.path) {
            let saved = instanceDir.appendingPathComponent("preferences.plist")
            // Through the preferences daemon, which may hold newer values
            // than the file (and would write them back after a plain move).
            if (try? Shell.run("/usr/bin/defaults", ["export", identifier, saved.path])) != nil {
                Shell.runAllowingFailure("/usr/bin/defaults", ["delete", identifier])
                // The daemon leaves an empty file behind; its contents are
                // saved above.
                if let remaining = NSDictionary(contentsOf: preferences), remaining.count == 0 {
                    try? fm.removeItem(at: preferences)
                }
            }
        }
        let state = library.appendingPathComponent("Saved Application State/\(identifier).savedState")
        if fm.fileExists(atPath: state.path) {
            try? fm.moveItem(at: state, to: instanceDir.appendingPathComponent("saved-state"))
        }
    }
}
