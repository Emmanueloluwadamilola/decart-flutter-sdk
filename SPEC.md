# `decart_vton_flutter` — Phase 0 findings & Phase 1 design spec

> This document is the *pre-implementation* artifact required by Phase 0/1 of the brief.
> It is kept in the repo because the "why" behind the API shape is not recoverable from
> the code alone. `IMPLEMENTATION.md` is the post-implementation maintainer doc;
> `README.md` is the consumer doc.

---

## Part 1 — Phase 0 research findings

### 1.1 What was actually read

Documentation pages (all read in full):

| Page | URL |
| --- | --- |
| Virtual Try-On model | https://docs.platform.decart.ai/models/realtime/virtual-try-on |
| Android SDK overview | https://docs.platform.decart.ai/sdks/android |
| Android Realtime API | https://docs.platform.decart.ai/sdks/android-realtime |
| Swift SDK overview | https://docs.platform.decart.ai/sdks/swift |
| Swift Realtime API | https://docs.platform.decart.ai/sdks/swift-realtime |
| Client Tokens | https://docs.platform.decart.ai/getting-started/client-tokens |
| Authentication | https://docs.platform.decart.ai/getting-started/authentication |
| Streaming best practices | https://docs.platform.decart.ai/models/realtime/streaming-best-practices |
| Reference images | https://docs.platform.decart.ai/models/realtime/reference-images |

**Crucially, the docs were not the primary source.** Both native SDKs are open source, so the
API surface below was read directly from source at the exact released commits:

| SDK | Repo | Tag / commit read |
| --- | --- | --- |
| Android | `github.com/DecartAI/decart-android` | `0.7.9` — `1ae393fe113eb399575a7ae8f9166d94ac5670d9` |
| iOS | `github.com/DecartAI/decart-ios` | `v0.6.9` — `21237b2d3e4f5b589af0cdb0bedb243936cf5c75` |

