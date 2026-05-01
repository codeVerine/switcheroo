// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "switcheroo",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SwitcherooCore", targets: ["SwitcherooCore"]),
        .executable(name: "switcheroo", targets: ["switcheroo"]),
        .executable(name: "SwitcherooMenuBar", targets: ["SwitcherooMenuBar"]),
    ],
    targets: [
        .target(
            name: "SwitcherooCore"
        ),
        .executableTarget(
            name: "switcheroo",
            dependencies: ["SwitcherooCore"]
        ),
        .executableTarget(
            name: "SwitcherooMenuBar",
            dependencies: ["SwitcherooCore"]
        ),
    ]
)
