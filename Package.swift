// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vatio",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Vatio", targets: ["Vatio"])
    ],
    targets: [
        .target(name: "Vatio", path: "Sources/Vatio")
    ]
)