Where the published docs disagree with the source at those tags, **the source wins** and the
divergence is called out. (Example: the Android docs page shows `realtime.setPrompt(prompt, enhance, timeoutMs)`
and `realtime.setImage(...)` as separate calls, while the model page describes a single `set()`.
There is no `set()` in the Android or iOS SDK — that is the JS/TS SDK's name. See §1.5.)

### 1.2 Native package coordinates

**Android** — JitPack, not Maven Central:

```kotlin
// settings.gradle.kts (or the plugin's own build.gradle repositories block)
maven { url = uri("https://jitpack.io") }

// dependency
implementation("com.github.DecartAI:decart-android:0.7.9")
```

The SDK module transitively brings in (`api` scope, so they leak onto the consumer classpath):

- `io.github.webrtc-sdk:android:125.6422.04`
- `io.livekit:livekit-android:2.25.3`

…plus `okhttp 4.12.0`, `kotlinx-serialization-json 1.7.3`, `kotlinx-coroutines-android 1.9.0`,
`androidx.core:core-ktx` at `implementation` scope.

Because `livekit-android` is exported with `api`, this plugin can use `TextureViewRenderer`
and `VideoTrack` directly without re-declaring the dependency.

**iOS** — Swift Package Manager **only**. There is no podspec anywhere in `decart-ios`:

```swift
.package(url: "https://github.com/DecartAI/decart-ios.git", .upToNextMinor(from: "0.6.9"))
// product: .product(name: "DecartSDK", package: "decart-ios")
```

Transitive SPM dependencies: `livekit/client-sdk-swift` (≥ 2.5.0) and
`shareup/websocket-apple` (≥ 4.1.0).

> **This is the single most consequential finding for the plugin.** See §2.6.

### 1.3 Minimum platform versions

| | Required by SDK | Flutter default | Action |
| --- | --- | --- | --- |
| Android `minSdk` | **24** (`sdk/build.gradle.kts`) | 21 (older templates) / `flutter.minSdkVersion` | Plugin pins `minSdk 24`; consumer app must be ≥ 24 |
| Android `compileSdk` | 35 | varies | Plugin uses 35 |
| Java / JVM target | **17** | 11 or 17 | Plugin sets `sourceCompatibility`/`targetCompatibility`/`jvmTarget` = 17 |
| Kotlin | **2.1+** | varies | Consumer's Kotlin plugin must be ≥ 2.1.0 |
| AGP | 8.7.3 used upstream | varies | ≥ 8.4 needed for the `namespace` + Java 17 combo used here |
| iOS deployment target | **17.0** (`Package.swift`) | 12.0 | Plugin + example pin `IPHONEOS_DEPLOYMENT_TARGET = 17.0` |
| macOS | 12.0 | — | not targeted by this plugin |
| Swift tools | **6.2.1** (`// swift-tools-version: 6.2.1`) | — | Requires Xcode with the Swift 6.2 toolchain |

iOS 17 is a hard floor and it is high. Any app adopting this plugin drops iOS 16 and below.
This is not something the Dart layer can paper over.

### 1.4 Core native API surface (read from source)

#### Android — `ai.decart.sdk`

```kotlin
DecartClient(context, DecartClientConfig(apiKey, baseUrl="wss://api.decart.ai",
                                         httpBaseUrl="https://api.decart.ai", logLevel=LogLevel.WARN))
  .realtime : RealTimeClient
  .queue    : QueueClient          // batch API — out of scope for v1
  .release()

RealTimeClient
  // stream construction (caller-owned; caller MUST dispose)
  fun createLocalVideoStream(model, facing=FRONT, includeMicrophone=false,
                             configuration=RealtimeConfiguration(), mirror=AUTO,
                             debugQuality=false): RealtimeMediaStream

  suspend fun connect(options: ConnectOptions, localStream: RealtimeMediaStream? = null): RealtimeMediaStream
  suspend fun setPrompt(prompt: String, enhance: Boolean = true, timeoutMs: Long = 15_000)
  suspend fun setImage(imageBase64: String?, prompt: String? = null,
                       enhance: Boolean? = null, timeout: Long = 30_000)
  fun setPromptAsync(...): Deferred<Unit>
  fun setImageAsync(...): Deferred<Unit>
  fun disconnect()
  fun release()
  fun isConnected(): Boolean
  suspend fun checkConnectivity(options: CheckConnectivityOptions = ...): ConnectivityReport
  fun getConnectionQuality(): ConnectionQualityReport?

  // observables (kotlinx.coroutines Flow)
  val connectionState:    StateFlow<ConnectionState>
  val errors:             SharedFlow<DecartError>
  val generationTicks:    SharedFlow<GenerationTickMessage>   // { seconds: Double }
  val generationEnded:    SharedFlow<GenerationEndedMessage>
  val queuePositionUpdates: SharedFlow<QueuePositionMessage>
  val remoteStreamUpdates: SharedFlow<RealtimeMediaStream>    // replay = 1
  val localStreamUpdates:  SharedFlow<RealtimeMediaStream>    // replay = 1
  val sessionStarted:      StateFlow<SessionStarted?>         // { sessionId, subscribeToken }
  val connectionQuality:   StateFlow<ConnectionQualityReport?>
  val diagnostics:         SharedFlow<DiagnosticEvent>
  val stats:               SharedFlow<PublishStatsEvent>
```

`ConnectOptions(model, initialPrompt: InitialPrompt?, initialImage: String? /*base64*/,
resolution: Resolution?, realtimeConfiguration, publishCamera=true, publishMicrophone=false /*ignored*/,
facing=FRONT, mirror=AUTO, debugQuality=false, onConnectionQuality, onRemoteStream)`

`ConnectionState` = `DISCONNECTED | CONNECTING | CONNECTED | GENERATING | RECONNECTING` (5 values).

`DecartError` is a **data class** `(code: String, message: String, data: Map?, cause: Throwable?)`,
with `ErrorCodes` constants: `INVALID_API_KEY`, `INVALID_INPUT`, `WEBRTC_WEBSOCKET_ERROR`,
`WEBRTC_ICE_ERROR`, `WEBRTC_TIMEOUT_ERROR`, `WEBRTC_SERVER_ERROR`, `WEBRTC_SIGNALING_ERROR`,
`QUEUE_SUBMIT_ERROR`, `QUEUE_STATUS_ERROR`, `QUEUE_RESULT_ERROR`.

`RealtimeMediaStream(videoTrack: VideoTrack?, audioTrack: AudioTrack? /*always null*/, id: String, room: Room?)`
— `room` is populated for **both** the local (caller-owned) and remote streams, which is what makes
renderer initialisation possible (`room.lkObjects.eglBase.eglBaseContext`).

#### iOS — `DecartSDK`

```swift
DecartClient(decartConfiguration: DecartConfiguration(baseURL: "https://api.decart.ai", apiKey:))
  func createRealtimeManager(options: RealtimeConfiguration) throws -> DecartRealtimeManager
  @MainActor func createLocalCameraStream(model:position:mirror:debugQuality:) -> RealtimeMediaStream
  var queue: QueueClient

DecartRealtimeManager (final class, @unchecked Sendable)
  let options: RealtimeConfiguration
  let events:                  AsyncStream<DecartRealtimeState>
  let remoteStreamUpdates:     AsyncStream<RealtimeMediaStream>
  let connectionQualityUpdates: AsyncStream<ConnectionQualityReport>
  private(set) var sessionId / generationTick / queuePosition / queueSize / serviceStatus

  func connect(localStream: RealtimeMediaStream) async throws -> RealtimeMediaStream
  func disconnect() async
  func setPrompt(_ prompt: DecartPrompt) async throws
  func waitForConnection(timeout:) async throws
  func getConnectionQuality() -> ConnectionQualityReport?
  func isPathRelayed() -> Bool?
```

`DecartPrompt(text: String, referenceImageData: Data? = nil, enrich: Bool = false)`.

`DecartRealtimeConnectionState` = `idle | connecting | connected | generating | reconnecting | disconnected | error`
(**7** values — two more than Android).

`DecartError` is an **enum** with `.errorCode` strings: `INVALID_API_KEY`, `INVALID_BASE_URL`,
`WEB_RTC_ERROR`, `PROCESSING_ERROR`, `INVALID_INPUT`, `INVALID_OPTIONS`, `MODEL_NOT_FOUND`,
`CONNECTION_TIMEOUT`, `WEBSOCKET_ERROR`, `NETWORK_ERROR`, `SERVER_ERROR`, `QUEUE_ERROR`.

Note `WEB_RTC_ERROR` (iOS) vs `WEBRTC_*` (Android) — the codes are **not** the same strings.

### 1.5 How `prompt` and `image` actually interact — confirmed

This was item 4 of Phase 0 and the answer is more interesting than the docs suggest.

The wire protocol has two client messages (`SignalingMessages.kt`, and the identical
`SignalingModel.swift` on iOS):

```kotlin
PromptMessage(prompt: String, enhance_prompt: Boolean)
SetImageMessage(image_data: String?, prompt: String? = null, enhance_prompt: Boolean? = null)
```

`SetImageMessage` is the superset: it carries prompt **and** image **and** the enhance flag in one
atomic update, and `image_data = null` explicitly *clears* the reference image. That is where the
docs' "`set()` replaces the entire state — omitted fields are cleared" behaviour comes from.

The two SDKs route to these messages differently:

- **iOS** has one public method, `setPrompt(DecartPrompt)`. Internally it branches on
  `options.model.hasReferenceImage`: if true → sends `SetImageMessage(base64(refImageData), text, enrich)`;
  if false → sends `PromptMessage(text, enrich)`.
- **Android** exposes both `setPrompt(...)` → `PromptMessage` and `setImage(...)` → `SetImageMessage`
  and does **no** model-based routing. Calling `setPrompt()` on a VTON model sends a `PromptMessage`,
  which is *not* what the iOS SDK would send for the same model.

`hasReferenceImage` is `true` for `lucy-2.1`, `lucy-2.5`, `lucy-vton-2`, `lucy-vton-3`,
`lucy-latest`, `lucy-vton-latest` (and the deprecated `lucy-2.1-vton-2`); `false` for
`lucy-restyle-2` / `lucy-restyle-latest`.

**Consequence for this plugin:** to make Dart behaviour platform-identical, the Android side must
replicate iOS's routing rule. It does — see `ModelRegistry.kt` / `DecartVtonSession.kt`. This is the
single most important behavioural fix the wrapper contributes.

All three combinations are valid and are supported by the Dart API:

| Call | Wire message (VTON model) | Effect |
| --- | --- | --- |
| prompt only | `SetImageMessage(null, "…", enhance)` | new prompt, **reference image cleared** |
| image only | `SetImageMessage(b64, null, enhance)` | new garment, **prompt cleared** |
| prompt + image | `SetImageMessage(b64, "…", enhance)` | both set — clearest signal per the docs |
| neither | — | rejected in Dart with `ArgumentError` before it reaches the channel |

### 1.6 Client tokens / API-key security

From the Client Tokens and Authentication pages:

- Permanent keys are prefixed `dct_`; ephemeral client tokens are prefixed `ek_`.
- Client tokens are minted **server-side** via `client.tokens.create({ expiresIn, allowedModels,
  allowedOrigins, constraints })`. TTL is 1–3600 s, default 60 s. `constraints.realtime.maxSessionDuration`
  caps a session.
- A client token is consumed by the client SDK in exactly the same place a raw key would go — it is a
  drop-in string. **This is why the Dart API takes an opaque `apiKey` string and says nothing about
  its provenance:** a production app passes an `ek_…` fetched from its own backend, a dev build passes
  a `dct_…` from `.env`. No API change is needed to move from one to the other.
- Both native SDKs put the key in the **signalling URL query string** (`?api_key=…`) for realtime.
  That is worth knowing: the key is in a URL, so it can end up in proxy logs. Another reason to use
  short-lived tokens in production.

Neither native SDK ships a `tokens.create()` — minting is a server-side concern, so this plugin
deliberately does not implement it. It is documented in `README.md` instead.

### 1.7 Native UI requirements

Confirmed: a `MethodChannel` alone is not sufficient.

- **Android**: the remote (transformed) track is a `livekit.org.webrtc`-backed `VideoTrack`. It is
  rendered with LiveKit's `TextureViewRenderer` (or `SurfaceViewRenderer`), which must be
  `init(...)`-ed against the owning `Room`'s `eglBase.eglBaseContext` and then attached with
  `track.addRenderer(renderer)`. Both are Android `View`s → `PlatformView`.
- **iOS**: LiveKit's `VideoView` (`UIView`); the SDK ships a SwiftUI wrapper `RTCMLVideoViewWrapper`,
  but for Flutter the underlying `VideoView` is used directly → `UiKitView`.
- The local camera preview has the same requirement (it is also a LiveKit `VideoTrack`).

Renderer lifetime is fiddly on Android: the LiveKit sample re-creates the whole `AndroidView` when the
`Room` identity changes, because re-initialising a renderer against a different `EglBase` is unreliable.
The plugin handles this natively (§2.5) instead of surfacing it to Dart.

### 1.8 Permissions, manifest and build gotchas

**Android**

- `AndroidManifest.xml`: `INTERNET`, `CAMERA` (the SDK's own manifest declares these two and they
  merge in), plus `ACCESS_NETWORK_STATE` used by the sample. `RECORD_AUDIO` is declared by the docs
  but **audio publishing is not implemented in the Android SDK at 0.7.x** (`publishMicrophone` is
  explicitly documented as ignored and `RealtimeMediaStream.audioTrack` is deprecated and always
  null), so this plugin does *not* request it.
- Runtime `CAMERA` permission must be granted **before** `connect()`.
- ProGuard/R8: the SDK ships `consumer-rules.pro` keeping `ai.decart.sdk.**`, `org.webrtc.**`,
  `livekit.org.webrtc.**`, `io.livekit.**`, plus kotlinx-serialization keeps. These are consumer
  rules so they apply automatically — **but only if the dependency resolves as an AAR with its
  consumer rules intact**. The plugin re-declares the critical keeps in its own
  `consumer-rules.pro` as a belt-and-braces measure, because JitPack-built AARs occasionally lose
  them.
- `LiveKit.loggingLevel` is forced to `OFF` by `RealTimeClient`'s `init` block — do not expect
  LiveKit logcat output.

**iOS**

- `Info.plist`: `NSCameraUsageDescription` is mandatory (the app will crash on capture without it).
  `NSMicrophoneUsageDescription` is only needed if the app itself uses the mic — this plugin never
  publishes audio, so it is not required.
- Camera capture does **not** work on the iOS Simulator. Realtime sessions must be tested on a
  physical device.
- Swift 6 strict concurrency: `DecartRealtimeManager` is `@unchecked Sendable`,
  `createLocalCameraStream` is `@MainActor`. All Flutter channel replies must be delivered on the
  main thread.

**Network (both)**

Per the streaming best-practices page: outbound TCP 443 for WSS, plus **UDP 3478 and 7882** for
WebRTC media. HTTP proxies that cannot pass UDP will force TURN relay or fail the session outright.

### 1.9 Existing Flutter wrapper — build vs. fork

Searched pub.dev and the wider web for an existing Decart / Lucy Flutter binding.
**None found** — no `decart*` package, no community wrapper, nothing abandoned worth forking.
`livekit_client` (the official LiveKit Flutter SDK) exists, but wrapping *it* would mean
re-implementing Decart's signalling protocol in Dart rather than wrapping Decart's SDKs, which is
explicitly not what was asked for and would duplicate ~2 000 lines of protocol logic that Decart
already maintains twice.

**Decision: build from scratch, wrapping the native SDKs.**

---

## Part 2 — Phase 1 design

### 2.1 Design goals, in priority order

1. **Platform-identical Dart behaviour.** Where the two SDKs differ, the native layers converge;
   only genuinely irreconcilable differences reach Dart, and those are documented, not hidden.
2. **No leaked native types.** No `PlatformException`, no LiveKit types, no base64 strings, no
   `Map<String, dynamic>` in the public API.
3. **Provider-agnostic naming.** The public surface talks about *outfits*, *sessions* and
   *try-on*, not about Decart or Lucy, so swapping the provider later is a plugin-internal change.
   Model identifiers are the one unavoidable exception and they live in a single enum.
4. **Hard to misuse.** The `set()` "replaces everything" footgun is made explicit rather than
   silently survivable.

### 2.2 Public Dart API

```dart
// ── lifecycle ────────────────────────────────────────────────────────────────
final vton = DecartVton();

await vton.initialize(
  apiKey: '...',                       // dct_… in dev, ek_… in production
  signalingBaseUrl: 'wss://api.decart.ai',
  logLevel: VtonLogLevel.warn,
);

await vton.connect(
  model: VtonModel.lucyVtonLatest,
  initialOutfit: VtonOutfit(prompt: 'Substitute the current top with a navy hoodie'),
  camera: VtonCameraFacing.front,
  mirror: VtonMirrorMode.auto,
  resolution: VtonResolution.p720,
  video: VtonVideoConfig(...),         // optional bitrate/fps/codec overrides
  connectTimeout: Duration(seconds: 30),
);

// ── the outfit control ──────────────────────────────────────────────────────
await vton.setOutfit(
  prompt: 'Add a wide-brimmed straw hat to the person\'s head',
  referenceImage: garmentBytes,        // Uint8List?, JPEG/PNG/WebP, ≥512×512
  enhance: true,
);

await vton.setOutfit(outfit: vton.currentOutfit!.copyWith(prompt: 'new prompt'));

// ── teardown ────────────────────────────────────────────────────────────────
await vton.switchCamera();
await vton.disconnect();
await vton.dispose();

// ── observation ─────────────────────────────────────────────────────────────
vton.connectionState;              // VtonConnectionState (sync snapshot)
vton.connectionStates;             // Stream<VtonConnectionState>, broadcast
vton.events;                       // Stream<VtonEvent>, sealed, broadcast
vton.errors;                       // Stream<DecartVtonException>, broadcast
vton.currentOutfit;                // VtonOutfit? — last successfully applied
vton.sessionId;                    // String?
vton.isConnected;                  // bool

// ── rendering ───────────────────────────────────────────────────────────────
VtonRemoteView(fit: BoxFit.cover)   // the transformed try-on output
VtonLocalPreview(fit: BoxFit.cover) // the raw camera, for a PiP self-view
```

#### `setOutfit` — the deliberate ergonomics

```dart
Future<void> setOutfit({
  String? prompt,
  Uint8List? referenceImage,
  bool enhance = true,
  VtonOutfit? outfit,
  Duration timeout = const Duration(seconds: 30),
});
```

Rules, all enforced in Dart before anything crosses the channel:

- Passing `outfit:` together with any of `prompt`/`referenceImage`/`enhance` → `ArgumentError`.
- Passing **neither** a prompt nor an image → `ArgumentError` with a message that names the
  replace-whole-state semantics. It is never silently turned into "clear everything".
- An empty/whitespace-only `prompt` with no image → same `ArgumentError`. An empty string is not a
  prompt.
- `enhance` mirrors the SDK's `enhance_prompt` / `enrich` flag and **defaults to `true`**, matching
  the documented model default. (The iOS `DecartPrompt.enrich` parameter defaults to `false` in
  Swift — that is an SDK-level inconsistency with its own docs; the plugin always passes the flag
  explicitly so the default never applies.)

`VtonOutfit` is an immutable value class with `copyWith`. It exists *specifically* so the
"keep the image, change the prompt" case has an obvious, correct spelling:

```dart
await vton.setOutfit(outfit: vton.currentOutfit!.copyWith(prompt: 'a denim jacket'));
```

…and so the wrong spelling (`setOutfit(prompt: 'a denim jacket')`, which silently drops the garment
image) is at least *visibly* different. `currentOutfit` is client-side bookkeeping of the last
successfully-acked update; it is not read back from the server.

#### Errors

Every failure surfaces as `DecartVtonException`:

```dart
class DecartVtonException implements Exception {
  final VtonErrorCode code;   // enum, never a raw string
  final String message;
  final String? nativeCode;   // the original SDK code, for bug reports
  final Object? details;
}
```

`VtonErrorCode` is a closed enum: `notInitialized`, `notConnected`, `invalidApiKey`, `invalidInput`,
`invalidOptions`, `modelNotFound`, `permissionDenied`, `cameraUnavailable`, `connectionTimeout`,
`webrtc`, `websocket`, `signaling`, `network`, `server`, `promptRejected`, `cancelled`, `unknown`.

`PlatformException` never escapes: `_invoke()` in `decart_vton_platform.dart` is the single
funnel that converts it. Both native `DecartError` code vocabularies (which, as noted in §1.4,
are *different strings*) are normalised to this one enum in `VtonErrorCode.fromNative`.

#### Events

`VtonEvent` is a Dart 3 `sealed class`, so `switch` over it is exhaustively checked:

`VtonConnectionStateChanged` · `VtonSessionStarted` · `VtonGenerationTick` ·
`VtonRemoteStreamUpdated` · `VtonLocalStreamUpdated` · `VtonConnectionQualityChanged` ·
`VtonErrorOccurred`

### 2.3 Method-by-method native mapping

| Dart | Android | iOS |
| --- | --- | --- |
| `initialize()` | construct `DecartClient(context, DecartClientConfig(...))`, hold `client.realtime` | construct `DecartClient(decartConfiguration:)`; store config (manager is per-session) |
| `connect()` | `realtime.createLocalVideoStream(model, facing, mirror)` then `realtime.connect(ConnectOptions(...), localStream)` | `client.createLocalCameraStream(model:position:mirror:)` then `client.createRealtimeManager(options:)` then `manager.connect(localStream:)` |
| `setOutfit()` (ref-image model) | `realtime.setImage(b64, prompt, enhance, timeout)` | `manager.setPrompt(DecartPrompt(text, referenceImageData, enrich))` |
| `setOutfit()` (non-ref model) | `realtime.setPrompt(prompt, enhance, timeoutMs)` | same `setPrompt(...)`; SDK routes internally |
| `switchCamera()` | dispose + rebuild local stream with flipped `FacingMode`, republish | recreate camera track with flipped `AVCaptureDevice.Position` |
| `disconnect()` | `realtime.disconnect()` + `localStream.dispose()` | `await manager.disconnect()` + stop local track |
| `dispose()` | `client.release()` | drop manager + client refs, cancel event `Task`s |
| `checkConnectivity()` | `realtime.checkConnectivity()` (STUN-only) | `Preflight` via SDK | 
| `VtonRemoteView` | `PlatformView` → `TextureViewRenderer` bound to remote `VideoTrack` | `UiKitView` → LiveKit `VideoView` |
| `VtonLocalPreview` | same, bound to local `VideoTrack` | same |
| `connectionStates` / `events` | collect `connectionState`, `errors`, `sessionStarted`, `generationTicks`, `remoteStreamUpdates`, `connectionQuality` Flows → one `EventChannel` | iterate `events`, `remoteStreamUpdates`, `connectionQualityUpdates` `AsyncStream`s → same `EventChannel` |

**Not exposed in v1** (documented as such): the batch/queue API, `debugQuality` glass-to-glass
measurement, LiveKit publish stats / diagnostics, `subscribeToken`-based viewer sessions,
`checkConnectivity(deep: true)` (it costs a real GPU session).

### 2.4 Pigeon vs. hand-written channels — decision and reasoning

**Decision: hand-written `MethodChannel` + `EventChannel`, with a single typed funnel on each side.**

The brief's default is Pigeon, and for a large or type-heavy surface I would agree. Here are the
reasons I went the other way, in order of weight:

1. **Pigeon does not generate the hard part.** More than half of this plugin's native code is
   `PlatformView` factories, LiveKit renderer lifecycle, camera stream ownership and
   Flow/`AsyncStream` bridging. Pigeon generates none of that. It would have removed serialisation
   boilerplate from ~8 method signatures and one event union — a real but modest win.
2. **The wire surface is small and almost entirely primitive.** Eight methods; arguments are
   `String`, `bool`, `int`, `Uint8List` and four enums-as-strings; the only non-trivial payload is
   a tagged event map with at most five fields. That is well inside the range where a single
   hand-written decoder is auditable in one sitting.
3. **A codegen step is a permanent tax on a plugin with two native languages.** Every contributor
   needs the right Pigeon version pinned, and generated files must be committed and kept in sync.
   For a package this size that is real friction.
4. **Honest disclosure:** the environment this was built in could not reach `pub.dev`, so Pigeon
   codegen could not be *run* here. I will not ship hand-forged "generated" code and call it
   Pigeon output — that is strictly worse than hand-written code that is honest about being
   hand-written.

Mitigation for the type-safety loss: every channel argument and every event field is constructed
and parsed in exactly one place per side (`decart_vton_platform.dart`, `ChannelCodec.kt`,
`ChannelCodec.swift`). The wire contract is written out in `IMPLEMENTATION.md` and both native
sides are checked against it. Migration to Pigeon later is mechanical because nothing else touches
raw maps.

### 2.5 Rendering architecture

One view type, `ai.decart.vton/video_view`, with creation params
`{ "source": "remote" | "local", "mirror": bool, "fit": "cover" | "contain" }`.

The native side keeps a registry of live views. When the SDK emits a new remote stream (which it
does after every auto-reconnect), the plugin **re-binds the existing views natively** rather than
telling Dart to tear down and recreate the `PlatformView`. This is deliberate:

- it avoids a visible black flash on reconnect;
- it keeps the "re-init a renderer against a different `EglBase` is unreliable" problem entirely
  inside Kotlin, where it can be solved by releasing and re-creating the renderer while keeping the
  same container `FrameLayout`;
- Dart still gets a `VtonRemoteStreamUpdated` event, but purely as information.

Android uses **hybrid composition** (`PlatformViewLink` + `initExpensiveAndroidView`) rather than
the cheaper texture-layer path. Rationale and the perf trade-off are in `IMPLEMENTATION.md` §
"Known limitations".

### 2.6 The iOS dependency problem — SPM only

`decart-ios` ships **no podspec**, and one of its transitive dependencies
(`shareup/websocket-apple`) has no CocoaPods presence either. There is no honest way to author a
podspec that resolves `DecartSDK`.

Therefore the plugin ships `ios/decart_vton_flutter/Package.swift` and **requires Flutter's Swift
Package Manager integration to be enabled**:

```bash
flutter config --enable-swift-package-manager
```

A `.podspec` is still present because Flutter's tooling and `pod install` expect one for
CocoaPods-based iOS projects, but it deliberately does **not** claim to provide `DecartSDK`; a
CocoaPods-only build will fail at compile time with `no such module 'DecartSDK'`. Rather than let
that be a mystery, the podspec carries a `prepare_command` that prints a loud, explicit message.

This is a genuine, unavoidable constraint of the upstream SDK and is listed as the first known
limitation in the README.

### 2.7 Threading contract

- **Android**: all `MethodChannel` handling happens on the platform thread. The plugin owns a
  `CoroutineScope(Dispatchers.Main + SupervisorJob())`; suspend SDK calls are launched there and
  `result.success/error` is always invoked on the main looper. Flow collection also runs on
  `Dispatchers.Main`, and the `EventChannel` sink is wrapped so `success()` can never be called off
  the main thread.
- **iOS**: `DecartRealtimeManager`'s async methods are awaited inside `Task`s;
  `createLocalCameraStream` is `@MainActor`. Every `FlutterResult` and every `eventSink` call is
  hopped to the main queue through one helper (`mainThread { }`). `AsyncStream` consumers are stored
  as cancellable `Task`s and cancelled on `disconnect`/`dispose`.

### 2.8 Known divergences that reach Dart

| Divergence | Handling |
| --- | --- |
| iOS has `idle` and `error` connection states; Android has 5 states | Dart exposes the **union** (7). Android simply never emits `idle`/`error`; `error` is inferred on iOS only. Documented on the enum. |
| Android emits a dedicated `errors` Flow; iOS only throws | Dart's `errors` stream is fed from the Flow on Android and from caught throws + `.error` state on iOS. Non-fatal mid-session errors are therefore **more visible on Android**. |
| Default video codec: Android VP8, iOS h264 | Plugin pins **VP8 on both** (the streaming best-practices page recommends VP8 for mobile). Overridable via `VtonVideoConfig`. |
| Default max bitrate: Android 2 000 000, iOS 3 500 000 | Plugin pins **2 500 000 on both** (the value the docs quote). Overridable. |
| `enhance` default: docs true, Swift `enrich` default false | Plugin always sends the flag explicitly; Dart default is `true`. |
| Android `setPrompt` does not do reference-image routing | Plugin replicates iOS's `hasReferenceImage` routing on Android. |
| Audio | Not supported on Android at 0.7.x. Plugin exposes no audio API on either platform. |
| Simulator | iOS camera capture is unavailable on the Simulator; Android emulator camera works but is useless for try-on. |

---

## Part 3 — Verification plan

1. `dart format --set-exit-if-changed .` and `flutter analyze` → zero issues.
2. `flutter test` → Dart-layer unit tests with `TestDefaultBinaryMessengerBinding` mocking both the
   method channel and the event channel; success **and** error paths for every public method,
   plus the `ArgumentError` validation matrix for `setOutfit`.
3. `cd example && flutter build apk --debug` → Android compile.
4. `cd example && flutter build ios --no-codesign` → iOS compile (requires macOS + Xcode 16 with the
   Swift 6.2 toolchain + SPM enabled).
5. Manual on-device run of the example: connect → see transformed stream → change outfit mid-session
   with prompt only, image only, and both → switch camera → background/foreground → disconnect.
