// swift-tools-version: 6.0
import PackageDescription

// LassoCore — hosts, keys, SSH-backed herdr transport and the live session store.
// UI-free; tested on macOS (`make test-core`, `make test-integration`).
let package = Package(
    name: "LassoCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LassoCore", targets: ["LassoCore"])],
    dependencies: [.package(path: "../HerdrKit"), .package(path: "../LassoSSH")],
    targets: [
        .target(name: "LassoCore", dependencies: ["HerdrKit", "LassoSSH"]),
        .testTarget(name: "LassoCoreTests", dependencies: ["LassoCore"]),
    ]
)
