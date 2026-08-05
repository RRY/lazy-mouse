// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "mxctl",
    platforms: [
        .macOS(.v13)
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
