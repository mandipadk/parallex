import Foundation
import XCTest

/// Helpers for building fake .app bundles and locating built products.
enum Fixtures {
    /// The build products directory (where parallex-launcher lives during tests).
    static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not locate the build products directory")
    }

    static var launcherBinary: URL {
        productsDirectory.appendingPathComponent("parallex-launcher")
    }

    /// Create a minimal fake .app bundle for inspector/preset tests.
    @discardableResult
    static func makeApp(
        named name: String,
        bundleID: String,
        in directory: URL,
        electron: Bool = false,
        productJSON: Bool = false,
        applicationIni: Bool = false,
        machOExecutable: Bool = false,
        extraInfoKeys: [String: Any] = [:]
    ) throws -> URL {
        let fm = FileManager.default
        let app = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        ]
        info.merge(extraInfoKeys) { _, new in new }
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = macOS.appendingPathComponent(name)
        if machOExecutable {
            // A real, signable Mach-O (needed when the bundle gets codesigned).
            try fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: executable)
        } else {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        if electron {
            try fm.createDirectory(
                at: contents.appendingPathComponent("Frameworks/Electron Framework.framework"),
                withIntermediateDirectories: true
            )
        }
        if productJSON {
            let appDir = resources.appendingPathComponent("app", isDirectory: true)
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            try Data(#"{"nameShort": "Fake"}"#.utf8).write(to: appDir.appendingPathComponent("product.json"))
        }
        if applicationIni {
            try Data("[App]\nName=Fake\n".utf8).write(to: resources.appendingPathComponent("application.ini"))
        }
        return app
    }

    /// The repository root (for sources the tests compile themselves).
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The home-redirect library, compiled once per test run from its
    /// source (the test build doesn't produce the dynamic library product).
    static let homeLibrary: URL = {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallex-tests-libparallexhome-\(ProcessInfo.processInfo.processIdentifier).dylib")
        let source = repositoryRoot.appendingPathComponent("Sources/ParallexHome")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = [
            "-dynamiclib", "-O2", "-I", source.appendingPathComponent("include").path,
            source.appendingPathComponent("home.c").path, "-o", output.path,
            "-framework", "Security", "-framework", "CoreFoundation",
        ]
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "couldn't compile the home-redirect library")
        return output
    }()

    /// The app-group mapping library, compiled once per test run.
    static let groupsLibrary: URL = {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallex-tests-libparallexgroups-\(ProcessInfo.processInfo.processIdentifier).dylib")
        let source = repositoryRoot.appendingPathComponent("Sources/ParallexGroups")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = [
            "-dynamiclib", "-fobjc-arc", "-framework", "Foundation", "-I", source.appendingPathComponent("include").path,
            source.appendingPathComponent("groups.m").path, "-o", output.path,
        ]
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "couldn't compile the app-group mapping library")
        return output
    }()

    /// Compile a small native app whose executable writes what it sees as
    /// home (NSHomeDirectory, Application Support, $HOME) to $FIXTURE_OUT.
    static func makeHomeReportingApp(named name: String, bundleID: String, in directory: URL) throws -> URL {
        let app = try makeApp(named: name, bundleID: bundleID, in: directory, extraInfoKeys: ["CFBundleShortVersionString": "1.0"])
        let source = directory.appendingPathComponent("\(name)-main.m")
        try Data("""
        #import <Foundation/Foundation.h>
        int main(void) {
            @autoreleasepool {
                NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
                NSString *report = [NSString stringWithFormat:@"%@\\n%@\\n%s\\n", NSHomeDirectory(), support, getenv("HOME") ?: ""];
                [report writeToFile:[NSString stringWithUTF8String:getenv("FIXTURE_OUT")] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [[NSFileManager defaultManager] createDirectoryAtPath:[support stringByAppendingPathComponent:@"\(name)"] withIntermediateDirectories:YES attributes:nil error:nil];
            }
            return 0;
        }
        """.utf8).write(to: source)
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        try? FileManager.default.removeItem(at: executable)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-fobjc-arc", "-framework", "Foundation", source.path, "-o", executable.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "fixture", code: 1) }
        return app
    }

    /// What tests remove goes here, never to the user's Trash.
    static let isolatedTrash: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallex-tests-trash-\(ProcessInfo.processInfo.processIdentifier)")
        setenv("PARALLEX_TRASH", url.path, 1)
        atexit {
            if let path = getenv("PARALLEX_TRASH") {
                try? FileManager.default.removeItem(atPath: String(cString: path))
            }
        }
        return url
    }()

    static func makeTempDirectory(_ testName: String) throws -> URL {
        _ = isolatedTrash
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallex-tests-\(testName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
