import Foundation
import ParallexKit

/// An instance as one file — its settings and data — for backups and moving
/// to another Mac. A `.parallex` file is a zip of the instance's folder (plus
/// an own-identity copy's preferences). Importing rebuilds the instance's
/// app on this Mac from the settings, under a name that's free here.
public enum InstanceArchive {
    public static let fileExtension = "parallex"
    static let preferencesFile = "preferences.plist"

    /// Write `manifest`'s instance to a `.parallex` file at `destination`
    /// (or inside it, when it's a folder). Returns the file written.
    @discardableResult
    public static func export(_ manifest: InstanceManifest, to destination: URL) throws -> URL {
        if Running.isRunning(manifest) {
            throw ParallexError("Quit “\(manifest.name)” first, so its data is saved in a consistent state.")
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let file = fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? destination.appendingPathComponent("\(manifest.name).\(fileExtension)")
            : destination
        if fm.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ParallexError("\(file.path) is a folder; choose a file name.")
        }
        let source = Paths.instanceDir(slug: manifest.slug)
        let staging = fm.temporaryDirectory.appendingPathComponent("parallex-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(manifest.slug, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Shell.run("/bin/cp", ["-cRp", source.path, folder.path])
        try? fm.removeItem(at: folder.appendingPathComponent("instance.pid"))
        InstanceCreator.removeRunState(in: folder)
        // Links to this Mac's home (the instance home's shared folders) mean
        // nothing elsewhere; the launcher recreates them where it's imported.
        removeLinks(leaving: folder)
        if let copyID = manifest.clone?.bundleIdentifier {
            _ = try? Shell.run("/usr/bin/defaults", ["export", copyID, folder.appendingPathComponent(preferencesFile).path])
        }
        // Zip next to the destination first; replace it only once that worked.
        let zipped = staging.appendingPathComponent("archive.\(fileExtension)")
        try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zipped.path])
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: zipped)
        } else {
            try fm.moveItem(at: zipped, to: file)
        }
        return file
    }

    /// Remove symbolic links under `folder` that point outside it.
    static func removeLinks(leaving folder: URL) {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        var outside: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
            else { continue }
            let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : url.deletingLastPathComponent().appendingPathComponent(target)).standardizedFileURL.path
            if resolved != root && !resolved.hasPrefix(root + "/") {
                outside.append(url)
            }
        }
        for url in outside {
            try? fm.removeItem(at: url)
        }
    }

    /// What a `.parallex` file holds, for confirming before importing.
    public struct Preview: Sendable {
        public let name: String
        public let appName: String
        public let bundleID: String?
        /// Extra launch arguments and environment the file carries. They're
        /// not imported unless asked for: they'd run with the app.
        public let extraArguments: [String]
        public let extraEnvironment: [String: String]
    }

    public static func preview(_ archive: URL) throws -> Preview {
        let (manifest, staging) = try unpack(archive)
        defer { try? FileManager.default.removeItem(at: staging) }
        let settings = manifest.0.effectiveSettings
        return Preview(
            name: manifest.0.name,
            appName: URL(fileURLWithPath: manifest.0.targetApp).deletingPathExtension().lastPathComponent,
            bundleID: manifest.0.knownTargetBundleID,
            extraArguments: settings.extraArguments,
            extraEnvironment: settings.extraEnvironment
        )
    }

    /// Unzip into a fresh temporary folder; returns the manifest, its folder,
    /// and the temporary folder (the caller removes it).
    private static func unpack(_ archive: URL) throws -> ((InstanceManifest, URL), URL) {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("parallex-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let invalid = ParallexError("\(archive.lastPathComponent) isn't a Parallex instance file.")
        do {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        } catch {
            try? fm.removeItem(at: staging)
            throw invalid
        }
        let folders = ((try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("instance.json").path) }
        guard folders.count == 1, let folder = folders.first,
              let data = try? Data(contentsOf: folder.appendingPathComponent("instance.json")),
              let manifest = try? InstanceStore.decoder.decode(InstanceManifest.self, from: data)
        else {
            try? fm.removeItem(at: staging)
            throw invalid
        }
        return ((manifest, folder), staging)
    }

    /// Recreate an instance from a `.parallex` file.
    ///
    /// The file is untrusted: the app comes from this Mac (found by bundle ID,
    /// never a path from the file), and the file's extra arguments and
    /// environment are left out unless `keepExtras` — even then, variables
    /// that load code into the app are dropped.
    @discardableResult
    public static func `import`(
        from archive: URL,
        name requestedName: String? = nil,
        keepExtras: Bool = false,
        outputDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        builderOptions: BundleBuilder.Options = BundleBuilder.Options(),
        locateApp: (String) -> URL? = AppResolver.locate(bundleID:)
    ) throws -> CreateResult {
        let fm = FileManager.default
        let ((imported, folder), staging) = try unpack(archive)
        defer { try? fm.removeItem(at: staging) }
        var manifest = imported
        removeLinks(leaving: folder)

        // A website's app is Parallex Web, which comes with Parallex.
        let webTemplate = manifest.isWeb ? try WebShell.templateApp() : nil
        guard let app = webTemplate ?? manifest.knownTargetBundleID.flatMap({ bundleID in
            OriginalData.isPlainName(bundleID) && !bundleID.hasPrefix("com.parallex.") ? locateApp(bundleID) : nil
        })
        else {
            let appName = URL(fileURLWithPath: manifest.targetApp).deletingPathExtension().lastPathComponent
            throw ParallexError("“\(manifest.name)” is an instance of \(appName), which isn't installed on this Mac.")
        }
        let target = try AppInspector.inspect(app)
        var warnings: [String] = []

        // Claim a name and slug that are free here, and move the data in.
        let lock = try InstanceStore.creationLock()
        let originalInstancePath = inferredInstancePath(of: manifest) ?? Paths.instanceDir(slug: manifest.slug).path
        let validName = try InstanceCreator.resolveName(requestedName ?? manifest.name, targetName: target.name, outDir: outputDirectory)
        let name = try uniqueName(validName, outputDirectory: outputDirectory)
        var slug = Slug.forInstance(named: name)
        let base = slug
        var index = 2
        while fm.fileExists(atPath: Paths.instanceDir(slug: slug).path) {
            slug = "\(base)-\(index)"
            index += 1
        }
        let destination = Paths.instanceDir(slug: slug)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: folder, to: destination)
        } catch {
            lock.release()
            throw error
        }
        let preferences = destination.appendingPathComponent(preferencesFile)

        let newPath = destination.path
        func rebase(_ value: String) -> String {
            value.replacingOccurrences(of: originalInstancePath, with: newPath)
        }
        var settings = manifest.effectiveSettings
        if keepExtras {
            let droppedKeys = settings.extraEnvironment.keys.filter(isCodeLoadingVariable).sorted()
            settings.extraEnvironment = settings.extraEnvironment.filter { !isCodeLoadingVariable($0.key) }.mapValues(rebase)
            settings.extraArguments = settings.extraArguments.map(rebase)
            if !droppedKeys.isEmpty {
                warnings.append("Left out \(droppedKeys.joined(separator: ", ")): they'd load code into the app.")
            }
        } else if !settings.extraArguments.isEmpty || !settings.extraEnvironment.isEmpty {
            warnings.append(
                "The file's extra arguments and environment weren't imported. Add them in the instance's "
                + "Advanced section if you trust where the file came from."
            )
            settings.extraArguments = []
            settings.extraEnvironment = [:]
        }
        // A shortcut could collide with one on this Mac.
        settings.shortcut = nil
        // A throwaway starts over here: only launches on this Mac count.
        Throwaway.normalize(&settings, was: nil)
        settings.openAtLaunch = nil
        manifest.settings = settings
        manifest.schemaVersion = 2
        manifest.name = name
        manifest.slug = slug
        manifest.bundleIdentifier = "com.parallex.instance.\(slug)"
        manifest.targetApp = target.url.path
        manifest.targetBinary = target.executableURL.path
        manifest.targetBundleID = target.bundleID
        manifest.wrapperPath = outputDirectory.appendingPathComponent("\(name).app").path
        manifest.arguments = []
        manifest.environment = ["PARALLEX_INSTANCE": slug]
        manifest.redirectedHome = manifest.redirectedHome.map(rebase)
        if let suffix = manifest.keychainSuffix, !KeychainNames.isValidSuffix(suffix) {
            manifest.keychainSuffix = nil
        }
        manifest.clone?.bundleIdentifier = "com.parallex.instance.\(slug)"
        // Build the copy fresh from this Mac's app.
        manifest.clone?.sourceVersion = ""
        do {
            try InstanceStore.save(manifest)
        } catch {
            try? Trash.move(destination)
            lock.release()
            throw error
        }
        lock.release()

        do {
            let result = try InstanceCreator.update(manifest, InstanceUpdate(targetApp: target.url), builderOptions: builderOptions)
            if let copyID = result.manifest.clone?.bundleIdentifier, fm.fileExists(atPath: preferences.path) {
                Shell.runAllowingFailure("/usr/bin/defaults", ["import", copyID, preferences.path])
            }
            try? fm.removeItem(at: preferences)
            return CreateResult(
                manifest: result.manifest, wrapperURL: result.wrapperURL,
                frameworkDisplayName: result.frameworkDisplayName, dataDirectories: result.dataDirectories,
                homeDirectory: result.homeDirectory, notes: result.notes, warnings: result.warnings + warnings
            )
        } catch {
            // Don't leave a half-imported instance behind.
            try? Trash.move(destination)
            throw ParallexError("Couldn't import “\(name)”: \(error)")
        }
    }

    /// Environment variables that make an app load or run other code.
    static func isCodeLoadingVariable(_ key: String) -> Bool {
        key.hasPrefix("DYLD_") || key.hasPrefix("LD_") || key.hasPrefix("PARALLEX_")
            || ["ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "ELECTRON_ENABLE_LOGGING", "PYTHONSTARTUP", "PERL5OPT"].contains(key)
    }

    /// The instance folder path recorded in the manifest's own settings (the
    /// exporting Mac's), from the pid file or data paths it contains.
    static func inferredInstancePath(of manifest: InstanceManifest) -> String? {
        let marker = "/instances/\(manifest.slug)"
        let candidates = manifest.arguments + Array(manifest.environment.values) + [manifest.redirectedHome].compactMap { $0 }
        for value in candidates {
            // The whole slug, not a prefix of another ("foo" in "foo-2").
            let range = value.range(of: marker + "/") ?? (value.hasSuffix(marker) ? value.range(of: marker, options: .backwards) : nil)
            if let range {
                let end = value.index(range.lowerBound, offsetBy: marker.count)
                let prefix = value[..<end]
                // The path starts at its first "/" ("--user-data-dir=/…").
                guard let start = prefix.firstIndex(of: "/") else { continue }
                return String(prefix[start...])
            }
        }
        return nil
    }

    private static func uniqueName(_ name: String, outputDirectory: URL) throws -> String {
        let names = Set(InstanceStore.loadAll().map { $0.name.lowercased() })
        var candidate = name
        var index = 2
        while names.contains(candidate.lowercased())
            || FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("\(candidate).app").path) {
            candidate = "\(name) \(index)"
            index += 1
        }
        return candidate
    }
}
