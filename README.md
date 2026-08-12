# decart_vton_flutter

**Flutter SDK for Decart's Lucy Virtual Try-On.** Decart ships native SDKs for
Swift and Kotlin only — there is no official Flutter support and no community
binding on pub.dev. This package fills that gap: it wraps both native SDKs
behind a single Dart API so a Flutter app can run real-time virtual try-on
without writing platform code.

[![pub package](https://img.shields.io/pub/v/decart_vton_flutter.svg)](https://pub.dev/packages/decart_vton_flutter)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-lightgrey.svg)](#platform-support)

---

## Why this exists

Decart's realtime API is not request/response — a session opens a WebSocket for
signalling, receives a LiveKit room, publishes the device camera over WebRTC, and
subscribes to a transformed video track coming back. Decart implements that
protocol in Kotlin and Swift; reproducing it in Dart would mean duplicating
roughly two thousand lines of signalling, reconnect and quality-measurement logic
that they already maintain twice.

So this package binds the native SDKs rather than reimplementing them. It wraps
[`DecartAI/decart-android`](https://github.com/DecartAI/decart-android) `0.7.9`
and [`DecartAI/decart-ios`](https://github.com/DecartAI/decart-ios) `v0.6.9`,
normalising the two into one Dart surface — including the places where the two
SDKs genuinely disagree (see [Platform parity](#platform-parity)).

---

## Features

Every item below maps to a real symbol in `lib/`.

- **One-call session lifecycle.** `initialize()`, `connect()`, `disconnect()`,
  `dispose()` on a single `DecartVton` singleton.
- **Live outfit changes without reconnecting.** `setOutfit()` accepts a text
  prompt, a garment reference image (`Uint8List`), or both, and completes when
  the server acknowledges the change — not when the request is sent.
- **Native video rendering.** `VtonRemoteView` renders the transformed stream and
  `VtonLocalPreview` the raw camera, as platform views
  (`TextureViewRenderer` on Android, LiveKit `VideoView` on iOS). Both re-bind
  themselves natively across the SDK's automatic reconnects, so no widget rebuild
  is required.
- **Typed, exhaustive event stream.** `events` emits a Dart 3 `sealed`
  `VtonEvent` hierarchy — `VtonConnectionStateChanged`, `VtonSessionStarted`,
  `VtonGenerationTick`, `VtonRemoteStreamUpdated`, `VtonLocalStreamUpdated`,
  `VtonConnectionQualityChanged`, `VtonErrorOccurred` — so a `switch` over it is
  checked for exhaustiveness by the analyser.
- **One exception type.** Everything throws `DecartVtonException` carrying a
  closed `VtonErrorCode` enum. `PlatformException` never escapes the package, and
  the two native SDKs' differing error vocabularies are normalised into one.
- **Pre-flight network check.** `checkConnectivity()` runs a STUN-only probe —
  no session, no model time billed — and reports whether UDP egress will support
  a realtime session.
- **Camera switching.** `switchCamera()` flips front/back and restores the
  current outfit. Note that it reconnects; see [Known limitations](#known-limitations).
- **App-lifecycle helper.** `VtonLifecycleObserver` disconnects on background and
  reconnects on foreground, restoring the last outfit, and only resurrects
  sessions it ended itself.
- **Platform-consistent behaviour by design.** Codec, bitrate and the
  prompt-enhance flag are pinned identically on both platforms, and Android is
  taught the iOS SDK's message-routing rule so an outfit update means the same
  thing on each. Divergences that cannot be hidden are documented rather than
  papered over.

---

## Platform support

| Platform | Status | Minimum | Wraps |
| --- | --- | --- | --- |
| Android | Supported | API 24 (7.0) | `com.github.DecartAI:decart-android:0.7.9` |
| iOS | Supported | iOS 17.0 | `DecartAI/decart-ios` v0.6.9 (**SPM only**) |
| Web, macOS, Windows, Linux | Not supported | — | no native SDK exists |

Requires Flutter `>=3.24.0` and Dart `^3.5.0`. Developed and verified against
Flutter 3.44.2 / Dart 3.12.2, Xcode 26.5, Java 21 and Android SDK 36.

---

## Installation

```yaml
dependencies:
  decart_vton_flutter: ^0.1.0
```

Not yet on pub.dev — until it is published, depend on it by path or git:

```yaml
dependencies:
  decart_vton_flutter:
    git:
      url: https://github.com/emmanueloluwadamilola/decart_vton_flutter.git
```

```bash
flutter pub get
```

Both platforms need native setup before the plugin will build. Do not skip the
next section — two of the steps are hard requirements, not recommendations.

---

## Platform setup

### Android

**1. `minSdk` 24.** The Decart SDK declares `minSdk 24`; anything lower fails at
manifest merge. In `android/app/build.gradle.kts`:

```kotlin
android {
    defaultConfig {
        minSdk = maxOf(24, flutter.minSdkVersion)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
```

**2. Add the JitPack repository — required.** The Decart Android SDK is published
on JitPack, not Maven Central. Add it to your app's *root*
`android/build.gradle.kts`:

```kotlin
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

Omitting this fails the build with:

```
Could not find com.github.DecartAI:decart-android:0.7.9.
Required by: project ':app' > project :decart_vton_flutter
```

The plugin declares JitPack in its own `build.gradle`, and that is deliberately
not sufficient. Gradle resolves a configuration using the repositories of the
project that *owns* it, so `:app:debugRuntimeClasspath` pulls this plugin's
transitive dependencies through your app's repositories. A plugin cannot add one
on its app's behalf without reaching into the root project, which modern Gradle
discourages.

If your project pins repositories centrally via `dependencyResolutionManagement`
in `android/settings.gradle.kts`, add the JitPack line there instead.

**3. Kotlin 2.1+ and Java 17.** The Decart SDK is compiled against both. If your
Flutter version generates AGP 9.x / Kotlin 2.3.x, match them in
`android/gradle.properties` so the two do not collide on the buildscript
classpath:

```properties
decartAgpVersion=9.0.1
decartKotlinVersion=2.3.20
```

`decartAndroidSdkVersion` and `decartCompileSdk` are overridable the same way.

**4. Permissions — already handled.** `INTERNET`, `CAMERA` and
`ACCESS_NETWORK_STATE` are declared in the plugin's manifest and merge into your
app; you do not need to add them. You *do* need to request `CAMERA` at runtime
before calling `connect()` — the plugin does not do this for you, because
permission UX belongs to your app.

`RECORD_AUDIO` is intentionally not declared: audio publishing is unimplemented
in the Decart Android SDK at 0.7.x, so requesting the microphone would be asking
for a permission the plugin cannot use.

**5. ProGuard/R8 — nothing to do.** The required keeps ship as consumer rules
(`ai.decart.sdk.**`, `org.webrtc.**`, `livekit.org.webrtc.**`, `io.livekit.**`,
plus the kotlinx-serialization glue).

### iOS

**1. Swift Package Manager is mandatory.** `decart-ios` publishes no podspec, and
its transitive dependency `shareup/websocket-apple` has no CocoaPods presence, so
no podspec could honestly resolve `DecartSDK`. Enable Flutter's SPM integration
once per machine:

```bash
flutter config --enable-swift-package-manager
```

On an existing CocoaPods project, clear the stale state once:

```bash
cd ios && rm -rf Pods Podfile.lock && cd .. && flutter clean
```

A CocoaPods-only build fails with `no such module 'DecartSDK'`; the plugin's
podspec prints an explanatory banner during `pod install` when that happens.

**2. Deployment target 17.0.** `DecartSDK`'s own `Package.swift` declares
`.iOS(.v17)`. This cannot be lowered — adopting this plugin drops iOS 16 and
below.

```ruby
# ios/Podfile
platform :ios, '17.0'
```

Set **Runner → Build Settings → iOS Deployment Target** to 17.0, or edit
`IPHONEOS_DEPLOYMENT_TARGET` in `ios/Runner.xcodeproj/project.pbxproj`.

**3. Xcode 16+ with the Swift 6.2 toolchain.** `decart-ios` declares
`// swift-tools-version: 6.2.1`.

**4. `Info.plist` camera usage description — mandatory.** Without it the OS
terminates the app the moment capture starts.

```xml
<key>NSCameraUsageDescription</key>
<string>Used to show you wearing different outfits in real time.</string>
```

Add `NSPhotoLibraryUsageDescription` if you let users pick a garment image from
their library. `NSMicrophoneUsageDescription` is not needed — this plugin never
publishes audio.

**5. Physical device required.** Camera capture does not work on the iOS
Simulator; a session there will produce no video.

### Credentials

1. Create an account at [platform.decart.ai](https://platform.decart.ai).
2. Open **API Keys** and generate a key. Permanent keys are prefixed `dct_`.
3. For local development, keep it in a git-ignored `.env` (see
   `example/.env.example`):

```
DECART_API_KEY=dct_your_key_here
```

```dart
await dotenv.load();
await DecartVton().initialize(apiKey: dotenv.env['DECART_API_KEY']!);
```

> **Production apps must not ship a permanent key.** A `dct_` key in an APK or
> IPA is extractable, and the realtime SDKs pass the key in the signalling URL's
> query string, so it can also reach proxy logs. Instead, have your backend mint
> a short-lived client token (`ek_…`, TTL 1–3600 s) via Decart's
> [`tokens.create()`](https://docs.platform.decart.ai/getting-started/client-tokens)
> and pass that to `initialize()`. No API change is needed — `initialize()` takes
> an opaque string and neither knows nor cares which kind it is. Rotate with
> `initialize(apiKey: fresh, force: true)`.

### Network

WebRTC needs more than port 443. Behind a restrictive firewall, allow **TCP 443**
for HTTPS/WSS signalling plus **UDP 3478** (STUN/TURN) and **UDP 7882** (LiveKit
media). A proxy that cannot pass UDP forces a TURN relay at best.
`checkConnectivity()` detects this before you offer the user a try-on button.

---

## Quick start

Condensed from `example/lib/main.dart`.

```dart
import 'package:decart_vton_flutter/decart_vton_flutter.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class TryOnPage extends StatefulWidget {
  const TryOnPage({super.key});

  @override
  State<TryOnPage> createState() => _TryOnPageState();
}

class _TryOnPageState extends State<TryOnPage> {
  final DecartVton _vton = DecartVton();
  VtonConnectionState _state = VtonConnectionState.idle;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (!await Permission.camera.request().isGranted) return;

    await _vton.initialize(apiKey: myApiKey);

    _vton.connectionStates.listen((VtonConnectionState s) {
      if (mounted) setState(() => _state = s);
    });
    _vton.errors.listen((DecartVtonException e) => debugPrint('$e'));

    await _vton.connect(
      model: VtonModel.lucyVtonLatest,
      initialOutfit: const VtonOutfit(
        prompt: 'Substitute the current top with a navy blue hoodie',
      ),
      camera: VtonCameraFacing.front,
      resolution: VtonResolution.p720,
    );
  }

  @override
  void dispose() {
    _vton.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          const VtonRemoteView(fit: VtonVideoFit.cover),
          if (_state.isLive)
            const Positioned(
              right: 12,
              top: 12,
              width: 96,
              height: 128,
              child: VtonLocalPreview(),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _state.isLive
            ? () => _vton.setOutfit(
                  prompt: "Add a wide-brimmed straw hat to the person's head",
                )
            : null,
        label: const Text('Add a hat'),
      ),
    );
  }
}
```

Changing the outfit with a garment image, with or without a prompt:

```dart
final Uint8List garment = await File('parka.jpg').readAsBytes();

await _vton.setOutfit(
  prompt: 'Substitute the current top with this jacket, worn open',
  referenceImage: garment,
);
```

### Outfit updates replace the whole state

This is the one behaviour worth reading twice, and it comes from the Decart API
rather than from this package. An outfit update **replaces the entire state** —
omitted fields are cleared server-side:

```dart
await vton.setOutfit(prompt: 'a red parka', referenceImage: garment);
await vton.setOutfit(prompt: 'in charcoal grey');   // garment is now cleared
```

To change one field and keep the rest, build the next state from the last:

```dart
await vton.setOutfit(
  outfit: vton.currentOutfit!.copyWith(prompt: 'in charcoal grey'),
);
```

`currentOutfit` holds the last update this app successfully applied.
`VtonOutfit.copyWith` also takes explicit `clearPrompt` and `clearReferenceImage`
flags for when removal is what you want. Calling `setOutfit()` with neither a
prompt nor an image throws `ArgumentError` rather than silently wiping the
effect.

For prompt and reference-image guidance (the "substitute"/"add" phrasing the
model responds to, and what makes a good garment photo), see
[`IMPLEMENTATION.md`](IMPLEMENTATION.md) and Decart's
[model documentation](https://docs.platform.decart.ai/models/realtime/virtual-try-on).

---

## API reference

### `DecartVton`

A singleton — `DecartVton()` always returns the same instance, mirroring the fact
that each native side holds one client and one session.

| Member | Description |
| --- | --- |
| `initialize({apiKey, signalingBaseUrl, httpBaseUrl, logLevel, force})` | Creates the native client. Call once; `force: true` recreates it, e.g. to rotate a client token. |
| `connect({model, initialOutfit, camera, mirror, resolution, video, connectTimeout})` | Opens a session and starts publishing the camera. Completes when the session is live. |
| `setOutfit({prompt, referenceImage, enhance, outfit, timeout})` | Replaces the whole try-on state. Completes on server acknowledgement. |
| `switchCamera()` | Flips front/back, restoring the current outfit. Reconnects — see limitations. |
| `checkConnectivity({timeout})` | STUN-only pre-flight probe. Returns `VtonConnectivityReport`. |
| `disconnect()` | Ends the session and releases the camera; keeps the client. |
| `dispose()` | Releases everything and clears the cached singleton. |
| `events` | `Stream<VtonEvent>`, broadcast. |
| `connectionStates` | `Stream<VtonConnectionState>`, broadcast. |
| `errors` | `Stream<DecartVtonException>`, broadcast — out-of-band failures. |
| `connectionState`, `isConnected`, `isInitialized`, `model`, `cameraFacing`, `sessionId`, `currentOutfit` | Synchronous state. |

### Widgets

| Widget | Description |
| --- | --- |
| `VtonRemoteView({fit, mirror, gestureRecognizers})` | Renders the transformed try-on video. |
| `VtonLocalPreview({fit, mirror, gestureRecognizers})` | Renders the raw camera feed; mirrored by default. |

Both are safe to place in the tree before connecting — they render transparent
until a track exists.

### Types

| Type | Description |
| --- | --- |
| `VtonModel` | `lucyVtonLatest` (recommended), `lucyVton3`, `lucyVton2`, `lucyLatest`, `lucy21`, `lucy25`, `lucyRestyleLatest`, `lucyRestyle2`. Carries native `width`, `height`, `fps` and `supportsReferenceImage`. |
| `VtonOutfit` | Immutable `{prompt, referenceImage, enhance}` with `copyWith`. |
| `VtonConnectionState` | `idle`, `connecting`, `connected`, `generating`, `reconnecting`, `disconnected`, `error`, plus `isLive` and `isInSession`. |
| `VtonResolution` | `p720` (default), `p1080`. |
| `VtonCameraFacing` | `front`, `back`. |
| `VtonMirrorMode` | `off`, `on`, `auto` (default). Pre-flips *outgoing* frames. |
| `VtonVideoConfig` | Bitrate, framerate, codec and simulcast overrides. |
| `VtonVideoFit` | `cover`, `contain`. |
| `VtonLogLevel` | `debug`, `info`, `warn` (default), `error`. Android only. |
| `VtonConnectivityReport` | `{quality, transport, roundTripMs}` with `isUsable`. |
| `VtonConnectionQuality` | `excellent`, `good`, `poor`, `unusable`, `unknown`. |
| `VtonLifecycleObserver` | `attach()` / `detach()` background-foreground handler. |
| `DecartVtonException` | `{code, message, nativeCode, details}`. |
| `VtonErrorCode` | `notInitialized`, `notConnected`, `invalidApiKey`, `invalidInput`, `invalidOptions`, `modelNotFound`, `permissionDenied`, `cameraUnavailable`, `connectionTimeout`, `webrtc`, `websocket`, `signaling`, `network`, `server`, `promptRejected`, `cancelled`, `unknown`. |

Every public member carries dartdoc. Generate the full reference with
`dart doc .`.

### Error handling

```dart
try {
  await vton.setOutfit(prompt: 'a red parka');
} on DecartVtonException catch (e) {
  switch (e.code) {
    case VtonErrorCode.notConnected:      // no live session
    case VtonErrorCode.promptRejected:    // server nacked the update
    case VtonErrorCode.invalidApiKey:     // expired client token?
    case VtonErrorCode.webrtc:            // network path problem
    default:
      debugPrint('${e.code.name}: ${e.message} (native: ${e.nativeCode})');
  }
}
```

Argument-shape mistakes throw `ArgumentError` instead — those are programming
errors, not runtime conditions.

---

## Platform parity

Normalised for you, so identical Dart code behaves identically:

| Concern | Handling |
| --- | --- |
| Outfit-update message routing | The iOS SDK routes to a `set_image` signalling message for reference-image models; the Android SDK does no such routing, so a prompt-only update would clear the garment on iOS but keep it on Android. This plugin replicates the iOS rule on Android. |
| Video codec / bitrate | Native defaults differ (Android VP8 / 2 Mbps, iOS H.264 / 3.5 Mbps). Pinned to VP8 / 2.5 Mbps on both; override via `VtonVideoConfig`. |
| Prompt-enhance flag | Native defaults disagree with the docs. Always sent explicitly; Dart default `true`. |
| Error codes | The two SDKs use different code strings for the same conditions. Both normalised into `VtonErrorCode`. |
| Camera-permission failures | Both platforms pre-check and fail with `permissionDenied` rather than timing out obscurely. |
| Stream rebinding on reconnect | Handled natively on both; invisible to Dart. |

Divergences that could not be hidden are listed below.

---

## Known limitations

1. **iOS requires Swift Package Manager** and **iOS 17.0**, both forced upstream.
   CocoaPods-only projects cannot build this plugin.
2. **`switchCamera()` reconnects the session.** Neither native SDK exposes an
   in-session camera flip on its public API at the wrapped versions, so the
   implementation is disconnect → rebuild capture → reconnect. Expect about a
   second of black frames and a new `sessionId`. The previous outfit is restored.
3. **No audio.** Audio publishing is unimplemented in the Decart Android SDK at
   0.7.x, so the plugin exposes no audio API on either platform rather than
   offering something that half-works.
4. **No batch/queue API.** Decart's job-based API for pre-recorded video is not
   wrapped; this package is realtime-only.
5. **`errors` is chattier on Android.** The Android SDK has a dedicated error
   flow; the iOS SDK mostly throws. A quiet `errors` stream on iOS does not mean
   a healthier session.
6. **`VtonLogLevel` and `signalingBaseUrl` are Android-only.** The iOS SDK has no
   runtime log level, and takes a single base URL from which it derives the
   signalling endpoint.
7. **Android rendering uses hybrid composition**, which is correct on every
   device but costs more than the texture-layer path. Most noticeable on low-end
   hardware.
8. **No camera preview before `connect()`.** The capture track is created as part
    of connecting, so `VtonLocalPreview` is blank until then.
9. **Flutter 3.44+ prints a Kotlin Gradle Plugin deprecation warning.** Builds
    work today; migrating to Flutter's Built-in Kotlin is a TODO.
10. **iOS Simulator cannot capture video.** Physical device only.

---

## Contributing

Issues and pull requests are welcome. Before opening a PR:

```bash
tool/verify.sh            # contract check, format, analyze, test, Android build
tool/verify.sh --ios      # adds the iOS build (macOS only)
tool/verify.sh --contract # cross-language wire-contract check; needs no toolchain
```

`tool/check_contract.py` verifies that the Dart, Kotlin and Swift layers agree on
every platform-channel method, argument key, event type and error code. It runs
without a Flutter toolchain and is the fastest way to catch a channel-contract
regression.

[`IMPLEMENTATION.md`](IMPLEMENTATION.md) explains how each native layer works and
why the API is shaped this way; [`SPEC.md`](SPEC.md) records the research and
design decisions that preceded the code. Read the former before changing native
code.

## Issues

Please report bugs at
[github.com/dextercyberlabs/decart_vton_flutter/issues](https://github.com/dextercyberlabs/decart_vton_flutter/issues),
including your Flutter version, platform, and the `sessionId` if a live session
was involved.

## License

MIT — see [LICENSE](LICENSE).

This is an independent wrapper. Decart, Lucy and the Decart SDKs are the property
of Decart AI; your use of the service is governed by their terms.
