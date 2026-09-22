# `decart_vton_flutter` maintainer guide

This document explains how the package implements the behavior defined in
`SPEC.md`. It is intended for maintainers changing the Dart controller, native
SDK integrations, platform views, or cross-language wire contract. Application
developers should start with `README.md`.

## 1. Runtime overview

A realtime session has two control paths and one media path:

```text
Control from Flutter
  DecartVton
      └── MethodChannel ──► Kotlin / Swift session controller

Events to Flutter
  Kotlin Flow / Swift AsyncStream
      └── EventChannel ──► typed Dart events and state

Video
  camera ──► LiveKit/WebRTC ──► Decart model
         ◄── transformed LiveKit/WebRTC track
```

Video frames do not cross a Flutter channel. The native Decart SDK owns
signaling and the LiveKit session, while this plugin owns the Flutter-facing
lifecycle, type conversion, view binding, and cross-platform normalization.

The native compatibility baseline is:

| Platform | SDK |
| --- | --- |
| Android | `decart-android` 0.7.10 |
| iOS | `decart-ios` 0.6.10 |

## 2. Repository structure

```text
lib/
  decart_vton_flutter.dart          public exports
  src/decart_vton.dart              public controller and lifecycle state
  src/decart_vton_platform.dart     Dart channel codec
  src/vton_lifecycle_observer.dart  background/foreground restoration
  src/models/                       public values, events, errors, configuration
  src/widgets/vton_video_view.dart  local and remote platform-view hosts

android/src/main/
  kotlin/.../DecartVtonPlugin.kt          channel registration and dispatch
  kotlin/.../VtonSessionController.kt    Android session ownership
  kotlin/.../VtonVideoPlatformView.kt    LiveKit renderer and view registry
  kotlin/.../VtonEventDispatcher.kt      event buffering and main-thread delivery
  kotlin/.../ChannelCodec.kt             Android wire codec
  kotlin/.../Errors.kt                   Android error normalization
  java/.../AndroidMirrorProcessorFactory.java

ios/decart_vton_flutter/Sources/decart_vton_flutter/
  DecartVtonPlugin.swift            channel registration and dispatch
  VtonSessionController.swift      iOS session ownership
  VtonVideoPlatformView.swift      LiveKit view and registry
  VtonEventDispatcher.swift        event delivery and value normalization
  ChannelCodec.swift               iOS wire codec
  Errors.swift                     iOS error normalization

tool/check_contract.py             static cross-language contract check
tool/verify.sh                     formatting, analysis, tests, and native builds
```

## 3. Dart layer

### 3.1 `DecartVton`

`DecartVton` is the public controller and the source of Dart-side state. The
default constructor returns a singleton because each native implementation owns
one client and one active session. `forTesting` bypasses the singleton and
accepts an isolated platform binding.

The controller is responsible for:

- validating lifecycle order and public arguments;
- obtaining and validating credentials;
- serializing public operations through `_operationTail`;
- maintaining synchronous snapshots such as `connectionState`, `sessionId`,
  `cameraFacing`, and `currentOutfit`;
- converting the native event stream into broadcast event, state, and error
  streams;
- retaining the most recent connection request for lifecycle restoration.

State is updated only after the corresponding operation succeeds. In
particular, a failed outfit update does not replace `currentOutfit`, and a
failed camera switch does not change `cameraFacing`.

### 3.2 Authentication and refresh

Production initialization stores a `VtonClientTokenProvider`, requests one
fresh `ek_` token, and creates the native client. The first connection reuses
that unused credential. Later connections refresh the native client with a new
token. If the initially created client reports an expired or rejected token on
its first use, the controller refreshes and retries once.

`initializeForDevelopment` follows the same native initialization path but
accepts a `dct_` key and is guarded by `kDebugMode`. Keeping both paths behind
the same private configuration object prevents authentication behavior from
drifting after the credential is obtained.

The plugin intentionally does not mint tokens. A mobile client cannot safely
hold the permanent credential needed to call Decart's token endpoint.

### 3.3 Serialized operations

`initialize`, `connect`, `setOutfit`, `switchCamera`, `disconnect`, session
restoration, and `dispose` are serialized. This avoids races such as a
disconnect releasing a client while a connect is still creating its local
camera stream.

