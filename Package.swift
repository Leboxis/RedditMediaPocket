// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MediaCore", platforms: [.macOS(.v26), .iOS(.v26)], products: [.library(name: "MediaCore", targets: ["MediaCore"])], targets: [.target(name: "MediaCore"), .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"])], swiftLanguageModes: [.v5])
