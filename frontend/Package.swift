// swift-tools-version:6.0
import PackageDescription

// The import rules are in ARCHITECTURE.md. Each target may only import the ones above it:
// NXCore (Foundation), NXModel (NXCore), NXLauncher (NXModel, NXCore), NX2Apple (all).
// All targets build in Swift 5 mode for now: NXCore does not build in Swift 6 mode yet (LauncherWork.counts, PipeReader).
let package = Package(
    name: "NX2Apple",
    platforms: [.macOS(.v13)],
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
        .testTarget(name: "ResignerCoreTests", dependencies: ["ResignerCore", "NXCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
