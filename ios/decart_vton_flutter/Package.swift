// swift-tools-version: 6.0
import PackageDescription

// Swift Package Manager manifest for the iOS side of `decart_vton_flutter`.
//
// This plugin is SPM-only, and that is not a preference — it is forced by the
// upstream SDK. `DecartAI/decart-ios` ships no podspec, and its transitive
// dependency `shareup/websocket-apple` has no CocoaPods presence either, so
// there is no honest way to author a podspec that resolves `DecartSDK`.
//
// Enable Flutter's SPM integration once per machine:
//
//     flutter config --enable-swift-package-manager
//
// See README > iOS setup.
let package = Package(
    name: "decart_vton_flutter",
    // DecartSDK's own Package.swift declares .iOS(.v17). This cannot be lowered.
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "decart-vton-flutter", targets: ["decart_vton_flutter"])
    ],
    dependencies: [
        // Flutter's SPM integration generates this package next to the plugin's
        // own at build time; it is what makes `import Flutter` resolve. Without
        // it the build fails with:
        //   "Plugin decart_vton_flutter has a Package.swift for ios but is
        //    missing a dependency on FlutterFramework."
        // The relative path is resolved against this manifest's directory, so
        // it only exists inside a Flutter build — resolving this package
        // standalone (outside `flutter build`) will not work, which is normal
        // for a Flutter plugin.
        .package(name: "FlutterFramework", path: "../FlutterFramework"),

        // Pinned to the release this plugin's Swift is tested against.
        // 0.6.x is pre-1.0, so `upToNextMinor` rather than `from` — a 0.7.0
        // may break the API surface used here.
        .package(
            url: "https://github.com/DecartAI/decart-ios.git",
            exact: "0.6.10"
        ),
        // Declared explicitly even though DecartSDK already depends on it:
        // `VtonVideoPlatformView` imports LiveKit directly for `VideoView`, and
        // relying on a transitive module being importable is not something SPM
        // guarantees. SwiftPM resolves this to a single shared version.
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            from: "2.5.0"
        )
    ],
    targets: [
        .target(
            name: "decart_vton_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "DecartSDK", package: "decart-ios"),
                .product(name: "LiveKit", package: "client-sdk-swift")
            ]
        )
    ]
)
