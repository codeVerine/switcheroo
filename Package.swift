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
        .library(name: "SwitcherooPresentation", targets: ["SwitcherooPresentation"]),
        .library(name: "SwitcherooDefaultApp", targets: ["SwitcherooDefaultApp"]),
        .executable(name: "switcheroo", targets: ["switcheroo"]),
        .executable(name: "SwitcherooMenuBar", targets: ["SwitcherooMenuBar"]),
    ],
    targets: [
        .target(
            name: "SwitcherooCore"
        ),
        .target(
            name: "SwitcherooPresentation",
            dependencies: ["SwitcherooCore"]
        ),
        .target(
            name: "SwitcherooDefaultApp",
            dependencies: ["SwitcherooPresentation", "SwitcherooCodexProvider", "SwitcherooMacAdapters"]
        ),
        .target(
            name: "SwitcherooCodexProvider",
            dependencies: ["SwitcherooCore"]
        ),
        .target(
            name: "SwitcherooMacAdapters",
            dependencies: ["SwitcherooCore"]
        ),
        .executableTarget(
            name: "switcheroo",
            dependencies: ["SwitcherooDefaultApp"]
        ),
        .executableTarget(
            name: "SwitcherooMenuBar",
            dependencies: ["SwitcherooDefaultApp", "SwitcherooPresentation"]
        ),
    ]
)
