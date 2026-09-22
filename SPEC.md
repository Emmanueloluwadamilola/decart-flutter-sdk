# `decart_vton_flutter` architecture and compatibility specification

This document defines the behavior that the package is expected to preserve.
It is written for maintainers reviewing changes to the Dart API, native bridges,
or supported Decart SDK versions. Consumer setup and examples belong in
`README.md`; implementation details and upgrade procedures belong in
`IMPLEMENTATION.md`.

## 1. Scope

The package provides one Flutter API for Decart's realtime virtual try-on SDKs
on Android and iOS. It is responsible for:

- configuring and authenticating the native Decart clients;
- opening and closing one realtime camera session;
- applying prompt and garment-image updates without reconnecting;
- switching the published camera track in place;
- exposing consistent state, events, errors, and model metadata to Dart;
- rendering local and transformed LiveKit tracks inside Flutter;
- normalizing behavior where the Android and iOS SDKs differ.

The package does not implement Decart's signaling protocol, mint client tokens,
process video frames in Dart, provide batch/queue APIs, or support desktop and
web platforms.

## 2. Supported platforms and dependencies

| Component | Minimum or pinned value |
| --- | --- |
| Flutter | 3.44.0 |
| Dart | 3.12.0 |
| Android | API 24, Java 17, AGP 9-compatible build |
| Decart Android SDK | 0.7.10 |
| iOS | iOS 17, Xcode 16+, Swift Package Manager |
| Decart iOS SDK | 0.6.10 |

The Android SDK is resolved from JitPack. A consuming Android application must
therefore include JitPack in its dependency repositories. The plugin's own
repository declaration is not sufficient for the application's runtime
classpath.

The iOS SDK is distributed through Swift Package Manager and has no CocoaPods
package. Flutter's Swift Package Manager integration must be enabled. The iOS
17 deployment target is imposed by the upstream SDK and cannot be lowered by
the Dart wrapper.

The pinned native versions are the compatibility baseline. Overrides are
possible on Android through Gradle properties, but an override is supported
only after the verification steps in `IMPLEMENTATION.md` pass against it.

## 3. System architecture

The realtime path is:

```text
Flutter application
    │ MethodChannel commands / EventChannel events
    ▼
Kotlin or Swift plugin
    │ native Decart SDK
    ▼
Decart signaling service
    │ room credentials
    ▼
LiveKit Room over WebRTC
    ├── local camera track ──► Decart processing
    └── transformed track ◄── Decart processing
```

Platform channels carry configuration, commands, acknowledgements, and events.
They never carry video frames. Video remains in the native LiveKit/WebRTC stack
and is rendered through Flutter platform views.

The package supports one native client and one active session. `DecartVton()` is
therefore a singleton in normal application code. Tests may create isolated
instances through `DecartVton.forTesting`.

## 4. Authentication contract

Production initialization requires a `VtonClientTokenProvider`:

```dart
await DecartVton().initialize(
  clientTokenProvider: fetchFreshClientToken,
);
```

The provider must return a fresh, short-lived Decart client token with the
`ek_` prefix. The permanent `dct_` credential belongs on the application's
backend and must not be embedded in a distributed mobile application.

The plugin may call the provider again before a later connection, during
session restoration, or after an unused initial token has expired. It does not
persist returned credentials.

`initializeForDevelopment(apiKey: ...)` accepts a permanent `dct_` key only in
debug builds. It throws in profile and release builds and is not a production
authentication path.

## 5. Public lifecycle

The valid high-level sequence is:

```text
initialize
    ↓
connect
    ↓
setOutfit / switchCamera / observe
    ↓
disconnect
    ↓
connect again or dispose
```

Public lifecycle operations are serialized in Dart. A later operation cannot
overtake an earlier one and tear down resources that the earlier operation is
still creating.

`connect` creates the local camera stream before establishing the realtime
session. It completes only after the native SDK reports a usable connection and
the transformed stream is available.

