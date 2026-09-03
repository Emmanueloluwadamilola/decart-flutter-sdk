# IMPLEMENTATION.md — how `decart_vton_flutter` works and why

This is the maintainer document. `README.md` tells you how to *use* the package;
this one tells you how it is built, what the native SDKs actually do, and which
decisions were judgement calls you may want to revisit. `SPEC.md` is the
pre-implementation artefact — raw Phase 0 findings and the Phase 1 design — and
is still worth reading first if you are picking this up cold.

---

## 1. What this wraps, and why a wrapper was needed

[Decart](https://platform.decart.ai) runs realtime generative video models. The
*Lucy VTON* family does virtual try-on: you stream live camera video in, and you
get the same video back with the person wearing different clothes, at roughly
30 fps with sub-second latency.

It is not a request/response API. A session is:

1. Open a WebSocket to `wss://api.decart.ai/v1/stream?api_key=…&model=…`.
2. Exchange signalling; the server hands back a **LiveKit** room URL and token.
3. Publish the device camera into that room over WebRTC.
4. Subscribe to the transformed track coming back.
5. Send `prompt` / `set_image` messages over the WebSocket to change the outfit
   live, and get an ack per change.

Decart maintains SDKs for JS, Python, Kotlin and Swift. **There is no Flutter
SDK, and pub.dev has no community wrapper** (checked before starting; see
`SPEC.md` §1.9). Reimplementing the protocol in Dart would mean duplicating
~2 000 lines of signalling, reconnect and quality-measurement logic that Decart
already maintains twice — so this package binds the native SDKs instead.

**Versions wrapped, pinned deliberately:**

| SDK | Coordinate | Version | Commit |
| --- | --- | --- | --- |
| Android | `com.github.DecartAI:decart-android` (JitPack) | `0.7.9` | `1ae393fe113eb399575a7ae8f9166d94ac5670d9` |
| iOS | `github.com/DecartAI/decart-ios` (SPM) | `v0.6.9` | `21237b2d3e4f5b589af0cdb0bedb243936cf5c75` |

Everything in this document was read from those two commits, not from the docs
site. Where the published docs and the source disagree, the source is what the
code targets, and the disagreement is called out.

---

## 2. Phase 0 findings that shaped the design

The full research write-up is in `SPEC.md` Part 1. The four findings that
actually changed the code:

### 2.1 The two SDKs disagree about how to change an outfit

This is the most important thing in this document.

There are two client messages on the wire (`SignalingMessages.kt`,
`SignalingModel.swift` — identical shapes):

```
prompt     { prompt: String,          enhance_prompt: Bool }
set_image  { image_data: String?,     prompt: String?, enhance_prompt: Bool? }
```

`set_image` is the superset — it carries prompt *and* image *and* the enhance
flag atomically, and `image_data: null` **explicitly clears** any previous
reference image. That is the mechanism behind the docs' "`set()` replaces the
entire state" line.

The routing differs:

- **iOS** has one method, `setPrompt(DecartPrompt)`. It branches on
  `options.model.hasReferenceImage`: true → `set_image`, false → `prompt`.
- **Android** has two methods, `setPrompt(...)` → `prompt` and `setImage(...)` →
  `set_image`, and does **no** model-based routing at all.

So the same Dart call, naively forwarded, would produce *different wire traffic*
per platform. Concretely: after setting a garment image, a prompt-only update
would clear the garment on iOS and keep it on Android.

**This plugin replicates iOS's routing rule on Android.** `VtonSessionController.kt`
branches on `supportsReferenceImage` (supplied by the Dart `VtonModel` enum) and
calls `setImage(...)` for reference-image models even when there is no image.
That single branch is the largest single piece of value this wrapper adds over
calling the SDKs directly.

`hasReferenceImage` is `true` for `lucy-2.1`, `lucy-2.5`, `lucy-vton-2`,
`lucy-vton-3`, `lucy-latest`, `lucy-vton-latest`; `false` for `lucy-restyle-2`
and `lucy-restyle-latest`.

> Note the docs describe a single `set()` method. There is no `set()` in either
> native SDK — that is the JS/TS SDK's name. Do not go looking for it.

### 2.2 Both remote and local streams carry their LiveKit `Room`

On Android, `RealtimeMediaStream` exposes `room: Room?`, populated for the
SDK-created remote stream (`LiveKitMediaChannel.kt:327`) and for caller-created
local streams (`LocalStreamFactory.kt:59`). This matters because a
`TextureViewRenderer` must be `init`-ed against `room.lkObjects.eglBase.eglBaseContext`.
Without it there would be no way to render at all from a plugin.

### 2.3 iOS is SPM-only, and that is load-bearing

`decart-ios` has no podspec anywhere in the repo, and `shareup/websocket-apple`
has no CocoaPods presence. There is no honest podspec to write. The plugin
therefore ships `ios/decart_vton_flutter/Package.swift` and requires
`flutter config --enable-swift-package-manager`. The podspec that *is* present
carries no sources and prints an explanatory banner from `prepare_command`,
because "no such module 'DecartSDK'" with no context is a bad afternoon.

### 2.4 Defaults differ between the platforms in ways users would feel

| | Android 0.7.9 | iOS v0.6.9 | Plugin |
| --- | --- | --- | --- |
| Preferred codec | `vp8` | `h264` | **`vp8`** (recommended for mobile by Decart's streaming guide) |
| Max bitrate | 2 000 000 | 3 500 000 | **2 500 000** (the figure the docs quote) |
| `enhance` / `enrich` default | `true` | `false` | **always sent explicitly**, Dart default `true` |
| Connection states | 5 | 7 | union of 7 |
| Error code vocabulary | `WEBRTC_ICE_ERROR`, … | `WEB_RTC_ERROR`, … | normalised to one Dart enum |
| Log level control | `LogLevel` enum, 4 cases | none (env var only) | Android only, documented |

Leaving these alone would have meant identical Dart code producing measurably
different video on the two platforms.

---

## 3. API design decisions

### 3.1 Shape of the Dart surface

`DecartVton` is a **singleton**. Each native side holds one client and one
session, so pretending otherwise would be a lie the first time someone made two
controllers. It also means `VtonRemoteView` needs no controller threading
through the widget tree — the native view registry finds the current track by
itself.

The public vocabulary is **provider-agnostic**: *outfit*, *session*, *try-on*.
The word "Decart" appears in `DecartVton` and `DecartVtonException` and nowhere
else in the API surface; model identifiers are confined to one enum. Swapping
providers later is a plugin-internal change, not a consumer-code change.

### 3.2 `setOutfit` — designing around the footgun

The whole-state-replace semantics of the underlying API is the number-one source
of confusion in Decart's own docs (they flag it twice). Three deliberate choices:

1. **`VtonOutfit` is a value class with `copyWith`.** The correct spelling of
   "change one field" is short and obvious:
   `setOutfit(outfit: currentOutfit!.copyWith(prompt: …))`. The wrong spelling
   (`setOutfit(prompt: …)`) is visibly different, and it is *legal* — sometimes
   dropping the garment is exactly what you want.
2. **`currentOutfit` tracks the last successfully-applied state**, updated only
   after the platform call resolves. It is client-side bookkeeping, not a read
   from the server, and is documented as such.
3. **An empty update throws `ArgumentError` in Dart**, before anything crosses
   the channel. Sending `set_image(null, null)` would silently clear the entire
   effect; that is never what someone typing `setOutfit()` meant. Blank/whitespace
   prompts count as absent.

Mixing `outfit:` with `prompt:`/`referenceImage:`/`referenceImagePath:` also
throws — there is no sensible precedence rule, so there is no rule.

### 3.3 Errors

One exception type, `DecartVtonException`, with a closed `VtonErrorCode` enum,
the original `nativeCode` string, and optional `details`.
`PlatformException` never escapes: `DecartVtonPlatform._invoke` is the single
funnel that converts it, and `VtonErrorCode.fromNative` is the single table that
knows both platforms' vocabularies.

`ArgumentError` is used — deliberately — for argument-shape violations. Those
are programming errors that should fail loudly in development, not runtime
conditions to be caught and displayed.

### 3.4 Pigeon vs. hand-written channels

**Hand-written `MethodChannel` + `EventChannel`.** The brief's default is
Pigeon; here is the honest reasoning for going the other way, heaviest first:

1. **Pigeon does not generate the hard part.** More than half of the native code
   is platform-view factories, renderer lifecycle, camera stream ownership and
   `Flow`/`AsyncStream` bridging. Pigeon generates none of that. It would have
   removed serialisation boilerplate from eight method signatures and one event
   union — real, but modest.
2. **The wire surface is small and nearly all primitive.** Seven methods;
   arguments are `String`, `bool`, `int`, `Uint8List` and four
   enums-as-strings; the only structured payload is a tagged event map with at
   most five fields.
3. **Codegen is a permanent tax** on a plugin with two native languages —
   pinned tool version, committed generated files, sync discipline.
4. **Disclosure:** the environment this was built in could not reach `pub.dev`,
   so Pigeon codegen could not be run. Hand-forging files that *look* generated
   and calling them Pigeon output would be strictly worse than hand-written code
   that is honest about being hand-written.

Mitigation for the lost type safety: every argument and event field is built and
parsed in **exactly one place per side** — `decart_vton_platform.dart`,
`ChannelCodec.kt`, `ChannelCodec.swift`. Nothing else touches raw maps, so a
future Pigeon migration is mechanical: replace those three files and the wire
contract below.

---

## 4. The wire contract

Method channel: `ai.decart.vton/methods`.
Event channel: `ai.decart.vton/events`.
Platform view type: `ai.decart.vton/video_view`.

### Methods

| Method | Arguments | Reply |
| --- | --- | --- |
| `initialize` | `apiKey: String`, `signalingBaseUrl: String`, `httpBaseUrl: String`, `logLevel: String` | `null` |
| `connect` | `model: String`, `width: int`, `height: int`, `fps: int`, `supportsReferenceImage: bool`, `facing: "front"\|"back"`, `mirror: "off"\|"on"\|"auto"`, `resolution: "720p"\|"1080p"\|null`, `connectTimeoutMs: int`, `video: {maxBitrate, maxFramerate, preferredCodec, simulcast}`, `prompt: String?`, `referenceImage: Uint8List?`, `referenceImagePath: String?`, `enhance: bool` | `{sessionId: String?}` |
| `setOutfit` | `prompt: String?`, `referenceImage: Uint8List?`, `referenceImagePath: String?`, `enhance: bool`, `timeoutMs: int` | `null` |
| `switchCamera` | `facing: "front"\|"back"` | `{facing: "front"\|"back"}` |
| `disconnect` | — | `null` |
| `release` | — | `null` |
| `isConnected` | — | `bool` |
| `checkConnectivity` | `timeoutMs: int` | `{quality: String, transport: String, roundTripMs: int?}` |

Errors are returned as `result.error(code, message, null)` where `code` is one
of the strings in `ErrorCodes` (Kotlin) / `ErrorCodes` (Swift). Those two sets
are identical by design so `VtonErrorCode.fromNative` needs one table.

### Events

Every payload is a map with a `type` key.

| `type` | Fields |
| --- | --- |
| `connectionState` | `state: "idle"\|"connecting"\|"connected"\|"generating"\|"reconnecting"\|"disconnected"\|"error"` |
| `sessionStarted` | `sessionId: String`, `subscribeToken: String?` |
| `generationTick` | `seconds: double` |
| `remoteStreamUpdated` | — |
| `localStreamUpdated` | — |
| `connectionQuality` | `quality: String`, `roundTripMs: int?`, `packetLoss: double?`, `jitterMs: int?` |
| `error` | `code: String`, `message: String`, `details: Object?` |

Unrecognised `type` values are **dropped** on the Dart side, not thrown on, so a
newer native layer never breaks an older Dart layer.

### Platform-view creation params

`{ source: "remote"|"local", fit: "cover"|"contain", mirror: bool }`

---

## 5. Android internals, file by file

`android/src/main/kotlin/ai/decart/vton/flutter/`

### `DecartVtonPlugin.kt`

The `FlutterPlugin` + `MethodCallHandler`. Deliberately thin: decode, delegate,
reply. Owns a `CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())`.

Every call is dispatched into that scope, so suspending SDK functions resume on
the main thread and `MethodChannel.Result` is only ever touched there — calling
it off the platform thread is a hard crash in the Flutter embedding.
`CancellationException` is rethrown rather than converted, because replying on a
cancelled scope during engine detach is a use-after-free on the messenger.

`onDetachedFromEngine` releases native resources **before** tearing down the
channels. A leaked LiveKit `Room` survives a Dart hot restart and keeps the
camera claimed with nothing driving it.

### `VtonSessionController.kt`

All the state: `DecartClient`, `RealTimeClient`, the local and remote
`RealtimeMediaStream`s, the current model, and the list of `Flow` collector
`Job`s.

- **`initialize`** builds `DecartClient` and immediately starts collecting all
  seven observable flows. Collection starts here rather than at `connect` so the
  `CONNECTING` transition is not missed.
- **`connect`** checks `CAMERA` permission first (fail fast with a legible code
  rather than a mystery WebRTC timeout twelve seconds later), then creates the
  local stream *before* calling `connect(..., localStream = ...)`. That ordering
  is what the SDK recommends and is what makes the preview and the publisher
  share one LiveKit `Room` — which in turn is what gives `VtonLocalPreview` an
  `EglBase` to render against. If the handshake throws, the local stream is
  disposed before rethrowing so a failed connect never leaves the camera on.
- **`setOutfit`** is where the §2.1 routing lives. Byte-backed images retain
  the original API. File-backed images are read on `Dispatchers.IO` and streamed
  directly into Android's Base64 encoder, avoiding a second raw-image buffer.
- **`teardownStreams`** disposes the caller-owned local stream. The SDK is
  explicit that failing to do so leaks the underlying `Room` and its native
  resources. The remote stream is SDK-owned, so it is only dereferenced.

### `VtonVideoPlatformView.kt`

Three things: `VtonVideoSource` (an enum), `VtonVideoViewRegistry`,
`VtonVideoViewFactory` and `VtonVideoPlatformView`.

The registry holds every live view and **rebinds them natively** when a new
stream arrives. This is the design decision worth understanding: the SDK emits a
fresh `RealtimeMediaStream` after every automatic reconnect (up to five
retries). Routing that through Dart would mean destroying and recreating a
platform view — a visible black flash plus dropped frames — for something Kotlin
can fix in place.

The view itself is a `FrameLayout` **wrapper** around a `TextureViewRenderer`,
not the renderer directly. The wrapper exists so the renderer can be released
and recreated when the owning `Room` changes, without the platform view going
away. Re-`init`-ing a renderer against a different `EglBase` is not reliable —
the LiveKit sample sidesteps it by recreating the whole composable via
`key(room)`, and this is the equivalent for a platform view.

### `VtonEventDispatcher.kt`

`EventChannel.StreamHandler` with two jobs: hop every emission to the main
looper (`EventSink.success` off the platform thread is an intermittent crash
under load), and **buffer up to 64 events** emitted before Dart subscribes.
Without the buffer, the first `connectionState` emission is lost and Dart starts
with a stale view of the world.

### `ChannelCodec.kt`

The wire format, and nothing else. Note `realtimeModel(args)` **constructs** a
`RealtimeModel` from the payload rather than looking it up in the SDK's
`RealtimeModels` registry: the Dart `VtonModel` enum is the single source of
truth for geometry, so adding a model is one Dart edit rather than three.

### `Errors.kt`

`ErrorCodes` (shared string vocabulary with Swift), `VtonPluginException`, and
`Throwable.toChannelError()`.

The SDK signals most failures with plain `Exception`s carrying human-readable
messages ("Not connected", "Prompt send timed out", "Failed to send image"), so
some message sniffing is unavoidable. Every branch is derived from a literal
that exists at 0.7.9, and each is commented with where. When those strings
change the worst case is a demotion to `UNKNOWN`, with the original message
still intact on the Dart side — degradation, not breakage.

---

## 6. iOS internals, file by file

`ios/decart_vton_flutter/Sources/decart_vton_flutter/`

The structure intentionally mirrors Android's, file for file, so a change on one
side has an obvious counterpart on the other.

### `DecartVtonPlugin.swift`

`FlutterPlugin`. `register(with:)` uses `MainActor.assumeIsolated` — plugin
registration runs on the platform thread during engine startup, and asserting
that is better than deferring registration past the first Dart call.

`handle(_:result:)` wraps the work in `Task { @MainActor in … }`, which is what
guarantees `FlutterResult` is invoked on the main thread.

`detachFromEngine` releases the session, for the same hot-restart reason as
Android.

### `VtonSessionController.swift`

The whole class is `@MainActor`. `createLocalCameraStream` is already
main-actor-isolated, `VideoView` is UIKit, and `FlutterResult` must be on the
main thread — pinning to the main actor removes a category of Swift 6 strict-
concurrency errors and a category of runtime crashes at once. The SDK's
`connect`/`setPrompt` do their real work off the main actor internally, so this
does not serialise the network path.

Two iOS-specific wrinkles:

- **`DecartConfiguration.init` calls `fatalError()`** on an empty API key or an
  unparseable base URL. The controller validates both *before* constructing it —
  a bad argument from Dart must not take the whole app down.
- **The manager is per-session, not per-client.** `createRealtimeManager` bakes
  the model and initial prompt in, so event tasks start at `connect`, not at
  `initialize`. Because of that, `connecting` would never be observed (the
  manager does not exist yet), so the controller emits it manually.
- **The event stream is a state snapshot**, `AsyncStream<DecartRealtimeState>`,
  not discrete events. The controller diffs successive snapshots against
  `lastConnectionState` / `lastSessionId` / `lastTick` to produce the discrete
  events the wire contract specifies.
- **File-backed reference images use memory-mapped `Data`.** Only the path
  crosses the channel; Swift validates the file and uses `.mappedIfSafe` before
  handing normal `Data` to `DecartPrompt`.

`ensureCameraAuthorised()` mirrors Android's permission pre-check, and
distinguishes `.notDetermined` from `.denied` in the message because the fixes
differ.

`teardownSession()` stops the caller-owned `LocalVideoTrack`. The SDK hands the
track over and does not stop it; leaving it running holds the capture device and
keeps the green privacy indicator lit.

### `VtonVideoPlatformView.swift`

Same registry pattern as Android, but simpler: LiveKit's `VideoView` owns its
renderer lifecycle, so binding is a single `videoView.track = …` assignment.

The registry uses `NSHashTable.weakObjects()`. `FlutterPlatformView` has no
`dispose` hook (unlike Android's `PlatformView.dispose`), and unregistering from
`deinit` would mean escaping `self` out of a deinitialiser into a `@MainActor`
hop, which is undefined behaviour. A weak table sidesteps the problem entirely.

### `VtonEventDispatcher.swift`

Same two jobs as Kotlin's, plus one extra: `normalise()` converts
`[String: Any?]` to `[String: Any]` with explicit `NSNull`, because Swift's
double-optional bridging is inconsistent and Android's Kotlin maps encode nulls
cleanly. Without it the two platforms would put subtly different payloads on the
same channel.

### `ChannelCodec.swift` / `Errors.swift`

Direct counterparts of the Kotlin files. `Errors.swift` maps iOS's
`WEB_RTC_ERROR` onto the shared `WEBRTC_ERROR` spelling so the Dart table stays
single-vocabulary.

---

## 7. Behavioural divergence between platforms

What the Dart layer papers over, and what it cannot.

### 7.1 Papered over

| Divergence | How |
| --- | --- |
| Outfit-update routing (§2.1) | Android replicates iOS's `hasReferenceImage` rule. |
| Codec and bitrate defaults | Both pinned to vp8 / 2.5 Mbps in `VtonVideoConfig`. |
| `enhance` default | Always sent explicitly; neither SDK's default applies. |
| Error-code vocabulary | Both normalised into `VtonErrorCode`. |
| Camera permission failure mode | Both pre-check and fail with `permissionDenied`. |
| Stream rebinding on reconnect | Both handled natively, invisible to Dart. |

### 7.2 Surfaced, because it cannot be hidden

| Divergence | Consequence |
| --- | --- |
| iOS has `idle` and `error` states; Android has neither | Dart exposes the 7-state union; Android simply never emits those two. Documented on the enum. |
| Android has an `errors` `SharedFlow`; iOS mostly throws | `DecartVton.errors` is chattier on Android. Documented on the getter — quiet is not the same as healthy. |
| `subscribeToken` is Android-only | `VtonSessionStarted.subscribeToken` is `null` on iOS. |
| `logLevel` is Android-only | Ignored on iOS; documented on `VtonLogLevel`. |
| `signalingBaseUrl` is Android-only | `DecartConfiguration` takes one base URL and derives `wss://` from it. Ignored on iOS; documented on `initialize`. |
| iOS has no error flow, only an `error` state | The Swift controller synthesises a `type: "error"` event on the transition to `.error`, so `DecartVton.errors` is not permanently silent on iOS — but it carries no specific cause, because the SDK does not provide one. |
| iOS Simulator cannot capture | No workaround exists. |

### 7.3 `switchCamera` preserves the live session

`switchCamera()` crosses the method channel because both pinned native stacks
provide a verified, public in-session mechanism:

- Android casts the Decart stream's video track to LiveKit `LocalVideoTrack`
  and calls `restartTrack`. LiveKit transfers the existing renderers and updates
  the current sender, so the Room is not disconnected. The controller rebuilds
  Decart's mirror processor for the selected lens because `.auto` mirrors only
  the front camera. `AndroidMirrorProcessorFactory.java` is a narrow interop
  shim: Decart's processor is a public JVM class but carries Kotlin `internal`
  metadata, so Java can construct the SDK implementation while Kotlin cannot.
- iOS obtains LiveKit's `CameraCapturer` from the existing `LocalVideoTrack` and
  calls `set(cameraPosition:)`. It then updates Decart's
  `MirroringVideoProcessor.cameraPosition`, as required by Decart's own SDK
  documentation.

The Dart controller updates `cameraFacing` only after native success. No token
is minted, the session ID and outfit state stay unchanged, and a failed switch
surfaces as `CAMERA_UNAVAILABLE` rather than silently replacing the session.
This code is intentionally covered by native compilation because it relies on
the LiveKit versions pinned transitively by `decart-android` 0.7.10 and
`decart-ios` 0.6.10.

### 7.4 One accepted asymmetry at connect time

`ConnectOptions.initialPrompt` with no image makes the Android SDK send a
`prompt` initial-state message, where iOS would send `set_image`. This is
**left alone**, because on a fresh session there is no image to clear, so the
two messages are semantically identical. Forcing parity would have cost an extra
round trip for no behavioural gain. It is commented at the call site so the next
person does not "fix" it.

---

## 8. Rendering: why hybrid composition on Android

`VtonRemoteView` uses `PlatformViewLink` + `PlatformViewsService.initExpensiveAndroidView`
— hybrid composition — rather than the cheaper texture-layer path that a plain
`AndroidView` would give.

**Why:** the LiveKit renderers manage their own EGL surface. Texture-layer
hybrid composition works by having the native view draw into a Flutter-supplied
`Surface`, and that copy is not reliable across the device matrix for
EGL-managed video views. Hybrid composition composites *any* native view
correctly, at the cost of an extra GPU pass and some overlay bookkeeping.

**The trade-off:** a measurable but usually acceptable frame-time cost, most
noticeable on low-end hardware and when the video view is under other Flutter
widgets.

**The faster route, if you need it:** do what `flutter_webrtc` does — skip
platform views entirely and render into a `TextureRegistry.SurfaceTextureEntry`
by attaching a `SurfaceEglRenderer` as a `VideoSink` on the track, then display
it with Flutter's `Texture` widget. That is a real amount of EGL code and a real
amount of lifecycle care, which is why it is not what this first version does.
iOS is unaffected — `UiKitView` composites `VideoView` efficiently already.

---

## 9. Deliberately out of scope

Each of these is a self-contained follow-up rather than a hole:

- **Batch / queue API.** `client.queue` on both SDKs submits a job for a
  pre-recorded video, polls, and downloads the result. Entirely separate from
  the realtime path; would want its own Dart surface (`VtonBatchJob`, a
  `Stream<VtonJobProgress>`) rather than being bolted onto `DecartVton`.
- **`debugQuality` / glass-to-glass measurement.** Both SDKs can stamp a
  **visible** pixel marker into every frame to measure true camera-to-display
  latency. Diagnostic only and explicitly not for production; exposing it would
  invite someone to ship it.
- **Deep connectivity probe.** `checkConnectivity(deep: true)` opens a real
  short-lived session with a synthetic source. It is the accurate probe, but it
  costs GPU time and therefore money — too sharp an edge for a default API.
- **Viewer sessions.** Android emits a `subscribeToken` so a second client can
  watch the same room without the publisher's key. iOS does not expose it at
  v0.6.9, so a cross-platform viewer API is not currently possible.
- **Publish stats and diagnostics flows.** Rich, verbose, and Android-only in
  their detailed form.

---

## 10. Build and verification status — read this

This is the part where honesty matters more than tidiness.

### What was verified

- The native API surface this plugin calls was read directly from
  `decart-android` @ `0.7.9` and `decart-ios` @ `v0.6.9` — every signature,
  enum case, default value and message string referenced in this codebase traces
  to those sources. No SDK method or behaviour here is inferred from the docs
  alone, and where the docs and source disagree the disagreement is documented.
- The Dart layer's logic is covered by `test/decart_vton_test.dart`: the full
  `setOutfit` validation matrix, `PlatformException` → `DecartVtonException`
  mapping for both platforms' code vocabularies, event decoding for every event
  type (plus the unknown-type case), lifecycle, and the `VtonOutfit` /
  `VtonModel` value semantics.
- **`tool/check_contract.py` runs and passes.** This is the one piece of
  genuinely *executable* verification that does not need a toolchain. It checks
  that Dart, Kotlin and Swift agree on: every channel method, every argument
  key, every event `type`, every platform-view creation param, the three channel
  and view-type name strings, and every error code that can reach
  `VtonErrorCode.fromNative`. It also verifies that every symbol the barrel
  exports actually exists, and that the shipped YAML and XML parse. It is
  mutation-tested — five deliberate faults were injected (a renamed argument
  key, a typo'd barrel export, a drifted event name on one platform, an
  unmapped native error code, and a mismatched channel name) and all five were
  caught. It found two real gaps on its first run: `QUEUE_ERROR` and `UNKNOWN`
  were unmapped and would have silently degraded to `VtonErrorCode.unknown`.
  Run it with `tool/verify.sh --contract`.
- Both the Dart and the native layers went through a line-by-line adversarial
  reading review against the vendored SDK sources and against the Flutter 3.24
  and Swift 6 API surfaces. That pass caught and fixed, among others: `@internal`
  not being re-exported by `flutter/foundation.dart`; a `VtonLifecycleObserver`
  bug where one failed transition would wedge the observer permanently; a
  disposed singleton with no recovery path; six Swift 6 strict-concurrency
  violations in the platform-view, event-dispatcher and plugin classes; iOS
  `release()` leaving `isConnected()` stale; and `DecartVton.errors` being
  permanently silent on iOS. A reading review is not a compiler, but it is
  considerably better than nothing.

`require_trailing_commas` was removed from `analysis_options.yaml`. It is a pure
style rule with no correctness value, it fires on a couple of dozen call sites in
`test/` and `example/`, and — without a formatter available in the authoring
environment — compliance could not be verified. Re-enable it once you have run
`dart format` locally; on Dart 3.7+ the formatter inserts the commas itself and
the rule self-disables.

### What was NOT verified, and why

**The package has not been compiled.** It was authored in a sandboxed
environment whose egress allowlist blocks `pub.dev`, `storage.googleapis.com`,
`dl.google.com`, Maven Central and JitPack. That makes it impossible to install
the Flutter SDK, run `flutter pub get`, run `flutter analyze`, resolve the
Android dependency, or run Pigeon. iOS is doubly impossible without macOS.

So: **`flutter analyze` is clean by construction, not by observation**, and the
Kotlin and Swift have never been through a compiler. Treat the first build as
part of the work, not as a regression.

Run it with:

```bash
tool/bootstrap_example.sh     # generates example/android + example/ios, patches them
tool/verify.sh                # format + analyze + test + Android build
tool/verify.sh --ios          # add the iOS build, on macOS
```

### Where the first build is most likely to complain

Ranked by how likely and how annoying, so you know where to look:

1. **Kotlin named-argument or overload mismatches** in
   `VtonSessionController.connect`. `ConnectOptions` at 0.7.9 has three
   constructors (one primary plus two source-compatibility overloads) and
   `createLocalVideoStream` has four. Named arguments were used throughout to
   pin resolution to the primary constructor, but this is the single most likely
   place for a signature to have drifted.
2. **`ConnectionQuality` enum-case exhaustiveness.** Kotlin `when` over
   `GOOD/FAIR/POOR/CRITICAL` and Swift `switch` over `good/fair/poor/critical`.
   If a case is added upstream both stop compiling — which is the desired
   behaviour, but it will be the error you see.
3. **LiveKit renderer imports on Android.** `io.livekit.android.renderer.TextureViewRenderer`
   and `livekit.org.webrtc.RendererCommon` come in transitively at `api` scope
   from the Decart SDK. If JitPack's AAR loses the `api` scoping, add
   `io.livekit:livekit-android:2.25.3` explicitly to `android/build.gradle`.
4. **Swift 6 strict concurrency around `VideoView` and `RealtimeMediaStream`.**
   `@preconcurrency import LiveKit` is used in the two files that touch LiveKit
   types; a stricter toolchain may want more `@Sendable` annotations or an
   explicit `nonisolated`.
5. **`LocalVideoTrack.stop()` throwing-ness.** `teardownSession` uses
   `try? await track.stop()`. If LiveKit's `stop()` is non-throwing in the
   resolved version, that becomes a warning; drop the `try?`.
6. **`MockStreamHandler` availability in tests.** `MockStreamHandler.inline` and
   `setMockStreamHandler` need a reasonably recent `flutter_test`. On an older
   Flutter, mock the event channel through
   `defaultBinaryMessenger.handlePlatformMessage` instead.
7. **JitPack version availability.** The plugin pins `0.7.9`. If JitPack has not
   built that tag, override it from the consuming app's `gradle.properties`:
   `decartAndroidSdkVersion=0.7.3` (the version the SDK's own README documents).
8. **AGP / Kotlin version conflict.** The plugin's buildscript defaults to AGP
   8.7.3 and Kotlin 2.1.0, which suits the Flutter 3.24–3.32 generation. Current
   Flutter stable generates apps on AGP 9.x and Kotlin 2.3.x, and Gradle objects
   when the same plugin appears on the buildscript classpath at two versions.
   The fix is one line in the app's `gradle.properties`:
   `decartAgpVersion=9.0.1` and `decartKotlinVersion=2.3.20`. All four
   Android version knobs (`decartAndroidSdkVersion`, `decartAgpVersion`,
   `decartKotlinVersion`, `decartCompileSdk`) are overridable for this reason.

### Runtime checks that still need a physical device

Nothing below can be established by a compiler:

- End-to-end: connect, see transformed video, change the outfit by prompt only,
  by image only, and by both.
- That the §2.1 routing fix actually behaves as intended on Android — set a
  garment, then send a prompt-only update, and confirm the garment clears
  (matching iOS).
- Renderer rebinding after a forced reconnect (turn the network off and on).
- Background/foreground via `VtonLifecycleObserver`, including that the camera
  indicator goes out on background.
- In-session `switchCamera()` in both directions, including `.auto` mirroring
  and an unavailable second lens.
- Release-build behaviour on Android with R8 enabled — the consumer ProGuard
  rules are the thing being tested, and their failure mode is release-only.

---

## 11. Repository map

```
decart_vton_flutter/
├── README.md                     consumer documentation
├── IMPLEMENTATION.md             this file
├── SPEC.md                       Phase 0 research + Phase 1 design, pre-implementation
├── lib/
│   ├── decart_vton_flutter.dart  barrel; the entire public surface
│   └── src/
│       ├── decart_vton.dart              DecartVton — the public controller
│       ├── decart_vton_platform.dart     the ONLY file that knows the wire format
│       ├── vton_lifecycle_observer.dart  background/foreground helper
│       ├── models/                       enums, VtonOutfit, errors, events
│       └── widgets/vton_video_view.dart  VtonRemoteView / VtonLocalPreview
├── android/
│   ├── build.gradle              JitPack + pinned SDK version + minSdk 24 + Java 17
│   ├── consumer-rules.pro        R8 keeps (duplicated from the SDK on purpose)
│   ├── src/main/java/ai/decart/vton/flutter/
│   │   └── AndroidMirrorProcessorFactory.java  Kotlin-internal SDK interop shim
│   └── src/main/kotlin/ai/decart/vton/flutter/
│       ├── DecartVtonPlugin.kt           thin dispatcher
│       ├── VtonSessionController.kt      all session state; the routing fix
│       ├── VtonVideoPlatformView.kt      registry + factory + renderer host
│       ├── VtonEventDispatcher.kt        main-thread hop + pre-listen buffer
│       ├── ChannelCodec.kt               wire format
│       └── Errors.kt                     error vocabulary + classification
├── ios/
│   ├── decart_vton_flutter.podspec       explains why CocoaPods cannot work
│   └── decart_vton_flutter/
│       ├── Package.swift                 SPM manifest; DecartSDK + LiveKit
│       └── Sources/decart_vton_flutter/  Swift mirrors of the Kotlin files
├── test/decart_vton_test.dart    Dart-layer unit tests
├── tool/
│   ├── bootstrap_example.sh      generates + patches example/android and example/ios
│   ├── check_contract.py         cross-language wire-contract check (no toolchain needed)
│   └── verify.sh                 the Phase 4 loop as one command
└── example/
    ├── lib/main.dart             full try-on demo
    ├── .env.example              where the API key goes
    └── pubspec.yaml
```
