// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "LocalSpeech", platforms: [.macOS(.v14), .iOS(.v17)], products: [
    .library(name: "LocalSpeech", targets: ["LocalSpeech"])
], dependencies: [.package(path: "../.local/speech/Misaki")], targets: [
    .target(name: "LocalSpeech", dependencies: [.product(name: "Misaki", package: "Misaki")]),
    .testTarget(name: "LocalSpeechTests", dependencies: ["LocalSpeech"])
], swiftLanguageModes: [.v5])
