// swift-tools-version:6.0
import PackageDescription

// The import rules are in ARCHITECTURE.md. Each target may only import the ones above it:
// NXCore (Foundation), NXModel (NXCore), NXLauncher (NXModel, NXCore), NX2Apple (all).
// The Resigner's targets follow the same rules (frontend/resigner/ARCHITECTURE.md): ResignerCore (Foundation, NXCore), ResignerModel
// (ResignerCore, NXModel, NXCore), ResignerUI (all but NX2Apple). NX2Apple stays the package's only executable, so `swift run` starts
// the launcher. The Resigner's executable is the package in frontend/resigner/app, which links the ResignerUI library.
// All targets build in Swift 5 mode for now: NXCore does not build in Swift 6 mode yet (LauncherWork.counts, PipeReader).
let package = Package(
    name: "NX2Apple",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NX2Apple", targets: ["NX2Apple"]),
        .library(name: "ResignerUI", targets: ["ResignerUI"])
    ],
    targets: [
        .target(name: "NXCore", path: "Sources/NXCore"),
        .target(name: "NXModel", dependencies: ["NXCore"], path: "Sources/NXModel"),
        .target(name: "NXLauncher", dependencies: ["NXModel", "NXCore"], path: "Sources/NXLauncher"),
        .executableTarget(name: "NX2Apple", dependencies: ["NXLauncher", "NXModel", "NXCore"], path: "Sources/NX2Apple"),
        // Tests of the pure logic: they link NXCore only, so they run without SwiftUI.
        .testTarget(name: "NXCoreTests", dependencies: ["NXCore"]),
        // Tests of the stores: they link NXModel and NXCore, never SwiftUI.
        .testTarget(name: "NXModelTests", dependencies: ["NXModel", "NXCore"]),
        .testTarget(name: "NX2AppleTests", dependencies: ["NX2Apple", "NXLauncher", "NXModel", "NXCore"]),
        // NX2Apple Resigner (frontend/resigner/ARCHITECTURE.md): the same layers. ResignerCore imports Foundation and NXCore only.
        .target(name: "ResignerCore", dependencies: ["NXCore"], path: "Sources/ResignerCore"),
        .target(name: "ResignerModel", dependencies: ["ResignerCore", "NXModel", "NXCore"], path: "Sources/ResignerModel"),
        .target(name: "ResignerUI", dependencies: ["ResignerModel", "ResignerCore", "NXLauncher", "NXModel", "NXCore"],
                path: "Sources/ResignerUI"),
        .testTarget(name: "ResignerCoreTests", dependencies: ["ResignerCore", "NXCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ResignerModelTests", dependencies: ["ResignerModel", "ResignerCore", "NXModel", "NXCore"])
    ],
    swiftLanguageModes: [.v5]
)
