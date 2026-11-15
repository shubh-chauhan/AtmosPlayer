// swift-tools-version: 6.1

import PackageDescription

// The player engine with its optional components switched on. Xcode projects can't pick a
// package's traits from project.yml, so this small local package depends on AetherEngine with
// the traits enabled and the app depends on it.
//
// - TrueHDObjectAudio / DTSXObjectAudio: TrueHD Atmos and DTS:X keep their height channels,
//   rendered to a 7.1.4 bed that iOS spatialises on AirPods.
// - DolbyVisionFelCurves: Profile 7 FEL sources keep most of their enhancement layer.
// - DolbyVisionStillReshaping: scrub thumbnails for Dolby Vision Profile 5 sources.
//
// These components may be subject to third-party patent licensing (see AetherEngine's README);
// this is a personal build.
let package = Package(
    name: "EngineBundle",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "EngineBundle", targets: ["EngineBundle"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            from: "7.67.1",
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DolbyVisionFelCurves", "DolbyVisionStillReshaping"]
        ),
    ],
    targets: [
        .target(
            name: "EngineBundle",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]
        ),
    ]
)
