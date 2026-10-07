// swift-tools-version: 6.0
// HomeClerkKit — HomeClerk's filing logic in Swift: the taxonomy and folder rules, file names, the
// household profile, duplicate detection, and the prompt and response schema the AI models use.
// It has no UI and no I/O beyond reading its config files and the duplicate index, so it can be
// tested on its own with `swift test`. `swift run homeclerk-dev eval` measures accuracy.

import PackageDescription

let package = Package(
    name: "HomeClerkKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HomeClerkKit", targets: ["HomeClerkKit"]),
        .executable(name: "homeclerk-dev", targets: ["homeclerk-dev"])
    ],
    targets: [
        .target(name: "HomeClerkKit"),
        // Developer commands (eval) while HomeClerk moves to Swift
        .executableTarget(name: "homeclerk-dev", dependencies: ["HomeClerkKit"]),
        .testTarget(
            name: "HomeClerkKitTests",
            dependencies: ["HomeClerkKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