Serialization is an ordering guarantee, not an error-swallowing mechanism. A
failed operation completes its returned future with the original error while
the tail is recovered so a later operation can still run.

### 3.4 `DecartVtonPlatform`

This is the only Dart file that deals directly with `MethodChannel`,
`EventChannel`, `PlatformException`, and raw maps. It:

- invokes the eight native methods;
- decodes native event maps into the sealed `VtonEvent` hierarchy;
- maps native error strings into `VtonErrorCode`;
- converts missing-plugin failures into a package-level exception;
- ignores unknown event types for forward compatibility.

Raw wire-map handling should not spread into model or controller classes. A
future Pigeon migration, if justified by a larger protocol, should replace this
file and the two native codecs rather than introduce a second parallel codec.

### 3.5 Models and values

`VtonModel` supplies the model identifier, expected camera geometry, frame
rate, and reference-image capability to both native platforms. The native
bridges construct their SDK model definitions from this payload instead of
maintaining independent model tables.

`VtonOutfit` is immutable and supports explicit field preservation and clearing
through `copyWith`. Byte arrays participate in value equality by contents.

`VtonVideoConfig` pins identical codec, bitrate, frame-rate, and simulcast
defaults on Android and iOS. This removes platform-dependent behavior caused by
the different upstream defaults.

### 3.6 Lifecycle observer

`VtonLifecycleObserver` disconnects an active session when the application
moves to the background. If restoration is enabled, it calls
`resumeLastSession` after foregrounding. The saved request contains model,
camera, mirror, output resolution, video configuration, and outfit state, but
not a cached credential; restoration obtains a fresh token.

## 4. Outfit update normalization

The Decart wire protocol has a prompt message and a broader image message that
can carry image, prompt, and enhancement state together. Supplying a null image
to the broader message clears the previous reference image.

The native SDKs expose that behavior differently:

| Platform | Reference-image model | Non-reference model |
| --- | --- | --- |
| Android SDK | separate `setImage` and `setPrompt` methods | `setPrompt` |
| iOS SDK | `setPrompt(DecartPrompt)` routes internally | same public method |

`VtonSessionController.kt` reproduces the model-based routing used on iOS. A
reference-image model always uses Android's image-capable update, even for a
prompt-only request. This makes prompt-only updates clear the previous image on
both platforms, matching the whole-state replacement contract.

The Dart layer rejects invalid combinations before they cross the channel:

- no prompt and no image;
- blank prompt without an image;
- byte and path image sources together;
- image input for a model that does not support it;
- unsupported image signatures;
- an image larger than 5 MB;
- `outfit` combined with individual outfit fields.

File-backed images avoid loading the original bytes into the Dart heap or
copying them through the platform channel. Android reads and Base64-encodes the
file off the main dispatcher. iOS validates and memory-maps the file before
creating `DecartPrompt` data.

## 5. Android implementation

### 5.1 Plugin and threading

`DecartVtonPlugin` registers the method channel, event channel, and platform
view factory. Method calls that reach suspend APIs are launched in a
`Dispatchers.Main.immediate + SupervisorJob` scope. Replies are delivered on
the Flutter platform thread.

Engine detachment releases native resources before unregistering channel
handlers. This ordering prevents a Room or camera from surviving a Dart hot
restart with no controller attached.

### 5.2 Session controller

`VtonSessionController` owns `DecartClient`, `RealTimeClient`, the local and
remote streams, model capability state, and jobs collecting the SDK flows.

Initialization creates the client and starts collectors early enough to retain
the first connection transition. Connection performs these steps:

1. Verify camera permission.
2. Tear down any previous session state.
3. Build a `RealtimeModel` and media configuration from channel arguments.
4. Create the caller-owned local video stream.
5. Register that stream with the local-view registry.
6. Connect the realtime client and retain the returned remote stream.
7. Register the remote stream and return the session ID.

If connection fails after camera creation, the local stream is disposed before
the error is returned.

### 5.3 Events

The controller collects connection state, errors, session start, generation
ticks, local/remote stream updates, and connection quality from SDK flows.
`VtonEventDispatcher` buffers a bounded set of events until Dart listens and
delivers every event through the main looper.

