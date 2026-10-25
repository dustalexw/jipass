// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Jipass", platforms: [.macOS(.v13)], products: [.executable(name: "jipass", targets: ["Jipass"])], targets: [.systemLibrary(name: "CSQLite"), .executableTarget(name: "Jipass", dependencies: ["CSQLite"]), .testTarget(name: "JipassTests", dependencies: ["Jipass"])])
