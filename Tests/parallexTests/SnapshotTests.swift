import XCTest
@testable import ParallexCore
import ParallexKit

/// Snapshots keep an instance's data as it was, and put it back.
final class SnapshotTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("snapshots")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_TRASH", tempDir.appendingPathComponent("trash").path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_TRASH")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A wrapper instance (no copy, so no preferences of its own to keep)
    /// with some data.
    private func makeInstance() throws -> (InstanceManifest, URL) {
        let app = try Fixtures.makeApp(named: "Kept", bundleID: "com.fake.kept", in: tempDir)
        let request = CreateRequest(appReference: app.path, name: "Kept Work", outputDirectory: outDir)
        let manifest = try InstanceCreator.create(request, builderOptions: options).manifest
        let instance = Paths.instanceDir(slug: manifest.slug)
        let data = instance.appendingPathComponent("data/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("signed in as work".utf8).write(to: data.appendingPathComponent("Cookies"))
        try Data("settings".utf8).write(to: data.appendingPathComponent("Preferences"))
        try Data("1\t2\tKept\tread\t/x\n".utf8).write(to: instance.appendingPathComponent("access.log"))
        return (manifest, instance)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testARestorePutsTheDataBackAndKeepsWhatWasThere() throws {
        let (manifest, instance) = try makeInstance()
        let data = instance.appendingPathComponent("data/Default")
        let taken = try Snapshots.take(manifest, label: "signed in", now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(Snapshots.list(manifest).map(\.id), [taken.id])
        XCTAssertEqual(taken.label, "signed in")
        let kept = Snapshots.folder(slug: manifest.slug).appendingPathComponent(taken.id).appendingPathComponent("data")
        XCTAssertEqual(read(kept.appendingPathComponent("data/Default/Cookies")), "signed in as work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent("instance.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent("access.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.appendingPathComponent(Snapshots.folderName).path))

        // Signed out, a file gone, a new one.
        try Data("signed out".utf8).write(to: data.appendingPathComponent("Cookies"))
        try FileManager.default.removeItem(at: data.appendingPathComponent("Preferences"))
        try Data("new".utf8).write(to: data.appendingPathComponent("Later"))

        let before = try Snapshots.restore(taken, of: manifest, now: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertEqual(read(data.appendingPathComponent("Cookies")), "signed in as work")
        XCTAssertEqual(read(data.appendingPathComponent("Preferences")), "settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("Later").path))
        // Its record and settings are left alone.
        XCTAssertNotNil(read(instance.appendingPathComponent("access.log")))
        XCTAssertNotNil(InstanceStore.load(slug: manifest.slug))

        // And the restore can be undone.
        XCTAssertEqual(before.reason, .beforeRestore)
        XCTAssertEqual(Snapshots.list(manifest).map(\.id), [before.id, taken.id])
        try Snapshots.restore(before, of: manifest, now: Date(timeIntervalSince1970: 1_800_000_200))
        XCTAssertEqual(read(data.appendingPathComponent("Cookies")), "signed out")
        XCTAssertEqual(read(data.appendingPathComponent("Later")), "new")
    }

    func testOnlyAFewTakenForYouAreKept() throws {
        let (manifest, _) = try makeInstance()
        let mine = try Snapshots.take(manifest, label: "mine", now: Date(timeIntervalSince1970: 1_700_000_000))
        for index in 0..<(Snapshots.keptAutomatic + 2) {
            try Snapshots.take(manifest, reason: .beforeRestore, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60))
        }
        let snapshots = Snapshots.list(manifest)
        XCTAssertEqual(snapshots.filter { $0.reason == .beforeRestore }.count, Snapshots.keptAutomatic)
        XCTAssertTrue(snapshots.contains(mine), "yours stay")
        XCTAssertEqual(snapshots.first?.date, Date(timeIntervalSince1970: 1_800_000_000 + Double(Snapshots.keptAutomatic + 1) * 60))
    }

    func testRenameDeleteAndDuplicatesLeaveThemOut() throws {
        let (manifest, _) = try makeInstance()
        let taken = try Snapshots.take(manifest)
        let again = try Snapshots.take(manifest, now: taken.date)
        XCTAssertNotEqual(again.id, taken.id, "two in the same second get their own names")
        try Snapshots.rename(taken, of: manifest, to: "before the trip")
        XCTAssertEqual(Snapshots.find(taken.id, in: manifest)?.label, "before the trip")

        let twin = try InstanceCreator.duplicate(manifest, includeData: true, builderOptions: options)
        XCTAssertTrue(Snapshots.list(twin.manifest).isEmpty)

        try Snapshots.delete(again, of: manifest)
        XCTAssertEqual(Snapshots.list(manifest).map(\.id), [taken.id])
        let trashed = try FileManager.default.contentsOfDirectory(atPath: tempDir.appendingPathComponent("trash").path)
        XCTAssertFalse(trashed.isEmpty, "deleted to the Trash")
    }

    func testStorageCountsSnapshotsApart() throws {
        let (manifest, _) = try makeInstance()
        let before = InstanceStorage.report(for: manifest)
        try Snapshots.take(manifest)
        let after = InstanceStorage.report(for: manifest)
        XCTAssertEqual(after.totalBytes, before.totalBytes)
        XCTAssertGreaterThan(after.snapshotBytes, 0)
    }
}
