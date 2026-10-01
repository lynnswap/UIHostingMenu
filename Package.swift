// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "UIHostingMenu",
    platforms: [.iOS("18.4")],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "UIHostingMenu",
            targets: ["UIHostingMenu"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/lynnswap/ABIBridge", revision: "d1b89cce15a6f243ccd1bedbd0cbb7f6d0bbecd3"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "UIHostingMenu",
            dependencies: [.product(name: "ABIBridge", package: "ABIBridge")],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "UIHostingMenuTests",
            dependencies: [
                "UIHostingMenu",
            ],
            swiftSettings: strictSwiftSettings
        ),
    ]
)
let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]
