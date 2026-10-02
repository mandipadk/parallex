import XCTest
@testable import ParallexCore

/// Programs a copy starts from outside it (macOS's own tools, a shell)
/// start without the copy's home library, keeping its variables (for the
/// copy's own binary started again through them) and any other inserted
/// library; the copy's own helpers keep everything.
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
        #include <stdlib.h>
        #include <string.h>
        int main(void) {
            // Loaded at all: what matters to a tool that can't load it.
            int loaded = 0, other = 0;
            for (unsigned i = 0; i < _dyld_image_count(); i++) {
                if (strstr(_dyld_get_image_name(i), "libparallexhome.dylib")) loaded = 1;
                if (strstr(_dyld_get_image_name(i), "libother.dylib")) other = 1;
            }
            printf("%s %s %s\\n", loaded ? "loaded" : "not loaded", other ? "other" : "no other",
                   getenv("PARALLEX_HOME_SCOPE") ? "variables" : "no variables");
            return 0;
        }
        """.utf8).write(to: toolSource)
        let outside = tempDir.appendingPathComponent("outside-tool")
        let inside = macOS.appendingPathComponent("inside-tool")
        try Shell.run("/usr/bin/clang", [toolSource.path, "-o", outside.path])
        try fm.copyItem(at: outside, to: inside)

        // Another inserted library (a debugging tool's, say) is left alone.
        let otherSource = tempDir.appendingPathComponent("other.c")
        try Data("int parallex_test_other = 1;\n".utf8).write(to: otherSource)
        let other = tempDir.appendingPathComponent("libother.dylib")
        try Shell.run("/usr/bin/clang", ["-dynamiclib", otherSource.path, "-o", other.path])

        let spawnerSource = tempDir.appendingPathComponent("spawner.c")
        try Data("""
        #include <spawn.h>
        #include <string.h>
        #include <sys/wait.h>
        extern char **environ;
        int main(int argc, char **argv) {
            for (int i = 1; i < argc; i++) {
                pid_t pid;
                char *args[] = {argv[i], NULL};
                // A bare name is found through PATH, as posix_spawnp does.
                int failed = strchr(argv[i], '/') ? posix_spawn(&pid, argv[i], NULL, NULL, args, environ)
                                                  : posix_spawnp(&pid, argv[i], NULL, NULL, args, environ);
                if (failed) return 1;
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
        process.arguments = [outside.path, inside.path, "inside-tool"]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_INSERT_LIBRARIES"] = "\(other.path):\(library.path)"
        environment["PARALLEX_HOME_REDIRECT"] = tempDir.appendingPathComponent("home").path
        environment["PARALLEX_HOME_SCOPE"] = app.path
        environment["PATH"] = "\(macOS.path):/usr/bin:/bin"
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
        XCTAssertEqual(printed.split(separator: "\n").map(String.init), ["not loaded other variables", "loaded other variables", "loaded other variables"])
    }
}
