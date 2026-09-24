import Foundation
import ParallexKit

/// Isolation mode of a created instance (the `auto` of `--mode auto` is
/// resolved before anything is stored).
public enum InstanceMode: String, Codable, Sendable {
    case dataDir = "data-dir"
    case home
    case launchOnly = "launch-only"

    public var summary: String {
        switch self {
        case .dataDir: "app-aware isolation (data-dir flags)"
        case .home: "HOME override (generic isolation)"
        case .launchOnly: "separate identity only — no data isolation"
        }
    }
}

/// What the user chose for an instance — as opposed to the launch config
/// derived from it. Rebuilds and edits re-derive the launch config from
/// these, so recipe improvements reach old instances and nothing the user
/// picked is lost.
public struct InstanceSettings: Codable, Sendable, Equatable {
    public var requestedMode: String
    public var badgeText: String?
    public var badgeColorHex: String?
    /// File name of the custom icon, kept inside the instance directory so it
    /// survives the original file moving.
    public var customIconFile: String?
    public var extraEnvironment: [String: String]
    public var extraArguments: [String]
    public var extraSharedItems: [String]
    public var includeDefaultSharedItems: Bool
    /// Recipe options turned on; `nil` means the recipe's defaults.
    public var enabledOptions: [String]?
    /// Clone mode: the instance is a re-signed copy of the app with its own
    /// identity (see `AppCloner`). `nil` means off.
    public var cloneApp: Bool?
    /// Open this instance whenever Parallex starts (e.g. at login).
    public var openAtLaunch: Bool?
    /// Global keyboard shortcut that opens (or brings forward) the instance.
    public var shortcut: KeyShortcut?
    /// An icon in the menu bar that opens, brings forward or hides it.
    public var menuBarIcon: Bool?
    /// Own-identity copies keep their data to themselves: a copy of an app
    /// that isn't sandboxed gets its own ~/Library (Application Support,
    /// caches, web storage…); a copy of a sandboxed app gets its own
    /// app-group containers. `nil` means on; `false` turns it off.
    public var separateLibrary: Bool?
    /// With its own Library, the copy's home mirrors yours except for the
    /// app's own hidden folders (like ~/.vscode), which stay in the
    /// instance too. `nil` means on; `false` shares them with the original.
    public var separateHiddenFolders: Bool?

    public var isClone: Bool { cloneApp == true }

    /// Whether an own-identity copy of `app` keeps its data separate (its
    /// own ~/Library, or for a sandboxed app its own app groups).
    public func separatesLibrary(for app: AppInfo) -> Bool {
        isClone && separateLibrary != false
    }

    public init(
        requestedMode: RequestedMode = .auto,
        badgeText: String? = nil,
        badgeColorHex: String? = nil,
        customIconFile: String? = nil,
        extraEnvironment: [String: String] = [:],
        extraArguments: [String] = [],
        extraSharedItems: [String] = [],
        includeDefaultSharedItems: Bool = true,
        enabledOptions: [String]? = nil,
        cloneApp: Bool? = nil,
        openAtLaunch: Bool? = nil,
        shortcut: KeyShortcut? = nil
    ) {
        self.requestedMode = requestedMode.rawValue
        self.badgeText = badgeText
        self.badgeColorHex = badgeColorHex
        self.customIconFile = customIconFile
        self.extraEnvironment = extraEnvironment
        self.extraArguments = extraArguments
        self.extraSharedItems = extraSharedItems
        self.includeDefaultSharedItems = includeDefaultSharedItems
        self.enabledOptions = enabledOptions
        self.cloneApp = cloneApp
        self.openAtLaunch = openAtLaunch
        self.shortcut = shortcut
    }

