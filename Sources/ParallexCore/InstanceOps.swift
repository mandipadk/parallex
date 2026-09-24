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

/// Duplicating an instance: the same app and settings under a new name,
/// optionally with a copy of its data.
extension InstanceCreator {
    public static func duplicate(
        _ manifest: InstanceManifest,
        name: String? = nil,
        includeData: Bool = false,
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
            name: name ?? duplicateName(for: manifest.name),
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
    static func duplicateName(for name: String) -> String {
        let names = Set(InstanceStore.loadAll().map { $0.name.lowercased() })
        var candidate = "\(name) Copy"
        var index = 2
        while names.contains(candidate.lowercased()) {
            candidate = "\(name) Copy \(index)"
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
        let skipped: Set<String> = ["instance.json", "instance.pid"]
        for item in (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
        where !skipped.contains(item) && !item.hasPrefix("custom-icon.") {
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
        let fm = FileManager.default
        let appURL = try AppResolver.resolve(request.appReference)
        let target = try AppInspector.inspect(appURL)
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

        let existing = InstanceStore.load(slug: slug)
        if existing != nil && !request.force {
            throw ParallexError(
                "An instance named '\(instanceName)' already exists. Rebuild it with force, or pick another name."
            )
        }
        let wrapperURL = outDir.appendingPathComponent("\(instanceName).app")
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
        try validateBadge(settings)
        if let adopt = request.adoptData {
            try validateAdoptable(adopt, target: target, slug: slug)
        }
        if let icon = request.customIcon {
            settings.customIconFile = try storeCustomIcon(icon, slug: slug)
        }

        let result = try assemble(
            target: target,
            name: instanceName,
            slug: slug,
            outputDirectory: outDir,
            settings: settings,
            previous: existing,
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
            names: [target.name, target.url.deletingPathExtension().lastPathComponent]
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
    public static func update(
        _ manifest: InstanceManifest,
        _ change: InstanceUpdate = InstanceUpdate(),
        builderOptions: BundleBuilder.Options = BundleBuilder.Options()
    ) throws -> CreateResult {
        let fm = FileManager.default
        var settings = change.settings ?? manifest.effectiveSettings

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

        let targetURL = try change.targetApp ?? locateTarget(of: manifest)
        let target = try AppInspector.inspect(targetURL)
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

        let result = try assemble(
            target: target,
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
    private static func assemble(
        target: AppInfo,
        name instanceName: String,
        slug: String,
        outputDirectory outDir: URL,
        settings: InstanceSettings,
        previous: InstanceManifest?,
        builderOptions: BundleBuilder.Options
    ) throws -> CreateResult {
        let instanceDir = Paths.instanceDir(slug: slug)
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
        // A dedicated home mirrors yours, except for the app's own folders
        // (and what the user shares explicitly). Home mode keeps its promise
        // of a home of its own, shared items aside.
        let privateHomeItems = redirectHome != nil && plan.homeOverride == nil && settings.separateHiddenFolders != false
            ? Presets.privateHomeItems(for: target).filter { item in
                !sharedItems.contains { item == $0 || item.hasPrefix($0 + "/") || $0.hasPrefix(item + "/") }
            }
            : nil

        // Plan recipe first, user-provided vars win, PARALLEX_INSTANCE always set.
        var environment = plan.environment
        environment.merge(settings.extraEnvironment) { _, user in user }
        environment["PARALLEX_INSTANCE"] = slug
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
            applicationCategory: target.infoPlist["LSApplicationCategoryType"] as? String,
            outputDirectory: outDir,
            launcherBinary: try LauncherLocator.locate(),
            iconSource: try resolveIconSource(custom: customIcon, target: target),
            badge: settings.badgeText.map {
                IconBuilder.Badge(text: $0, colorHex: settings.badgeColorHex, colorSeed: slug)
            },
            pidFile: Paths.pidFile(slug: slug).path,
            redirectHome: redirectHome,
            redirectPrivate: privateHomeItems
        )

        var notes = plan.notes
        var separatedGroups: [String: String]?
        let output: BundleBuilder.BuildOutput
        var cloneRecord: InstanceManifest.CloneRecord?
        if settings.isClone {
            let built = try buildClone(
                spec: spec, target: target, previous: previous,
                separateGroups: settings.separatesLibrary(for: target) && target.isSandboxed,
                builderOptions: builderOptions
            )
            separatedGroups = built.groupMap.isEmpty ? nil : built.groupMap
            output = built.output
            cloneRecord = built.record
            spec.targetBinaryPath = built.executable
            notes += AppCloner.assess(target).notes
            if !built.record.usesLauncher,
               !settings.extraEnvironment.isEmpty || !settings.extraArguments.isEmpty || settings.mode != .auto {
                notes.append(
                    "Extra environment, arguments, and isolation modes don't apply to a sandboxed app's copy — "
                    + "it starts directly, and its container is what keeps it separate."
                )
            }
        } else {
            output = try BundleBuilder(options: builderOptions).build(spec)
        }

        let manifest = InstanceManifest(
            name: instanceName,
            slug: slug,
            bundleIdentifier: spec.bundleIdentifier,
            targetApp: target.url.path,
            targetBinary: spec.targetBinaryPath,
            wrapperPath: output.url.path,
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
            links: plan.links.isEmpty ? nil : plan.links
        )
        try InstanceStore.save(manifest)

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

    /// Clone mode: build a re-signed copy of the target (with the launcher
    /// as its main executable unless it's sandboxed) where the wrapper would
    /// go. Returns the executable the running instance will be.
    private static func buildClone(
        spec: WrapperSpec,
        target: AppInfo,
        previous: InstanceManifest?,
        separateGroups: Bool,
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
        if let previous, Running.isRunning(previous) {
            throw ParallexError("Quit “\(previous.name)” first — its copy of the app is replaced when it's rebuilt.")
        }
        let destination = spec.outputDirectory.appendingPathComponent("\(spec.name).app", isDirectory: true)
        if fm.fileExists(atPath: destination.path), !BundleBuilder.isParallexWrapper(destination) {
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
            : [ParallexConfig.Key.slug: spec.slug]

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
        let url = try AppCloner.build(buildSpec, sign: builderOptions.sign)
        if builderOptions.registerWithLaunchServices, let lsregister = BundleBuilder.lsregisterPath {
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
