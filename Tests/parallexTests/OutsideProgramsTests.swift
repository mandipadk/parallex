import XCTest
@testable import ParallexCore

/// Programs a copy starts from outside it (macOS's own tools, a shell)
/// start without the copy's home library and its variables; the copy's own
/// helpers keep them.
final class OutsideProgramsTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try Fixtures.makeTempDirectory("outside-programs")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOnlyTheCopysOwnProgramsGetTheHomeLibrary() throws {
        let fm = FileManager.default
        let app = tempDir.appendingPathComponent("Probe.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempDir.appendingPathComponent("home"), withIntermediateDirectories: true)
        // Named as it ships, which is how the library recognises itself.
        let library = app.appendingPathComponent("Contents/libparallexhome.dylib")
        try fm.copyItem(at: Fixtures.homeLibrary, to: library)

        let toolSource = tempDir.appendingPathComponent("tool.c")
        try Data("""
        #include <mach-o/dyld.h>
        #include <stdio.h>
        #include <string.h>
        int main(void) {
            // Loaded at all: what matters to a tool that can't load it.
            int loaded = 0;
            for (unsigned i = 0; i < _dyld_image_count(); i++) {
                if (strstr(_dyld_get_image_name(i), "libparallexhome.dylib")) loaded = 1;
            }
            printf("%s\\n", loaded ? "loaded" : "not loaded");
            return 0;
        }
        """.utf8).write(to: toolSource)
        let outside = tempDir.appendingPathComponent("outside-tool")
        let inside = macOS.appendingPathComponent("inside-tool")
        try Shell.run("/usr/bin/clang", [toolSource.path, "-o", outside.path])
        try fm.copyItem(at: outside, to: inside)

        let spawnerSource = tempDir.appendingPathComponent("spawner.c")
        try Data("""
        #include <spawn.h>
        #include <sys/wait.h>
        extern char **environ;
        int main(int argc, char **argv) {
            for (int i = 1; i < argc; i++) {
                pid_t pid;
                char *args[] = {argv[i], NULL};
                if (posix_spawn(&pid, argv[i], NULL, NULL, args, environ) != 0) return 1;
                int status;
                waitpid(pid, &status, 0);
            }
            return 0;
        }
        """.utf8).write(to: spawnerSource)
        let spawner = macOS.appendingPathComponent("spawner")
        try Shell.run("/usr/bin/clang", [spawnerSource.path, "-o", spawner.path])

        let process = Process()
        process.executableURL = spawner
        process.arguments = [outside.path, inside.path]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = library.path
        environment["PARALLEX_HOME_REDIRECT"] = tempDir.appendingPathComponent("home").path
        environment["PARALLEX_HOME_SCOPE"] = app.path
        // swift test's own library path would load the library from .build.
        environment["DYLD_LIBRARY_PATH"] = nil
        environment["DYLD_FRAMEWORK_PATH"] = nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let printed = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(printed.split(separator: "\n").map(String.init), ["not loaded", "loaded"])
    }
}
