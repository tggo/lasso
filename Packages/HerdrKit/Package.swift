// swift-tools-version: 6.0
import PackageDescription

// HerdrKit — herdr socket API (NDJSON) models and codec. Pure Swift, no dependencies,
// tested on macOS with `swift test` (no simulator).
let package = Package(
    name: "HerdrKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "HerdrKit", targets: ["HerdrKit"])],
    targets: [
        .target(name: "HerdrKit"),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"]),
    ]
)
