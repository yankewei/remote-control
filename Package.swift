// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RemoteControlCore", platforms: [.macOS(.v14)], products: [.library(name: "RemoteControlCore", targets: ["RemoteControlCore"])], targets: [.target(name: "RemoteControlCore", path: "Shared"), .testTarget(name: "RemoteControlCoreTests", dependencies: ["RemoteControlCore"], path: "Tests")])
