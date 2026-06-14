// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwertyFretboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QwertyFretboard", targets: ["QwertyFretboard"])
    ],
    targets: [
        .executableTarget(
            name: "QwertyFretboard",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreMIDI")
            ]
        )
    ]
)
