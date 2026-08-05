// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "mxctl",
    platforms: [
        // macOS 14 wegen SettingsLink und der zweiparametrigen onChange-Signatur in MXMenu.
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "HIDPPKit",
            path: "Sources/HIDPPKit"
        ),
        .executableTarget(
            name: "mxctl",
            dependencies: ["HIDPPKit"],
            path: "Sources/mxctl"
        ),
        .executableTarget(
            name: "MXMenu",
            dependencies: ["HIDPPKit"],
            path: "Sources/MXMenu",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "hidraw",
            path: "Sources/hidraw"
        ),
        .executableTarget(
            name: "gattscan",
            path: "Sources/gattscan",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/gattscan/Info.plist"
                ])
            ]
        )
    ]
)
