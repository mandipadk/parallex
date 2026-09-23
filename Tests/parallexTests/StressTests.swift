import XCTest
@testable import ParallexCore
import ParallexKit

/// Heavier scenarios than the unit tests: many instances, awkward names,
/// concurrent operations, and a target app that moves or disappears.
final class StressTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    var targetApp: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("stress")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        targetApp = try Fixtures.makeApp(named: "Stress Target", bundleID: "com.fake.stress", in: tempDir, electron: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func request(_ name: String?) -> CreateRequest {
        CreateRequest(appReference: targetApp.path, name: name, outputDirectory: outDir)
    }

    /// The registry and the wrappers on disk agree, and every slug is unique.
    private func assertConsistent(file: StaticString = #filePath, line: UInt = #line) {
        let manifests = InstanceStore.loadAll()
        XCTAssertEqual(Set(manifests.map(\.slug)).count, manifests.count, "duplicate slugs", file: file, line: line)
        XCTAssertEqual(Set(manifests.map(\.wrapperPath)).count, manifests.count, "shared wrapper", file: file, line: line)
        for manifest in manifests {
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.wrapperPath),
                          "missing wrapper for \(manifest.name)", file: file, line: line)
            XCTAssertTrue(InstanceStatus.check(manifest).problems.isEmpty,
                          "\(manifest.name): \(InstanceStatus.check(manifest).problems)", file: file, line: line)
        }
        let wrappers = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path))?.filter { $0.hasSuffix(".app") } ?? []
        XCTAssertEqual(wrappers.count, manifests.count, "orphaned wrappers: \(wrappers)", file: file, line: line)
    }

    func testAwkwardNamesSurviveTheWholeLifecycle() throws {
        let names = [
            "Claude — Work", "Straße Café", "日本語のアプリ", "Emoji 🚀 Build", "  padded  ",
            "Slash/Back\\slash", "Quotes \"and\" 'apostrophes'", "Dots... and: colons",
            "A very long instance name that keeps going well past what any sidebar would show comfortably",
            "$HOME and `ticks`", "percent %20 encoded", "tab\tand\nnewline",
        ]
        var created: [InstanceManifest] = []
        for name in names {
            do {
                created.append(try InstanceCreator.create(request(name), builderOptions: options).manifest)
            } catch {
                // A name may be refused, but only with a clear error — never a crash or a half-built instance.
                XCTAssertFalse("\(error)".isEmpty)
            }
        }
        // Only names with '/' or ':' (not allowed in file names) are refused.
        XCTAssertEqual(created.count, names.count - 2, "every other name is accepted")
        XCTAssertTrue(created.contains { $0.name == "tab and newline" }, "whitespace is normalized")
        XCTAssertTrue(created.contains { $0.name == "日本語のアプリ" && !$0.slug.isEmpty })
        assertConsistent()

        // Rename each, then remove each.
        for (index, manifest) in created.enumerated() {
            let fresh = try XCTUnwrap(InstanceStore.load(slug: manifest.slug))
            _ = try InstanceCreator.update(fresh, InstanceUpdate(name: "Renamed \(index) ✓"))
        }
        assertConsistent()
        for manifest in InstanceStore.loadAll() {
            _ = try InstanceRemover.remove(manifest, keepData: false)
        }
        XCTAssertTrue(InstanceStore.loadAll().isEmpty)
        assertConsistent()
    }

    func testChurnKeepsRegistryConsistent() throws {
        var rng = SystemRandomNumberGenerator()
        for round in 0..<40 {
            let manifests = InstanceStore.loadAll()
            switch Int.random(in: 0..<4, using: &rng) {
            case 0, 1:
                _ = try InstanceCreator.create(request(nil), builderOptions: options)
            case 2 where !manifests.isEmpty:
                let victim = manifests.randomElement(using: &rng)!
                var settings = victim.effectiveSettings
                settings.badgeText = String(round % 10)
                settings.shortcut = KeyShortcut(parsing: "ctrl+opt+\(round % 10)")
                _ = try InstanceCreator.update(victim, InstanceUpdate(name: "Churn \(round)", settings: settings))
            case 3 where !manifests.isEmpty:
                _ = try InstanceRemover.remove(manifests.randomElement(using: &rng)!, keepData: Bool.random(using: &rng))
            default:
                _ = try InstanceCreator.create(request("Churn new \(round)"), builderOptions: options)
            }
        }
        assertConsistent()
    }

    func testConcurrentCreatesNeverShareASlug() throws {
        // Core hops to the main thread for AppKit work, so wait with an
        // expectation (which keeps the main run loop turning), not a blocking wait.
        let lock = NSLock()
        var results: [Result<InstanceManifest, Error>] = []
        let requests = (0..<8).map { _ in request(nil) }
        let done = expectation(description: "all creates finish")
        done.expectedFulfillmentCount = requests.count
        for request in requests {
            DispatchQueue.global().async {
                let result = Result { try InstanceCreator.create(request, builderOptions: self.options).manifest }
                lock.lock()
                results.append(result)
                lock.unlock()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 120)
        let made = results.compactMap { try? $0.get() }
        XCTAssertEqual(made.count, requests.count, "every create succeeds: \(results)")
        XCTAssertEqual(Set(made.map(\.slug)).count, made.count)
        assertConsistent()
    }

    func testNamesThatShareASlugGetTheirOwn() throws {
        let first = try InstanceCreator.create(request("Claude Work"), builderOptions: options).manifest
        let second = try InstanceCreator.create(request("Claude—Work"), builderOptions: options).manifest
        XCTAssertEqual(first.slug, "claude-work")
        XCTAssertEqual(second.slug, "claude-work-2")
        XCTAssertThrowsError(try InstanceCreator.create(request("claude work"), builderOptions: options),
                             "the same name (ignoring case) is still a duplicate")
        // Looking up by name finds each one, not the other.
        XCTAssertEqual(InstanceStore.find("Claude—Work")?.slug, "claude-work-2")
        XCTAssertEqual(InstanceStore.find("Claude Work")?.slug, "claude-work")
        XCTAssertEqual(InstanceStore.find("claude-work-2")?.name, "Claude—Work")
        assertConsistent()
    }

    func testAnotherLibraryCannotRebuildThisLibrarysApp() throws {
        let manifest = try InstanceCreator.create(request("Mine"), builderOptions: options).manifest
        let before = try Data(contentsOf: URL(fileURLWithPath: manifest.wrapperPath).appendingPathComponent("Contents/Info.plist"))
        // A second library holding a copy of the record (a test or QA
        // library copied from the real one).
        let other = tempDir.appendingPathComponent("other-library")
        setenv("PARALLEX_HOME", other.path, 1)
        defer { setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1) }
        try InstanceStore.save(manifest)
        XCTAssertThrowsError(try InstanceCreator.update(manifest, InstanceUpdate()))
        let after = try Data(contentsOf: URL(fileURLWithPath: manifest.wrapperPath).appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(before, after, "the other library's app is untouched")
    }

    func testCorruptManifestDoesNotHideOtherInstances() throws {
        _ = try InstanceCreator.create(request("Healthy"), builderOptions: options)
        let broken = Paths.instanceDir(slug: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("instance.json"))
        let empty = Paths.instanceDir(slug: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("instance.json"))

        let names = InstanceStore.loadAll().map(\.name)
        XCTAssertEqual(names, ["Healthy"])
        // And creating another still works around the debris.
        XCTAssertNoThrow(try InstanceCreator.create(request("Second"), builderOptions: options))
    }

    func testTargetMovedAndDeletedMidLife() throws {
        let manifest = try InstanceCreator.create(request("Mover"), builderOptions: options).manifest
        let moved = tempDir.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let newLocation = moved.appendingPathComponent(targetApp.lastPathComponent)
        try FileManager.default.moveItem(at: targetApp, to: newLocation)

        // Moved: repair against the new location records it.
        let status = InstanceStatus.check(manifest)
        XCTAssertTrue(status.problems.contains { if case .targetMissing = $0 { return true }
            if case .targetMoved = $0 { return true }
            return false })
        let repaired = try InstanceCreator.update(manifest, InstanceUpdate(targetApp: newLocation)).manifest
        XCTAssertEqual(URL(fileURLWithPath: repaired.targetApp).standardizedFileURL.path,
                       newLocation.standardizedFileURL.path)
        XCTAssertTrue(InstanceStatus.check(repaired).problems.isEmpty)

        // Deleted: blocking, can't launch, and a plain repair explains why.
        try FileManager.default.removeItem(at: newLocation)
        let gone = InstanceStatus.check(repaired)
        XCTAssertTrue(gone.problems.contains(.targetMissing))
        XCTAssertFalse(gone.canLaunch)
        XCTAssertThrowsError(try InstanceCreator.update(repaired, InstanceUpdate()))
    }

    func testDeletedWrapperIsRepairedWithDataKept() throws {
        let manifest = try InstanceCreator.create(request("Phoenix"), builderOptions: options).manifest
        let data = Paths.instanceDir(slug: manifest.slug).appendingPathComponent("data/keep.txt")
        try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: data)
        try FileManager.default.removeItem(atPath: manifest.wrapperPath)

        XCTAssertTrue(InstanceStatus.check(manifest).problems.contains(.wrapperMissing))
        let repaired = try InstanceCreator.update(manifest, InstanceUpdate()).manifest
        XCTAssertTrue(FileManager.default.fileExists(atPath: repaired.wrapperPath))
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "precious")
    }

    func testMetadataSavesUnderLoadStayConsistent() throws {
        let manifest = try InstanceCreator.create(request("Busy"), builderOptions: options).manifest
        // Many quick bookkeeping saves (what toggling in the UI does).
        for index in 0..<200 {
            let current = try XCTUnwrap(InstanceStore.load(slug: manifest.slug))
            var settings = current.effectiveSettings
            settings.openAtLaunch = index.isMultiple(of: 2) ? true : nil
            settings.shortcut = KeyShortcut(parsing: "cmd+opt+\(index % 10)")
            _ = try InstanceCreator.saveSettings(settings, for: current)
        }
        let final = try XCTUnwrap(InstanceStore.load(slug: manifest.slug))
        XCTAssertEqual(final.settings?.shortcut?.displayString, "⌥⌘9")
        XCTAssertNil(final.settings?.openAtLaunch)
        assertConsistent()
    }
}
