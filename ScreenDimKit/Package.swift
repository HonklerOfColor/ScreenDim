// swift-tools-version: 6.2

import PackageDescription

// Logik ohne UI und ohne private API: DDC-Protokoll, Display-Verwaltung, Dimmung,
// Speicher, Entprellung. Beide App-Targets linken das Paket; die Tests laufen per
// `swift test`, ohne App und ohne Hardware.
let package = Package(
    name: "ScreenDimKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScreenDimKit", targets: ["ScreenDimKit"]),
    ],
    targets: [
        .target(
            name: "ScreenDimKit",
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
        .testTarget(
            name: "ScreenDimKitTests",
            dependencies: ["ScreenDimKit"],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ]
)