    /// Whether going from `self` to `other` changes the built wrapper (or
    /// copy). Launch preferences, the shortcut, and the color while there's
    /// no badge to paint it on, are bookkeeping only.
    public func requiresRebuild(toReach other: InstanceSettings) -> Bool {
        var lhs = self
        var rhs = other
        lhs.openAtLaunch = nil
        rhs.openAtLaunch = nil
        lhs.shortcut = nil
        rhs.shortcut = nil
        lhs.menuBarIcon = nil
        rhs.menuBarIcon = nil
        if lhs.badgeText == nil && rhs.badgeText == nil {
            lhs.badgeColorHex = nil
            rhs.badgeColorHex = nil
        }
        return lhs != rhs
    }

    public var mode: RequestedMode {
        get { RequestedMode(rawValue: requestedMode) ?? .auto }
        set { requestedMode = newValue.rawValue }
    }

    /// The option IDs in effect, given the recipe's options.
    public func activeOptions(of available: [RecipeOption]) -> Set<String> {
        enabledOptions.map(Set.init) ?? Set(available.filter(\.defaultEnabled).map(\.id))
    }

    /// Turn one recipe option on or off (materializing the defaults first).
    public mutating func setOption(_ id: String, enabled: Bool, available: [RecipeOption]) {
        var active = activeOptions(of: available)
        if enabled {
            active.insert(id)
        } else {
            active.remove(id)
        }
        enabledOptions = available.map(\.id).filter(active.contains)
    }
}

