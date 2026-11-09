// swift-tools-version: 5.10
//
// Faders — a clean, modern per-app volume mixer for the macOS menu bar.
//
// Build with `swift build`, or run `./scripts/build-app.sh` to produce Faders.app.
// Run the unit tests with `swift test`.

import PackageDescription

let package = Package(
    name: "Faders",
    platforms: [
        // Per-app volume relies on Core Audio "process taps", added in macOS 14.2.
        // 14.4 is the first release where they are reliable in practice.
        .macOS("14.4")
    ],
    dependencies: [
        // Lock-free atomics for the one value the UI shares with the real-time
        // audio thread (the volume). The standard library's `Atomic` needs macOS 15.
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "Faders",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")],
            path: "Sources/Faders"
        ),
        .testTarget(
            name: "FadersTests",
            dependencies: ["Faders"],
            path: "Tests/FadersTests"
        ),
    ]
)
