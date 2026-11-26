// swift-tools-version:6.0
import PackageDescription

// The NX2Apple Resigner's executable and nothing else. The app is the ResignerUI library of the frontend package (frontend/Package.swift,
// frontend/resigner/ARCHITECTURE.md): there it reaches the launcher's `package` types, and the frontend package keeps NX2Apple as its
// only executable, so `swift run` in frontend/ still starts the launcher.
// Build: frontend/tools/build_resigner.sh, or `swift run --package-path frontend/resigner/app` while working on it.
let package = Package(
    name: "NX2AppleResigner",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "NX2AppleResigner", dependencies: [.product(name: "ResignerUI", package: "frontend")], path: "Sources")
    ],
    swiftLanguageModes: [.v5]
)
