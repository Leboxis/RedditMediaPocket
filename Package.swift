// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MediaCore", platforms: [.macOS(.v13), .iOS(.v16)], products: [.library(name: "MediaCore", targets: ["MediaCore"])], targets: [.target(name: "MediaCore"), .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"])])
