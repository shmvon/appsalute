// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppSalute",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AppSalute", targets: ["AppSalute"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AppSalute",
            dependencies: [],
            path: "Sources/AppSalute"
        )
    ]
)
