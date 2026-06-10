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
        self.force = force
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
            suggestedName: suggestName(targetName: info.name, outputDirectory: outputDirectory)
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

        let instanceName = try resolveName(request.name, targetName: target.name, outDir: outDir)
        let slug = Slug.make(instanceName)
        guard !slug.isEmpty else {
            throw ParallexError("Instance name '\(instanceName)' contains no letters or digits — pick another name.")
        }

        if InstanceStore.load(slug: slug) != nil && !request.force {
            throw ParallexError(
                "An instance named '\(instanceName)' already exists. Rebuild it with force, or pick another name."
            )
        }
        let wrapperURL = outDir.appendingPathComponent("\(instanceName).app")
        if fm.fileExists(atPath: wrapperURL.path) && !request.force {
            throw ParallexError(
                "\(wrapperURL.path) already exists. Rebuild with force (only Parallex wrappers are replaced), "
                + "or pick another name."
            )
        }

        let instanceDir = Paths.instanceDir(slug: slug)
        var sharedItems = request.includeDefaultSharedItems ? Presets.defaultSharedItems : []
        sharedItems.append(contentsOf: request.extraSharedItems.filter { !sharedItems.contains($0) })

        let plan = Presets.plan(
            for: target,
            requested: request.mode,
            instanceDir: instanceDir,
            sharedItems: sharedItems
        )

        // Plan recipe first, user-provided vars win, PARALLEX_INSTANCE always set.
        var environment = plan.environment
        environment.merge(request.environment) { _, user in user }
        environment["PARALLEX_INSTANCE"] = slug
        let arguments = plan.arguments + request.extraArguments

        let spec = WrapperSpec(
            name: instanceName,
            slug: slug,
            bundleIdentifier: "com.parallex.instance.\(slug)",
            targetAppPath: target.url.path,
            targetBinaryPath: target.executableURL.path,
            arguments: arguments,
            environment: environment,
            homeOverride: plan.homeOverride,
            homeSymlinks: plan.homeSymlinks,
            createDirectories: plan.createDirectories,
            applicationCategory: target.infoPlist["LSApplicationCategoryType"] as? String,
            outputDirectory: outDir,
            launcherBinary: try LauncherLocator.locate(),
            iconSource: try resolveIconSource(custom: request.customIcon, target: target),
            badge: try makeBadge(
                text: request.badgeText,
                colorHex: request.badgeColorHex,
                slug: slug
            ),
            pidFile: Paths.pidFile(slug: slug).path
        )

        let output = try BundleBuilder(options: builderOptions).build(spec)

        let manifest = InstanceManifest(
            name: instanceName,
            slug: slug,
            bundleIdentifier: spec.bundleIdentifier,
            targetApp: target.url.path,
            targetBinary: target.executableURL.path,
            wrapperPath: output.url.path,
            mode: plan.mode,
            preset: plan.presetID,
            arguments: arguments,
            environment: environment,
            homeSymlinks: plan.homeOverride != nil ? plan.homeSymlinks : nil,
            createdAt: Date(),
            parallexVersion: ParallexConfig.version
        )
        try InstanceStore.save(manifest)

        return CreateResult(
            manifest: manifest,
            wrapperURL: output.url,
            frameworkDisplayName: target.framework.displayName,
            dataDirectories: plan.createDirectories,
            homeDirectory: plan.homeOverride,
            notes: plan.notes,
            warnings: output.warnings
        )
    }

    // MARK: Helpers

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

    private static func resolveName(_ requested: String?, targetName: String, outDir: URL) throws -> String {
        guard let requested else {
            return suggestName(targetName: targetName, outputDirectory: outDir)
        }
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func makeBadge(text: String?, colorHex: String?, slug: String) throws -> IconBuilder.Badge? {
        guard let text else {
            if colorHex != nil {
                throw ParallexError("A badge color was given without badge text.")
            }
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...2).contains(trimmed.count) else {
            throw ParallexError("The badge must be 1 or 2 characters, got '\(text)'.")
        }
        if let colorHex, IconBuilder.color(fromHex: colorHex) == nil {
            throw ParallexError("The badge color must be #RRGGBB hex, got '\(colorHex)'.")
        }
        return IconBuilder.Badge(text: trimmed, colorHex: colorHex, colorSeed: slug)
    }

    private static func resolveIconSource(custom: URL?, target: AppInfo) throws -> IconBuilder.IconSource {
        if let custom {
            guard FileManager.default.fileExists(atPath: custom.path) else {
                throw ParallexError("Icon file not found: \(custom.path)")
            }
            return custom.pathExtension.lowercased() == "icns" ? .icnsFile(custom) : .imageFile(custom)
        }
        if let iconFile = target.iconFileURL {
            return .icnsFile(iconFile)
        }
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
}

public enum InstanceRemover {
    /// Remove an instance. Everything goes through the Trash, never `rm -rf`,
    /// and bundles Parallex didn't create are never touched.
    public static func remove(_ manifest: InstanceManifest, keepData: Bool) throws -> RemoveResult {
        let fm = FileManager.default
        let wasRunning = Running.isRunning(instanceSlug: manifest.slug, targetBinary: manifest.targetBinary)

        var wrapperTrashed = false
        var wrapperWasMissing = false
        var wrapperSkippedForeign = false
        let wrapper = URL(fileURLWithPath: manifest.wrapperPath)
        if fm.fileExists(atPath: wrapper.path) {
            if BundleBuilder.isParallexWrapper(wrapper) {
                try fm.trashItem(at: wrapper, resultingItemURL: nil)
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
            try fm.trashItem(at: instanceDir, resultingItemURL: nil)
            dataTrashed = true
        }

        return RemoveResult(
            instanceName: manifest.name,
            wrapperTrashed: wrapperTrashed,
            wrapperWasMissing: wrapperWasMissing,
            wrapperSkippedForeign: wrapperSkippedForeign,
            dataTrashed: dataTrashed,
            dataKeptAt: dataKeptAt,
            wasRunning: wasRunning
        )
    }
}
