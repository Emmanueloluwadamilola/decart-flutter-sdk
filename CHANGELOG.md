# Changelog

## 0.1.0

Initial release.

- Realtime virtual try-on wrapping `DecartAI/decart-android` 0.7.9 and
  `DecartAI/decart-ios` v0.6.9.
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
- Single `DecartVtonException` type with a normalised `VtonErrorCode`; no
  `PlatformException` escapes the package.

Known limitations are listed in `README.md`; build-verification status is in
`IMPLEMENTATION.md` §10.
