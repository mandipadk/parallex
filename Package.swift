// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parallex",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "parallex", targets: ["parallex"]),
        .executable(name: "parallex-launcher", targets: ["parallex-launcher"]),
        .executable(name: "parallex-router", targets: ["parallex-router"]),
        // Binary is named ParallexApp to avoid a case-insensitive collision
        // with the `parallex` CLI in the build directory; the Makefile renames
        // it to `Parallex` when assembling Parallex.app.
        .executable(name: "ParallexApp", targets: ["ParallexApp"]),
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

        // "Parallex Links": receives sign-in links and passes each to the
        // right running copy of an app (see LinkRouting).
        .executableTarget(
            name: "parallex-router",
            dependencies: ["ParallexCore"]
        ),

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
