// swift-tools-version:5.9
import PackageDescription

// The recached release whose RecachedFFI.xcframework this package links on
// Apple platforms. While these are empty, Apple builds use
// engine/RecachedFFI.xcframework, built from a recached checkout by
// scripts/build-engine.sh on a Mac. Pinning a release also means committing
// that release's generated Sources/RecachedCore/RecachedCore.swift.
let engineURL = ""
let engineChecksum = ""

#if os(Linux)
    // On Linux the core is a system library: scripts/build-engine.sh stages the
    // header and librecached_mobile.so in engine/, and scripts/test-linux.sh
    // points the linker at it. This is how CI and non-Apple contributors test.
    let ffi: Target = .systemLibrary(name: "RecachedFFI", path: "Sources/RecachedFFI")
#else
    let ffi: Target =
        engineURL.isEmpty
        ? .binaryTarget(name: "RecachedFFI", path: "engine/RecachedFFI.xcframework")
        : .binaryTarget(name: "RecachedFFI", url: engineURL, checksum: engineChecksum)
#endif

let package = Package(
    name: "Recached",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Recached", targets: ["Recached"])
    ],
    targets: [
        ffi,
        // UniFFI-generated bindings over RecachedFFI. Not an API: Recached wraps it.
        .target(name: "RecachedCore", dependencies: ["RecachedFFI"]),
        .target(
            name: "Recached",
            dependencies: ["RecachedCore"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "RecachedTests",
            dependencies: ["Recached"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