/// Everything we know about a created instance. Stored as pretty JSON at
/// `<instance dir>/instance.json`, co-located with the instance's data so
/// removing the directory removes every trace.
public struct InstanceManifest: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var name: String
    public var slug: String
    public var bundleIdentifier: String
    public var targetApp: String
    public var targetBinary: String
    public var wrapperPath: String
    public var mode: InstanceMode
    public var preset: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var homeSymlinks: [String]?
    public var createdAt: Date
    public var parallexVersion: String
    /// The target's bundle ID (schema 2+), for finding a moved target.
    public var targetBundleID: String?
    /// The user's choices (schema 2+). Older manifests: see `effectiveSettings`.
    public var settings: InstanceSettings?
    /// Set when the instance is a clone of its target app.
    public var clone: CloneRecord?
    /// The home an own-identity copy is shown as the user's (its own
    /// ~/Library lives there). Nil when the copy uses the real ~/Library.
    public var redirectedHome: String?
    /// A sandboxed copy's app groups: the original's → the copy's own.
    public var separatedGroups: [String: String]?
    /// When the copy's home mirrors yours: the app's own items, which stay
    /// in the instance (see `HomeMirror`).
    public var privateHomeItems: [String]?
    /// Short aliases the launcher keeps pointing at long paths (alias → target).
    public var links: [String: String]?
    /// What the copy's "<App> Safe Storage" keychain items are renamed with
    /// (its own encryption key). Nil: it uses the original's, as copies
    /// made before 0.13.1 do, and copies started from the original's data.
    public var keychainSuffix: String?

    public struct CloneRecord: Codable, Sendable, Equatable {
        /// The copy's own bundle identifier.
        public var bundleIdentifier: String
        /// The original's version when the copy was made, to spot updates.
        public var sourceVersion: String
        /// Whether the copy starts through the Parallex launcher.
        public var usesLauncher: Bool
    }

    init(
        name: String,
        slug: String,
        bundleIdentifier: String,
        targetApp: String,
        targetBinary: String,
        wrapperPath: String,
        mode: InstanceMode,
        preset: String?,
        arguments: [String],
        environment: [String: String],
        homeSymlinks: [String]?,
        createdAt: Date,
        parallexVersion: String,
        targetBundleID: String? = nil,
        settings: InstanceSettings? = nil,
        clone: CloneRecord? = nil,
        redirectedHome: String? = nil,
        separatedGroups: [String: String]? = nil,
        privateHomeItems: [String]? = nil,
        links: [String: String]? = nil,
        keychainSuffix: String? = nil
    ) {
        self.name = name
        self.slug = slug
        self.bundleIdentifier = bundleIdentifier
        self.targetApp = targetApp
        self.targetBinary = targetBinary
        self.wrapperPath = wrapperPath
        self.mode = mode
        self.preset = preset
        self.arguments = arguments
        self.environment = environment
        self.homeSymlinks = homeSymlinks
        self.createdAt = createdAt
        self.parallexVersion = parallexVersion
        self.targetBundleID = targetBundleID
        self.settings = settings
        self.clone = clone
        self.redirectedHome = redirectedHome
        self.separatedGroups = separatedGroups
        self.privateHomeItems = privateHomeItems
        self.links = links
        self.keychainSuffix = keychainSuffix
        if settings != nil {
            schemaVersion = 2
        }
    }

    /// The instance's settings, reconstructed for schema-1 manifests (which
    /// stored only the resolved launch config). Isolation-generated arguments
    /// and environment point into the instance directory, which is how
    /// user-supplied extras are told apart.
    public var effectiveSettings: InstanceSettings {
        if var settings {
            // Own-identity copies made before 0.9 used the real ~/Library;
            // keep it that way until the user turns separation on, so a
            // routine rebuild doesn't make the copy look signed out.
            // Likewise copies of sandboxed apps made before 0.12, which
            // shared the original's app groups.
            if settings.separateLibrary == nil, let clone, redirectedHome == nil, separatedGroups == nil {
                let introduced = clone.usesLauncher ? "0.9.0" : "0.12.0"
                if InstanceStatus.compareVersions(parallexVersion, introduced) == .orderedAscending {
                    settings.separateLibrary = false
                }
            }
            // Copies made before 0.13 shared the app's hidden folders (a
            // VS Code copy used ~/.vscode); keep that until turned on.
            if settings.separateHiddenFolders == nil, redirectedHome != nil, privateHomeItems == nil,
               InstanceStatus.compareVersions(parallexVersion, "0.13.0") == .orderedAscending {
                settings.separateHiddenFolders = false
            }
            return settings
        }
        let instancePath = Paths.instanceDir(slug: slug).path
        let requested: RequestedMode
        switch mode {
        case .dataDir: requested = preset == "generic-data-dir" ? .dataDir : .auto
        case .home: requested = .home
        case .launchOnly: requested = .launchOnly
        }
        var extraEnvironment = environment
        extraEnvironment["PARALLEX_INSTANCE"] = nil
        extraEnvironment = extraEnvironment.filter { !$0.value.hasPrefix(instancePath) }
        let shared = homeSymlinks ?? []
        let defaults = Presets.defaultSharedItems
        return InstanceSettings(
            requestedMode: requested,
            extraEnvironment: extraEnvironment,
            extraArguments: Self.userArguments(in: arguments, instancePath: instancePath, preset: preset),
            extraSharedItems: shared.filter { !defaults.contains($0) },
            includeDefaultSharedItems: homeSymlinks == nil || defaults.allSatisfy(shared.contains)
        )
    }

    /// The target's bundle ID: recorded since schema 2; for older recipe
    /// instances the preset is the recipe ID, which is the bundle ID.
    public var knownTargetBundleID: String? {
        if let targetBundleID {
            return targetBundleID
        }
        if let preset, Presets.recipes.contains(where: { $0.id == preset }) {
            return preset
        }
        return nil
    }

    /// One line describing how the instance is isolated.
    public var isolationSummary: String {
        guard let clone else { return "\(mode.rawValue) — \(mode.summary)" }
        switch mode {
        case .launchOnly where clone.usesLauncher == false:
            return "own identity — a copy of the app with its own bundle ID and sandbox container"
        case .launchOnly:
            return "own identity — a copy of the app with its own bundle ID (data not separated)"
        default:
            let library = redirectedHome != nil ? " and its own ~/Library" : ""
            return "own identity + \(mode.rawValue) — a copy of the app with its own bundle ID\(library), \(mode.summary)"
        }
    }

    /// The per-app recipe this instance's app has, if any.
    public var recipe: AppRecipe? {
        if let preset, let byID = Presets.recipes.first(where: { $0.id == preset }) {
            return byID
        }
        if let targetBundleID {
            return Presets.recipe(for: targetBundleID)
        }
        // Schema 1: ask the target bundle itself.
        let infoPlist = URL(fileURLWithPath: targetApp).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else {
            return nil
        }
        return Presets.recipe(for: bundleID)
    }

    /// Strip what isolation generated from a schema-1 argument list: values
    /// pointing into the instance directory, a flag whose value that was
    /// (`--profile <dir>`), and Firefox's `--no-remote`.
    static func userArguments(in arguments: [String], instancePath: String, preset: String?) -> [String] {
        var kept: [String] = []
        for argument in arguments {
            if argument.contains(instancePath) {
                if let last = kept.last, last.hasPrefix("-"), !last.contains("=") {
                    kept.removeLast()
                }
                continue
            }
            kept.append(argument)
        }
        if preset == AppFramework.firefox.rawValue, let index = kept.firstIndex(of: "--no-remote") {
            kept.remove(at: index)
        }
        return kept
    }

    /// The color that identifies this instance (badge, window tags, menus).
    public var colorHex: String {
        effectiveSettings.badgeColorHex ?? IconBuilder.defaultColorHex(for: slug)
    }
}

