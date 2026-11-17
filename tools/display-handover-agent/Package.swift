// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "display-handover-agent",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DisplayHandoverAgentCore"),
        .executableTarget(
            name: "display-handover-agent",
            dependencies: ["DisplayHandoverAgentCore"],
            linkerSettings: [
                .linkedFramework("ColorSync"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                // Embeds an Info.plist so the Local Network privacy control can identify the binary
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", Context.packageDirectory + "/Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(name: "DisplayHandoverAgentCoreTests", dependencies: ["DisplayHandoverAgentCore"]),
    ]
)
