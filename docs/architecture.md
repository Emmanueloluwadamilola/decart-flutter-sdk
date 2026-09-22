# Architecture

`decart_vton_flutter` presents one Dart API over Decart's Android and iOS
realtime SDKs. Flutter controls the session and interface, while camera capture,
WebRTC transport, model communication, and video rendering remain native.

## System overview

```text
Flutter application
    │
    ├── DecartVton API
    │      │
    │      ├── MethodChannel ─────► Kotlin / Swift session controller
    │      └── EventChannel  ◄───── native state, quality, and errors
    │
    ├── VtonRemoteView ───────────► native transformed-video renderer
    └── VtonLocalPreview ─────────► native camera-preview renderer
                                      │
                                      ▼
                              Decart native SDK
                                      │
                                      ▼
                           LiveKit Room over WebRTC
                              │                 │
                              │ camera track    │ transformed track
                              ▼                 ▼
                           Decart realtime VTON service
```

Platform channels carry commands and events, not video frames. LiveKit and
WebRTC keep video in the native media pipeline, avoiding per-frame copies
through Dart.

## Layer responsibilities

### Dart API

The Dart layer provides:

- authentication through a short-lived client-token provider;
- serialized lifecycle operations;
- model, camera, mirror, resolution, and video configuration;
- outfit validation and immutable outfit state;
- typed connection state, events, quality reports, and errors;
- application-lifecycle restoration;
- Flutter widgets that host native video views.

`DecartVton` is a singleton in normal application code because each native
implementation owns one Decart client and one active realtime session.

### Platform channels

The method channel carries operations such as:

```text
initialize
connect
setOutfit
switchCamera
disconnect
release
checkConnectivity
```

The event channel carries:

```text
connectionState
sessionStarted
generationTick
localStreamUpdated
remoteStreamUpdated
connectionQuality
error
```

Raw channel maps are centralized in three codecs:

- `lib/src/decart_vton_platform.dart`
- `android/src/main/kotlin/ai/decart/vton/flutter/ChannelCodec.kt`
- `ios/decart_vton_flutter/Sources/decart_vton_flutter/ChannelCodec.swift`

`tool/check_contract.py` verifies that their method names, argument keys,
events, view parameters, and error vocabulary remain aligned.

### Native session controllers

The Kotlin and Swift session controllers own their platform's Decart client,
LiveKit Room, camera track, transformed track, and native event collectors.
They also normalize differences between the upstream Android and iOS SDKs.

The most important normalization concerns outfit updates. Every update replaces
the complete outfit state. The Android bridge deliberately routes updates so a
prompt-only change clears the previous image on both platforms, matching the
iOS and server semantics.

### Media transport

LiveKit manages the Room, track publication and subscription, reconnection, and
connection quality. WebRTC provides the underlying encrypted realtime media
transport, including ICE, STUN, TURN, congestion control, and video delivery.

The flow for a connected session is:

1. The native SDK obtains LiveKit Room credentials through Decart signaling.
2. The device publishes its camera track to the Room.
3. Decart subscribes to and transforms the camera stream.
4. Decart publishes the transformed stream back to the Room.
5. The native SDK subscribes to the transformed track.
6. The plugin binds that track to the remote video view.

Changing an outfit or switching cameras does not create another Room.

## Native rendering

The package does not depend on `flutter_webrtc`. It renders the LiveKit tracks
provided by the Decart SDK directly:

| Platform | Renderer | Flutter host |
| --- | --- | --- |
| Android | LiveKit `TextureViewRenderer` | hybrid-composition platform view |
| iOS | LiveKit `VideoView` | `UiKitView` |

Flutter determines the view's size, position, clipping, gestures, and
surrounding controls. Native WebRTC code decodes and paints the pixels.

The native view registry rebinds existing views when reconnection produces a
replacement stream. This avoids rebuilding Flutter platform views and reduces
visible interruption.

On Android, each renderer is initialized with the owning Room's EGL context.
When the Room changes, the renderer is recreated inside a stable native
container. Hybrid composition is used because it reliably hosts the
renderer-managed EGL surface across devices.

## Authentication

Production applications pass a `VtonClientTokenProvider` to `initialize`.
Their backend stores the permanent Decart credential and returns short-lived
`ek_` tokens to authenticated clients. The plugin requests a fresh token for
later connections and restoration, and never persists it.

`initializeForDevelopment` accepts a permanent `dct_` key only in debug builds.
It is disabled in profile and release builds.

## Lifecycle and ownership

Public operations are serialized so connection, update, camera, and teardown
operations cannot overtake one another.

The plugin explicitly releases caller-owned camera streams and tracks after a
failed connection, disconnect, engine detachment, and disposal. Event tasks and
collectors are cancelled with their session. Remote streams are owned by the
Decart SDK and are unbound rather than disposed by the plugin.

`VtonLifecycleObserver` can disconnect an active session in the background and
restore its last configuration after foregrounding with a newly obtained
credential.

## Cross-platform boundaries

The wrapper normalizes:

- outfit-update routing;
- codec and bitrate defaults;
- enhancement defaults;
- camera-permission errors;
- native error-code vocabularies;
- stream rebinding after reconnection.

Some upstream differences remain visible. Android provides a richer
out-of-band error flow, while iOS provides additional connection states. The
Dart API exposes their documented union rather than manufacturing equivalent
native behavior.

## Further documentation

<!-- - [`../SPEC.md`](../SPEC.md) defines the supported behavior and compatibility
  contract.
- [`../IMPLEMENTATION.md`](../IMPLEMENTATION.md) explains the code structure,
  native internals, maintenance workflow, and SDK upgrade process. -->
- [`../README.md`](../README.md) contains consumer installation and usage
  instructions.
