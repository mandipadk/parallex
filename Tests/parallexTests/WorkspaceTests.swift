import XCTest
@testable import ParallexCore

final class WorkspaceTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    var targetApp: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("workspaces")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        targetApp = try Fixtures.makeApp(named: "Target", bundleID: "com.fake.ws", in: tempDir, electron: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func instance(_ name: String) throws -> InstanceManifest {
        try InstanceCreator.create(CreateRequest(appReference: targetApp.path, name: name, outputDirectory: outDir),
                                   builderOptions: options).manifest
    }

    func testCreateFindAndUniqueNames() throws {
        let work = try instance("Work One")
        let created = try WorkspaceStore.create(name: "  Work  ", members: [work.slug, work.slug])
        XCTAssertEqual(created.name, "Work")
        XCTAssertEqual(created.members, [work.slug], "members are unique")
        XCTAssertEqual(WorkspaceStore.find("work")?.id, created.id)
        XCTAssertEqual(WorkspaceStore.find(created.id.uuidString)?.id, created.id)
        XCTAssertThrowsError(try WorkspaceStore.create(name: "WORK"))
        XCTAssertThrowsError(try WorkspaceStore.create(name: "   "))
    }

    func testUpdateRenameAndConflicts() throws {
        let work = try WorkspaceStore.create(name: "Work")
        _ = try WorkspaceStore.create(name: "Personal")
        XCTAssertThrowsError(try WorkspaceStore.update(id: work.id) { $0.name = "personal" }, "names stay unique")
        try WorkspaceStore.update(id: work.id) { $0.name = "Day\nJob " }
        XCTAssertEqual(WorkspaceStore.load().map(\.name).sorted(), ["Day Job", "Personal"])
        try WorkspaceStore.delete(id: work.id)
        XCTAssertEqual(WorkspaceStore.load().map(\.name), ["Personal"])
        XCTAssertThrowsError(try WorkspaceStore.update(id: work.id) { _ in }, "a deleted workspace can't be updated")
    }

    func testEditsFromTwoPlacesDontUndoEachOther() throws {
        let one = try instance("Alpha")
        let two = try instance("Beta")
        let stale = try WorkspaceStore.create(name: "Mix", members: [one.slug])
        // The CLI adds an instance…
        try WorkspaceStore.update(id: stale.id) { $0.members.append(two.slug) }
        // …while the app, holding its older copy, flips a setting.
        try WorkspaceStore.update(id: stale.id) { $0.hidesOthers = true }
        let now = try XCTUnwrap(WorkspaceStore.find("Mix"))
        XCTAssertEqual(now.members, [one.slug, two.slug])
        XCTAssertTrue(now.hidesOthers)
    }

    func testRemovingAnInstanceTakesItOutOfWorkspaces() throws {
        let one = try instance("One")
        let two = try instance("Two")
        _ = try WorkspaceStore.create(name: "Both", members: [one.slug, two.slug])
        _ = try InstanceRemover.remove(one, keepData: false)
        XCTAssertEqual(WorkspaceStore.find("Both")?.members, [two.slug])
        XCTAssertEqual(WorkspaceStore.find("Both")?.instances(in: InstanceStore.loadAll()).map(\.name), ["Two"])
    }

    func testShortcutsBelongToOneThing() throws {
        let one = try instance("Solo")
        var settings = one.effectiveSettings
        settings.shortcut = KeyShortcut(parsing: "ctrl+opt+1")
        _ = try InstanceCreator.saveSettings(settings, for: one)
        let workspace = try WorkspaceStore.update(id: WorkspaceStore.create(name: "Focus").id) {
            $0.shortcut = KeyShortcut(parsing: "ctrl+opt+f")
        }

        XCTAssertEqual(ShortcutOwners.owner(of: KeyShortcut(parsing: "⌃⌥1")!), "“Solo”")
        XCTAssertEqual(ShortcutOwners.owner(of: KeyShortcut(parsing: "⌃⌥F")!), "the “Focus” workspace")
        XCTAssertNil(ShortcutOwners.owner(of: KeyShortcut(parsing: "⌃⌥F")!, except: workspace.id.uuidString))
        XCTAssertNil(ShortcutOwners.owner(of: KeyShortcut(parsing: "⌃⌥9")!))
    }

    func testCorruptFileDoesNotCrash() throws {
        try FileManager.default.createDirectory(at: WorkspaceStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: WorkspaceStore.fileURL)
        XCTAssertTrue(WorkspaceStore.load().isEmpty)
        XCTAssertNoThrow(try WorkspaceStore.create(name: "Fresh"))
        let kept = try FileManager.default.contentsOfDirectory(atPath: WorkspaceStore.fileURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("workspaces.unreadable-") }
        XCTAssertEqual(kept.count, 1, "the unreadable file is kept aside")
    }
}