`disconnect` releases session and camera resources while keeping the native
client available. `dispose` releases the client, closes Dart streams, and makes
that controller unusable.

`VtonLifecycleObserver` disconnects when the application is backgrounded and
can restore the most recent configuration with a fresh client token when the
application returns to the foreground.

## 6. Model contract

`VtonModel` is the shared source of truth for the model identifier, capture
geometry, frame rate, and reference-image support passed to both native SDKs.

| Dart value | Wire identifier | Capture geometry | Reference image |
| --- | --- | --- | --- |
| `lucyVtonLatest` | `lucy-vton-latest` | 1280×720 @ 30 fps | yes |
| `lucyVton35` | `lucy-vton-3.5` | 1280×720 @ 30 fps | yes |
| `lucyVton3` | `lucy-vton-3` | 1088×624 @ 30 fps | yes |
| `lucyVton2` | `lucy-vton-2` | 1088×624 @ 30 fps | yes |
| `lucyLatest` | `lucy-latest` | 1088×624 @ 30 fps | yes |
| `lucy21` | `lucy-2.1` | 1088×624 @ 30 fps | yes |
| `lucy25` | `lucy-2.5` | 1280×720 @ 30 fps | yes |
| `lucyRestyleLatest` | `lucy-restyle-latest` | 1280×704 @ 30 fps | no |
| `lucyRestyle2` | `lucy-restyle-2` | 1280×704 @ 30 fps | no |

`latest` identifiers are server-managed aliases. Versioned identifiers request
a named deployment, but the upstream service remains responsible for the
contents and availability of every deployment.

VTON 3.5 and `lucy-vton-latest` accept only 720p output in this compatibility
baseline. The Dart layer rejects a 1080p request for either model before it
reaches native code.

## 7. Outfit-state semantics

An outfit consists of an optional nonblank prompt, an optional JPEG/PNG/WebP
reference image, and the `enhance` flag. At least one of prompt or image must be
present. Reference images must be 5 MB or smaller.

Every `setOutfit` call replaces the complete server-side outfit state:

| Update | Result on a reference-image model |
| --- | --- |
| prompt only | replaces prompt and clears the previous image |
| image only | replaces image and clears the previous prompt |
| prompt + image | replaces both |

To change one field while retaining another, callers must start from
`currentOutfit` and use `copyWith`.

`currentOutfit` is client-side bookkeeping. It changes only after the native
operation succeeds; it is not read back from the service.

The upstream Android and iOS SDKs route outfit updates differently. The plugin
normalizes them so the table above is true on both platforms. Non-reference
models receive prompt messages and reject image input.

## 8. Camera and media configuration

The default camera is front-facing. `VtonMirrorMode.auto` pre-flips frames only
for the front camera before they are published. This is distinct from the
display-only `mirror` option on `VtonLocalPreview`.

The cross-platform video defaults are:

| Setting | Default |
| --- | --- |
| Maximum publish bitrate | 2,500,000 bits/s |
| Maximum publish frame rate | 30 fps |
| Preferred codec | VP8 |
| Simulcast | enabled |

These defaults intentionally replace the different defaults supplied by the
two native SDKs. Applications should override them only after measuring the
effect on their target devices and networks.

`switchCamera` replaces the capturer behind the existing published track. It
must preserve the LiveKit Room, Decart session ID, authentication token, and
current outfit. Dart state changes only after native switching succeeds.

## 9. State, events, and errors

The Dart connection-state enum is the union of native states:

```text
idle, connecting, connected, generating,
reconnecting, disconnected, error
```

Android does not emit every state in the union. iOS does not expose the same
dedicated error flow as Android. Those differences are documented rather than
hidden behind fabricated events.

Native and plugin-domain failures are represented by `DecartVtonException` and
`VtonErrorCode`. Raw `PlatformException` values must not escape the platform
binding. Invalid Dart argument combinations may throw `ArgumentError`; invalid
lifecycle or build-mode use may throw `StateError`.

The event stream contains:

