// swift-tools-version: 5.10
//
// Faders — a clean, modern per-app volume mixer for the macOS menu bar.
//
// Build with `swift build`, or run `./scripts/build-app.sh` to produce Faders.app.

import PackageDescription

let package = Package(
    name: "Faders",
    platforms: [
        // Per-app volume relies on Core Audio "process taps", added in macOS 14.2.
        // 14.4 is the first release where they are reliable in practice.
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "Faders",
            path: "Sources/Faders"
        )
    ]
)
