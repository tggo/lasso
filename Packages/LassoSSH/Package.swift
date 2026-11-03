// swift-tools-version: 6.0
import PackageDescription

// LassoSSH — libssh2 over OpenSSL, both built from pinned source by `make native`
// into Artifacts/ (gitignored). Run `make native` before building this package.
let package = Package(
    name: "LassoSSH",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LassoSSH", targets: ["LassoSSH"])],
    targets: [
        .binaryTarget(name: "COpenSSL", path: "Artifacts/COpenSSL.xcframework"),
        .binaryTarget(name: "CLibSSH2", path: "Artifacts/CLibSSH2.xcframework"),
        .target(name: "LassoSSH", dependencies: ["CLibSSH2", "COpenSSL"]),
        .testTarget(name: "LassoSSHTests", dependencies: ["LassoSSH"]),
    ]
)
