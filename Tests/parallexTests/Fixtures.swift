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

    static func makeTempDirectory(_ testName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallex-tests-\(testName)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
