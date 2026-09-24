// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parallex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "parallex", targets: ["parallex"]),
        .executable(name: "parallex-launcher", targets: ["parallex-launcher"]),
        .executable(name: "parallex-router", targets: ["parallex-router"]),
        // Binary is named ParallexApp to avoid a case-insensitive collision
        // with the `parallex` CLI in the build directory; the Makefile renames
        // it to `Parallex` when assembling Parallex.app.
        .executable(name: "ParallexApp", targets: ["ParallexApp"]),
        // Loaded into own-identity copies so they keep their own ~/Library.
        .library(name: "parallexhome", type: .dynamic, targets: ["ParallexHome"]),
        // Loaded into own-identity copies of sandboxed apps so they use their
        // own app-group containers.
        .library(name: "parallexgroups", type: .dynamic, targets: ["ParallexGroups"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Constants shared between the CLI (which writes wrapper Info.plists)
        // and the launcher (which reads them). Keeps the two from drifting.
        .target(name: "ParallexKit"),

        // Everything that knows how to inspect apps and build/manage wrapper
        // bundles. Shared by the CLI and the GUI app.
        .target(
            name: "ParallexCore",
            dependencies: ["ParallexKit"]
        ),

        // The generic launcher embedded in every wrapper .app. Deliberately
        // tiny and dependency-free: reads its config from its own bundle's
        // Info.plist and execs the target binary.
        .executableTarget(
            name: "parallex-launcher",
            dependencies: ["ParallexKit"],
            path: "launcher"
        ),

        // The home-redirect library (C, no dependencies): answers account
        // lookups with the instance's home inside an instance's own copy.
        .target(
            name: "ParallexHome",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]
        ),

        // The app-group mapping library (Objective-C): translates a sandboxed
        // copy's requests for its original app groups to its own.
        .target(
            name: "ParallexGroups",
            linkerSettings: [.linkedFramework("Foundation")]
        ),

        // "Parallex Links": receives sign-in links and passes each to the
        // right running copy of an app (see LinkRouting).
        .executableTarget(
            name: "parallex-router",
            dependencies: ["ParallexCore"]
        ),

        // "Parallex Web": the small browser a web instance is a copy of
        // (see WebShell). Dependency-free: it's copied into every web
        // instance and only reads its launch environment.
        .executableTarget(name: "parallex-web"),

        // The CLI over ParallexCore.
        .executableTarget(
            name: "parallex",
            dependencies: [
                "ParallexCore",
                "ParallexKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // The SwiftUI app over ParallexCore (manager window + menu bar).
        .executableTarget(
            name: "ParallexApp",
            dependencies: ["ParallexCore", "ParallexKit"],
            exclude: ["Resources"]
        ),

        .testTarget(
            name: "parallexTests",
            dependencies: ["ParallexCore", "ParallexKit"]
        ),
    ]
)