- connection-state changes;
- session start and session ID;
- generation ticks;
- local and remote stream updates;
- connection-quality reports;
- normalized error events.

Unknown event types are ignored by older Dart code so a native addition does
not break an otherwise compatible release.

## 10. Platform-channel contract

Channel identifiers:

```text
Method channel: ai.decart.vton/methods
Event channel:  ai.decart.vton/events
Video view:     ai.decart.vton/video_view
```

Supported methods:

| Method | Purpose |
| --- | --- |
| `initialize` | create the native client with a supplied credential |
| `connect` | create camera and realtime session |
| `setOutfit` | atomically replace outfit state |
| `switchCamera` | replace the active camera capturer |
| `disconnect` | close the session and camera |
| `release` | release all native client resources |
| `isConnected` | read native session state |
| `checkConnectivity` | run a STUN-only preflight probe |

Event `type` values:

```text
connectionState
sessionStarted
generationTick
remoteStreamUpdated
localStreamUpdated
connectionQuality
error
```

Platform-view creation parameters are:

```text
source: remote | local
fit: cover | contain
mirror: bool
```

`lib/src/decart_vton_platform.dart`, `ChannelCodec.kt`, and
`ChannelCodec.swift` are the only files that should construct or decode raw
channel maps. `tool/check_contract.py` verifies that the three implementations
remain aligned.

## 11. Rendering contract

`VtonRemoteView` renders the transformed track. `VtonLocalPreview` renders the
published camera track. Both are Flutter hosts for native views:

| Platform | Native renderer | Flutter integration |
| --- | --- | --- |
| Android | LiveKit `TextureViewRenderer` | hybrid-composition platform view |
| iOS | LiveKit `VideoView` | `UiKitView` |

The native view registry must rebind existing views when reconnection creates a
new stream. Dart receives an informational stream-update event but does not
recreate the view.

On Android, a renderer belongs to the current Room's EGL context. A Room change
requires releasing and recreating the renderer inside its stable container.

## 12. Resource ownership

Caller-created local camera streams and tracks are explicitly stopped or
disposed during failed connection attempts, disconnect, engine detachment, and
release. Remote streams are owned by the Decart SDK and are dereferenced rather
than disposed by the plugin.

Event collectors and Swift tasks are cancelled when their session or engine is
released. Native channel replies and event-sink calls occur on the platform
thread.

These rules prevent leaked rooms, cameras remaining active after hot restart,
stale renderers, and replies sent through a detached Flutter messenger.

## 13. Security and privacy requirements

- Production applications use short-lived client tokens minted by their own
  authenticated backend.
- Permanent credentials are never committed, logged, persisted by the plugin,
  or accepted by the production initializer.
- Camera permission is obtained by the host application before `connect`.
- The host application provides appropriate privacy disclosures and consent.
- Media, prompts, and reference images are transmitted to Decart to provide the
  requested transformation.
- Connectivity checks remain STUN-only and must not open a billable model
  session.

## 14. Verification requirements

A change is ready to merge when the applicable checks pass:

```bash
tool/verify.sh --fast       # contract, formatting, analysis, unit tests
tool/verify.sh              # also builds Android
tool/verify.sh --ios        # also builds iOS on macOS
dart doc --validate-links   # public API documentation links
```

Changes to session, camera, renderer, authentication, or lifecycle code also
require physical-device testing. The minimum device flow is connect, display
the transformed stream, apply prompt/image/both updates, switch cameras,
background and restore, then disconnect.

## 15. Change policy

When upgrading a native SDK or adding a model:

1. Compare the upstream API and dependency graph with the pinned baseline.
2. Update the model metadata and native configuration builders together.
3. Run the cross-language contract check.
4. Compile both native targets.
5. Repeat the physical-device flow on Android and iOS.
6. Update this specification only for behavior that the package actually
   guarantees.

Implementation history and temporary investigation notes do not belong in this
document. Durable rationale should be recorded next to the relevant contract or
in `IMPLEMENTATION.md`.