### 5.4 Rendering

`VtonVideoViewFactory` creates a stable `FrameLayout` containing LiveKit's
`TextureViewRenderer`. The view registry tracks local and remote views and
binds the current `RealtimeMediaStream` immediately when a view registers.

The renderer is initialized against:

```kotlin
room.lkObjects.eglBase.eglBaseContext
```

When reconnection yields a stream owned by a different Room, the renderer is
released and recreated inside the same container. Reinitializing one renderer
against a new EGL context is not reliable.

Flutter uses hybrid composition for this native view. It is robust for the
renderer-managed EGL surface but can cost additional GPU composition when
large translucent or animated Flutter layers overlap the video.

### 5.5 Camera switching

The controller obtains the existing LiveKit `LocalVideoTrack` and calls
`restartTrack` with the selected camera position. LiveKit moves the current
renderers to the replacement track and updates the sender without reconnecting
the Room. The Decart mirror processor is rebuilt so `VtonMirrorMode.auto`
continues to mirror only the front camera.

`AndroidMirrorProcessorFactory.java` is a narrow interoperability helper for a
public JVM class that Kotlin treats as internal through metadata.

### 5.6 Build configuration

`android/build.gradle` pins the supported SDK and toolchain defaults while
allowing consuming applications to override compatible versions through
Gradle properties. It excludes an unused unshaded WebRTC artifact; the active
Decart path uses LiveKit's shaded WebRTC classes.

The consuming application must declare JitPack. Critical R8 rules are repeated
in the plugin's consumer rules so release builds preserve SDK classes used by
JNI, serialization, and reflection.

## 6. iOS implementation

### 6.1 Swift Package Manager

`ios/decart_vton_flutter/Package.swift` declares FlutterFramework, DecartSDK
0.6.10, and LiveKit. LiveKit is explicit because the platform-view source
imports `VideoView` directly; relying on a transitive import is not supported by
Swift Package Manager.

The podspec exists only for Flutter tooling compatibility and cannot resolve
DecartSDK. A functional iOS build uses Flutter's Swift Package Manager
integration.

### 6.2 Plugin and concurrency

`DecartVtonPlugin.register` creates the dispatcher, view registry, and session
controller on the platform thread, then registers both channels and the video
view factory.

`VtonSessionController` is main-actor isolated because camera creation, UIKit
views, Flutter replies, and much of the SDK-facing state are main-thread-bound.
The Decart and LiveKit SDKs perform their internal network and media work away
from the main actor.

### 6.3 Session controller

The iOS manager is created per session because its configuration includes the
model and initial prompt. Connection therefore:

1. Verifies or requests camera authorization.
2. Builds the SDK model, prompt, and realtime configuration.
3. Creates the local camera stream.
4. Creates the realtime manager and starts its event tasks.
5. Connects the manager with the local stream.
6. Binds the returned remote stream to registered views.

The controller validates credentials and URLs before constructing SDK objects
whose initializers may terminate on invalid input.

The SDK event stream contains state snapshots rather than separate events. The
controller compares each snapshot with the previous connection state, session
ID, and generation tick before emitting Flutter events.

### 6.4 Rendering

`VtonVideoPlatformView` contains LiveKit's `VideoView`. Binding is a direct
assignment:

```swift
videoView.track = stream?.videoTrack
```

The registry stores views weakly because `FlutterPlatformView` has no Android-
style disposal callback. A view removed by Flutter can therefore be released
without an explicit unregister call.

### 6.5 Camera switching and teardown

The controller retrieves the `CameraCapturer` from the current
`LocalVideoTrack`, changes its camera position, and updates Decart's mirroring
processor. The LiveKit track publication and Room remain in place.

Teardown cancels event tasks, disconnects the manager, clears view bindings,
and stops the caller-owned local track. Stopping the track is required to
release the camera and privacy indicator.

### 6.6 Event value normalization

Swift dictionaries containing optional values do not bridge to Flutter as
predictably as Kotlin maps. `VtonEventDispatcher` converts absent values to
explicit `NSNull` before using the event sink, keeping payloads consistent with
Android.

## 7. Rendering inside Flutter

