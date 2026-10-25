// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Foreedge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Foreedge", targets: ["Foreedge"])],
    dependencies: [],
    targets: [.systemLibrary(name: "CSQLite"), .executableTarget(name: "Foreedge", dependencies: ["CSQLite"])]
)
