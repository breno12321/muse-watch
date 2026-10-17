// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MuseCore", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "MuseCore", targets: ["MuseCore"])], targets: [
    .target(name: "MuseCore", path: "Shared"),
    .testTarget(name: "MuseCoreTests", dependencies: ["MuseCore"], path: "ProtocolTests", resources: [.copy("Fixtures")])
])