public enum InstanceStore {
    public static let manifestFilename = "instance.json"

    public static func manifestURL(slug: String) -> URL {
        Paths.instanceDir(slug: slug).appendingPathComponent(manifestFilename)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func save(_ manifest: InstanceManifest) throws {
        let url = manifestURL(slug: manifest.slug)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    public static func load(slug: String) -> InstanceManifest? {
        guard let data = try? Data(contentsOf: manifestURL(slug: slug)) else {
            return nil
        }
        return try? decoder.decode(InstanceManifest.self, from: data)
    }

    /// An exclusive lock held while an instance is being created, shared
    /// between threads and processes (it's an `flock` on a file in the
    /// registry). Release it when done; it's also released if the process dies.
    public static func creationLock() throws -> FileLock {
        let root = Paths.instancesRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FileLock(root.appendingPathComponent(".create.lock"))
    }

    /// All known instances, sorted by name. Corrupt manifests are reported on
    /// stderr and skipped rather than failing the whole listing.
    public static func loadAll() -> [InstanceManifest] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Paths.instancesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        var manifests: [InstanceManifest] = []
        for entry in entries {
            let manifestFile = entry.appendingPathComponent(manifestFilename)
            guard fm.fileExists(atPath: manifestFile.path) else { continue }
            do {
                let data = try Data(contentsOf: manifestFile)
                manifests.append(try decoder.decode(InstanceManifest.self, from: data))
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: skipping unreadable manifest \(manifestFile.path): \(error)\n".utf8
                ))
            }
        }
        return manifests.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Look an instance up by display name (case-insensitive) or slug.
    /// An exact name wins: two names can reduce to the same slug
    /// ("Claude Work", "Claude—Work"), and the second one gets "-2".
    public static func find(_ nameOrSlug: String) -> InstanceManifest? {
        let all = loadAll()
        if let byName = all.first(where: { $0.name.caseInsensitiveCompare(nameOrSlug) == .orderedSame }) {
            return byName
        }
        if let bySlug = load(slug: nameOrSlug) {
            return bySlug
        }
        let slugified = Slug.forInstance(named: nameOrSlug)
        if !slugified.isEmpty, let manifest = load(slug: slugified) {
            return manifest
        }
        return nil
    }
}

/// An exclusive advisory lock on a file, blocking until it's acquired.
public final class FileLock: @unchecked Sendable {
    private var descriptor: Int32

    init(_ url: URL) throws {
        descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ParallexError("Couldn't open \(url.path) to lock it (\(String(cString: strerror(errno)))).")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw ParallexError("Couldn't lock \(url.path) (\(String(cString: strerror(errno)))).")
            }
        }
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