`VtonRemoteView` and `VtonLocalPreview` both build the internal
`VtonVideoView`. The widget sends only `source`, `fit`, and `mirror` creation
parameters.

On Android, `PlatformViewLink` and `initExpensiveAndroidView` host the native
renderer using hybrid composition. On iOS, `UiKitView` hosts the native
`VideoView`.

Flutter controls layout, clipping, gestures, and surrounding interface. Native
WebRTC code decodes and paints the video. A method or event channel is never in
the per-frame path.

A future rendering optimization could adapt the existing LiveKit track to a
Flutter texture on Android. It should preserve the current Decart/LiveKit
session and replace only the presentation layer. Adding `flutter_webrtc` as a
second media stack is not required and would not make the Decart track directly
compatible with a Flutter texture.

## 8. Wire-contract maintenance

The canonical channel names, methods, event types, and platform-view parameters
are listed in `SPEC.md`. Their implementations are intentionally centralized:

| Layer | Codec location |
| --- | --- |
| Dart | `lib/src/decart_vton_platform.dart` |
| Android | `android/src/main/kotlin/ai/decart/vton/flutter/ChannelCodec.kt` |
| iOS | `ios/decart_vton_flutter/Sources/decart_vton_flutter/ChannelCodec.swift` |

When adding or renaming a field:

1. Update all three codecs in the same change.
2. Update `tool/check_contract.py` if the contract shape changes.
3. Add Dart tests for successful decoding and native-error conversion.
4. Compile both native implementations.

Do not pass native LiveKit, Decart, UIKit, Android View, or raw exception types
through the public Dart API.

## 9. Error handling

Kotlin and Swift expose different native error vocabularies. Each native
controller converts SDK failures to a shared channel-code vocabulary, and Dart
maps that vocabulary to `VtonErrorCode`.

The original native code and message are retained for diagnostics. Unknown
codes degrade to `VtonErrorCode.unknown` instead of becoming decoding failures.

Out-of-band native errors are delivered through the event channel. Android's
SDK provides a dedicated error flow. The iOS SDK mostly throws and also exposes
an error connection state, so the iOS controller synthesizes a generic error
event when that state is reached without a more specific thrown cause.

## 10. Connectivity and networking

`checkConnectivity` performs a throwaway STUN preflight. It does not create a
Decart model session or start the camera. A report may indicate direct UDP,
that TURN would be required, or that no usable WebRTC path was found. A relay
result does not prove that a real TURN session will succeed.

The realtime session still requires signaling over HTTPS/WSS and media access
through the network environment supported by Decart and LiveKit. Restricted
corporate networks should be tested with a real session after preflight.

## 11. Verification workflow

Use the repository scripts rather than running an incomplete subset manually:

```bash
tool/verify.sh --contract   # channel and error vocabulary only
tool/verify.sh --fast       # contract, format, analyze, and tests
tool/verify.sh              # fast checks plus Android build
tool/verify.sh --ios        # also compile iOS on macOS
```

Generate and validate API documentation separately when documentation changes:

```bash
dart doc --validate-links
```

Native builds cannot validate camera ownership, rendering, or reconnection.
Changes in those areas require Android and iOS device tests covering:

1. Connect and display both local and transformed tracks.
2. Apply prompt-only, image-only, and prompt-plus-image updates.
3. Switch front/back cameras without changing session ID.
4. Interrupt and restore network connectivity.
5. Background and foreground the application.
6. Disconnect and confirm that the camera indicator turns off.
7. Test an Android release build with R8 enabled.

## 12. Native SDK upgrade checklist

For an Android or iOS SDK upgrade:

1. Review the upstream release notes and source-level API changes.
2. Compare model identifiers, geometry, and reference-image capability.
3. Check LiveKit and WebRTC dependency changes for type or binary conflicts.
4. Recheck outfit-update routing and whole-state semantics.
5. Recheck error codes and connection-state cases.
6. Compile both native targets with the supported Flutter toolchain.
7. Run contract, Dart, and device tests.
8. Update the pinned versions in build files, README, `SPEC.md`, and this guide
   only after the new baseline passes.

Repository documentation should describe the supported state of the package,
not the temporary steps used to discover or implement it.
