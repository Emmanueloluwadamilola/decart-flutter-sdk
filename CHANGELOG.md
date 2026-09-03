# Changelog

## 1.0.0

Stable release consolidating the existing realtime virtual try-on integration.

- Realtime virtual try-on for Android and iOS, including VTON 3.5 at
  1280x720.
- `DecartVton`, native video views, lifecycle handling, and production
  client-token authentication.
- Typed connection state, events, and normalized `VtonErrorCode` failures.
- Reuses the client created by `initialize()` for the first connection, avoiding
  a duplicate token request while retaining refresh-on-reconnect behavior.
- Switches front and back cameras on the existing published track, preserving
  the Decart session ID, outfit state, and client token.
- Adds file-backed garment images through `referenceImagePath`, avoiding large
  Dart heap allocations and platform-channel byte copies for picker files.

## 0.1.0

Initial pub.dev release.

- Realtime virtual try-on wrapping `DecartAI/decart-android` 0.7.10 and
  `DecartAI/decart-ios` v0.6.10, including VTON 3.5 at 1280x720.
- `DecartVton` controller: `initialize`, `connect`, `setOutfit`, `switchCamera`,
  `checkConnectivity`, `disconnect`, `dispose`.
- `VtonRemoteView` and `VtonLocalPreview` platform views, with native rebinding
  across automatic reconnects.
- Outfit updates by prompt, by garment reference image, or both — with the
  whole-state-replace semantics of the underlying API made explicit rather than
  hidden.
- Android replicates the iOS SDK's `hasReferenceImage` message routing, so an
  outfit update means the same thing on both platforms.
- `VtonLifecycleObserver` for background/foreground session handling.
- Short-lived production client-token provider API; only `ek_` client tokens
  are accepted there, and tokens are refreshed before a new or restored
  session.
- Explicit `initializeForDevelopment(apiKey: ...)` escape hatch for local
  prototypes; it accepts `dct_` test keys in debug builds and is disabled in
  profile and release builds.
- Serialized lifecycle and outfit operations to prevent overlapping native
  connects, disconnects and updates.
- Android garment-image encoding runs off the main thread.
- Removes the unused unshaded Android WebRTC engine and narrows consumer R8
  rules to reduce release size.
- Requires Flutter 3.44 / Dart 3.12 and migrates the plugin to AGP 9 built-in
  Kotlin support.
- Single `DecartVtonException` type with a normalised `VtonErrorCode`; no
  `PlatformException` escapes the package.

Security, privacy, setup and supported-platform details are in `README.md`.
