import XCTest
@testable import ParallexCore
import ParallexKit

/// A workspace's persona: its own identity for your command-line tools, in
/// a home of its own that mirrors yours otherwise, for `parallex run` and
/// for what copies in the workspace start.
final class PersonaTests: XCTestCase {
    var tempDir: URL!
    var outDir: URL!
    let options = BundleBuilder.Options(registerWithLaunchServices: false)
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("persona")
        setenv("PARALLEX_HOME", tempDir.appendingPathComponent("support").path, 1)
        setenv("PARALLEX_LAUNCHER", Fixtures.launcherBinary.path, 1)
        setenv("PARALLEX_HOME_LIBRARY", Fixtures.homeLibrary.path, 1)
        outDir = tempDir.appendingPathComponent("apps", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("PARALLEX_HOME")
        unsetenv("PARALLEX_LAUNCHER")
        unsetenv("PARALLEX_HOME_LIBRARY")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAPersonaHomeIsYoursExceptForWhoYouAre() throws {
        var workspace = try WorkspaceStore.create(name: "Client A")
        workspace = try WorkspaceStore.update(id: workspace.id) { $0.persona = true }
        let home = Personas.prepare(workspace)
        let fm = FileManager.default
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("Library").path), realHome + "/Library")
        if fm.fileExists(atPath: realHome + "/Documents") {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("Documents").path), realHome + "/Documents")
        }
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".aws").path), "its own, not a link to yours")
        // Always its own, so `git config --global` never writes to yours.
        let gitconfig = try String(contentsOf: home.appendingPathComponent(".gitconfig"), encoding: .utf8)
        if fm.fileExists(atPath: realHome + "/.gitconfig") {
            XCTAssertTrue(gitconfig.contains("path = \"\(realHome)/.gitconfig\""), "starts from your settings")
        }
        // Library is a link that stays put through syncs.
        let before = try fm.attributesOfItem(atPath: home.appendingPathComponent("Library").path)[.systemFileNumber] as? Int
        Personas.prepare(workspace)
        let after = try fm.attributesOfItem(atPath: home.appendingPathComponent("Library").path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after)
        let environment = Personas.environment(for: workspace, base: [
            "PATH": "/usr/bin:/bin", "GH_TOKEN": "yours", "AWS_PROFILE": "personal",
            "XDG_CONFIG_HOME": realHome + "/.config", "EDITOR": "vim",
        ])
        XCTAssertEqual(environment["HOME"], home.path)
        XCTAssertEqual(environment["PARALLEX_WORKSPACE"], "Client A")
        XCTAssertNil(environment["GH_TOKEN"], "your identity isn't passed on")
        XCTAssertNil(environment["AWS_PROFILE"])
        XCTAssertEqual(environment["XDG_CONFIG_HOME"], home.path + "/.config")
        XCTAssertEqual(environment["EDITOR"], "vim")

        // git as the workspace: its email, and yours untouched.
        let yours = try? Shell.run("/usr/bin/git", ["config", "--global", "user.email"])
        let set = Process()
        set.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        set.arguments = ["config", "--global", "user.email", "me@client-a.example"]
        set.environment = environment
        try set.run()
        set.waitUntilExit()
        XCTAssertEqual(set.terminationStatus, 0)
        let read = Process()
        let pipe = Pipe()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        read.arguments = ["config", "--global", "user.email"]
        read.environment = environment
        read.standardOutput = pipe
        try read.run()
        read.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), "me@client-a.example")
        XCTAssertEqual(try? Shell.run("/usr/bin/git", ["config", "--global", "user.email"]), yours)
    }

    func testDeletingAWorkspaceTrashesItsPersona() throws {
        setenv("PARALLEX_TRASH", tempDir.appendingPathComponent("trash").path, 1)
        defer { unsetenv("PARALLEX_TRASH") }
        var workspace = try WorkspaceStore.create(name: "Gone")
        workspace = try WorkspaceStore.update(id: workspace.id) { $0.persona = true }
        let home = Personas.prepare(workspace)
        let script = try Personas.terminalScript(for: workspace)
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("export PARALLEX_WORKSPACE='Gone'"))
        XCTAssertTrue(text.contains("unset "), "your identity's variables aren't passed on")
        try WorkspaceStore.delete(id: workspace.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testVersionsCompareByTheirParts() {
        XCTAssertEqual(AppVersions.compare("4.41.106 (41106)", "4.41.105 (41105)"), .orderedDescending)
        XCTAssertEqual(AppVersions.compare("1.10 (5)", "1.9 (4)"), .orderedDescending)
        XCTAssertEqual(AppVersions.compare("2.0 (7)", "2.0 (12)"), .orderedAscending)
        XCTAssertEqual(AppVersions.compare("2.0 (?)", "2.0 (?)"), .orderedSame)
    }

    /// What a copy in a persona workspace starts gets the persona's home.
    func testACopysToolsInAPersonaWorkspaceAreThePersona() throws {
        let app = try Fixtures.makeApp(named: "Termy", bundleID: "com.fake.termy", in: tempDir)
        let source = tempDir.appendingPathComponent("Termy.c")
        try Data("""
        #include <spawn.h>
        #include <stdlib.h>
        #include <sys/wait.h>
        extern char **environ;
        int main(void) {
            char *argv[] = {"/bin/sh", "-c", "echo \\"$HOME|$PARALLEX_WORKSPACE\\" > \\"$FIXTURE_OUT\\"", NULL};
            pid_t pid;
            if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) == 0) waitpid(pid, NULL, 0);
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/Termy")
        try? FileManager.default.removeItem(at: executable)
        try Shell.run("/usr/bin/clang", [source.path, "-o", executable.path])
        var request = CreateRequest(appReference: app.path, name: "Termy Work", mode: .launchOnly, outputDirectory: outDir)
        request.cloneApp = true
        let copy = try InstanceCreator.create(request, builderOptions: options)

        func childHome() throws -> String {
            let out = tempDir.appendingPathComponent("out-\(UUID().uuidString)")
            let process = Process()
            process.executableURL = copy.wrapperURL.appendingPathComponent("Contents/MacOS/parallex-launcher")
            var environment = ProcessInfo.processInfo.environment
            environment["FIXTURE_OUT"] = out.path
            environment.removeValue(forKey: "PARALLEX_WORKSPACE")
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) { usleep(50_000) }
            return try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        XCTAssertEqual(try childHome(), "\(realHome)|", "not in a persona workspace: yours")
        var workspace = try WorkspaceStore.create(name: "Client B", members: [copy.manifest.slug])
        XCTAssertEqual(try childHome(), "\(realHome)|", "a workspace without a persona: yours")
        workspace = try WorkspaceStore.update(id: workspace.id) { $0.persona = true }
        XCTAssertEqual(try childHome(), "\(Personas.home(for: workspace).path)|Client B")
        try WorkspaceStore.update(id: workspace.id) { $0.members = [] }
        XCTAssertEqual(try childHome(), "\(realHome)|", "left the workspace: yours again")
    }
}
