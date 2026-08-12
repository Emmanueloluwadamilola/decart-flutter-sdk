# decart_vton_flutter

Realtime **virtual try-on** for Flutter. This package wraps the native
[Decart](https://platform.decart.ai) Android and iOS SDKs (the *Lucy VTON*
family of realtime models) so a Flutter app can stream the device camera to
Decart over WebRTC, get an edited video stream back with different clothes on
the person, and change the outfit live — by text prompt, by garment reference
image, or both — without ever reconnecting. Decart ships no Flutter SDK, so this
package binds their Kotlin and Swift SDKs directly rather than reimplementing
the protocol in Dart.

| | |
| --- | --- |
| Android | ✅ API 24+ · wraps `com.github.DecartAI:decart-android:0.7.9` |
| iOS | ✅ iOS 17.0+ · wraps `DecartAI/decart-ios` v0.6.9 (**Swift Package Manager only**) |
| Web / macOS / Windows / Linux | ❌ no native SDK exists |

---

## Contents

- [Install](#install)
- [Platform setup](#platform-setup)
- [Getting an API key](#getting-an-api-key)
- [Quickstart](#quickstart)
- [The one thing that trips everyone up](#the-one-thing-that-trips-everyone-up)
- [Writing good prompts and reference images](#writing-good-prompts-and-reference-images)
- [API reference](#api-reference)
- [Lifecycle handling](#lifecycle-handling)
- [Errors](#errors)
- [Known limitations](#known-limitations)
- [Running the example](#running-the-example)

---

## Install

```yaml
dependencies:
  decart_vton_flutter: ^0.1.0
```

```bash
flutter pub get
```

---

## Platform setup

Both platforms need real setup. Read the whole of your platform's section before
building — a couple of these are hard requirements, not suggestions.

### Android

**1. Minimum SDK 24.** The Decart SDK declares `minSdk 24`, so anything lower
fails at manifest merge. In `android/app/build.gradle.kts`:

```kotlin
android {
    compileSdk = 35

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }
}
```

**2. Java 17 and Kotlin 2.1+.** The Decart SDK is compiled against Java 17 and
Kotlin 2.1. An older Kotlin Gradle plugin fails with a metadata-version error.

If your app is on a newer Flutter that generates AGP 9.x / Kotlin 2.3.x, match
them in `android/gradle.properties` so the two do not collide on the buildscript
classpath:

```properties
decartAgpVersion=9.0.1
decartKotlinVersion=2.3.20
```

The Decart SDK version and `compileSdk` are overridable the same way
(`decartAndroidSdkVersion`, `decartCompileSdk`).

**3. JitPack — you must add this, it is not optional.** The Decart Android SDK
is published on JitPack, not Maven Central. Add it to your **app's** root
`android/build.gradle.kts`:

```kotlin
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }   // ← add this
    }
}
```

Skipping this fails the build with:

```
Could not find com.github.DecartAI:decart-android:0.7.9.
Required by: project ':app' > project :decart_vton_flutter
```

The plugin does declare JitPack in its own `build.gradle`, and that is genuinely
not enough — which is worth understanding so the error makes sense. Gradle
resolves a configuration using the repositories of the project that **owns** it.
The plugin's own block covers the plugin's compile classpath; when your app
assembles `:app:debugRuntimeClasspath` it pulls the plugin's transitive
dependencies through the *app's* repositories. A plugin cannot add a repository
on its app's behalf without reaching into the root project, which modern Gradle
discourages, so this one step stays yours.

If your project pins repositories centrally with a
`dependencyResolutionManagement` block in `android/settings.gradle.kts`, add the
JitPack line there instead.

**4. Permissions.** `INTERNET`, `CAMERA` and `ACCESS_NETWORK_STATE` are declared
by this plugin's manifest and merge into your app automatically — you do not
need to add them. You **do** have to request `CAMERA` at runtime before
connecting; the plugin deliberately does not do this for you (permission UX
belongs to your app). Any package works;
[`permission_handler`](https://pub.dev/packages/permission_handler) is what the
example uses.

`RECORD_AUDIO` is intentionally *not* declared. Audio publishing is not
implemented in the Decart Android SDK at 0.7.x, so asking for the microphone
would be asking for something the plugin cannot use.

**5. Kotlin Gradle Plugin warning.** On Flutter 3.44+ the build prints:

```
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): decart_vton_flutter
Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
```

It is a warning, not an error, and the build works. This plugin applies KGP the
way Flutter's own plugin template still does at 3.44. Migrating to Flutter's
"Built-in Kotlin" is tracked as a known limitation below.

**6. ProGuard/R8.** Nothing to do — the required keeps ship as consumer rules in
this plugin (and again in the Decart SDK). They cover `ai.decart.sdk.**`,
`org.webrtc.**`, `livekit.org.webrtc.**`, `io.livekit.**` and the
kotlinx-serialization glue.

### iOS

**1. Swift Package Manager is required.** This is not a preference. The Decart
iOS SDK ships no podspec, and its transitive dependency
`shareup/websocket-apple` has no CocoaPods presence, so there is no podspec that
could honestly resolve `DecartSDK`. Enable Flutter's SPM support once per
machine:

```bash
flutter config --enable-swift-package-manager
```

If you have an existing CocoaPods-based iOS project, also clear the stale state
once:

```bash
cd ios && rm -rf Pods Podfile.lock && cd .. && flutter clean
```

A CocoaPods-only build fails with `no such module 'DecartSDK'`. The plugin's
podspec prints an explanatory banner during `pod install` when that happens.

**2. Deployment target 17.0.** `DecartSDK`'s own `Package.swift` declares
`.iOS(.v17)`. This cannot be lowered, and adopting this plugin means dropping
iOS 16 and below.

```ruby
# ios/Podfile
platform :ios, '17.0'
```

…and in Xcode, set **Runner → Build Settings → iOS Deployment Target** to 17.0
(or edit `IPHONEOS_DEPLOYMENT_TARGET` in `ios/Runner.xcodeproj/project.pbxproj`).

**3. Xcode 16 with the Swift 6.2 toolchain.** `decart-ios` declares
`// swift-tools-version: 6.2.1`.

**4. `Info.plist`.** Camera usage description is mandatory; without it the app
is terminated by the OS the moment capture starts.

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to show you wearing different outfits in real time.</string>
```

Add `NSPhotoLibraryUsageDescription` too if you let users pick a garment image
from their library.

`NSMicrophoneUsageDescription` is **not** needed — this plugin never publishes
audio.

**5. Physical device required.** Camera capture does not work on the iOS
Simulator. The app will build and launch there, but no session will produce
video.

### Network

WebRTC needs more than port 443. If your users are behind a restrictive
firewall, allow:

- **TCP 443** for HTTPS/WSS signalling
- **UDP 3478** (STUN/TURN) and **UDP 7882** (LiveKit media)

An HTTP proxy that cannot pass UDP will force a TURN relay at best and fail the
session at worst. `DecartVton().checkConnectivity()` detects this before you
show the user a try-on button.

---

## Getting an API key

1. Create an account at [platform.decart.ai](https://platform.decart.ai).
2. Open the **API Keys** section of the dashboard.
3. Generate a key — permanent keys are prefixed `dct_`.

For local development, put it in a git-ignored `.env`:

```bash
cp example/.env.example example/.env
# then edit example/.env:
#   DECART_API_KEY=dct_your_key_here
```

```dart
await dotenv.load();
await DecartVton().initialize(apiKey: dotenv.env['DECART_API_KEY']!);
```

### ⚠️ Production apps must not ship a permanent key

A `dct_` key embedded in an APK or IPA can be extracted by anyone who downloads
your app. Decart's own guidance is explicit about this, and it is worth
underlining that the realtime SDKs put the key **in the signalling URL's query
string**, so it can also end up in proxy and gateway logs.

The production pattern is short-lived **client tokens**:

1. Your backend holds the permanent `dct_` key and calls Decart's
   `tokens.create()` — with `expiresIn` (1–3600 s, default 60), an
   `allowedModels` list, and optionally
   `constraints.realtime.maxSessionDuration` to cap session length.
2. Your app fetches the resulting `ek_…` token from your backend just before
   connecting.
3. Pass it to `initialize(apiKey: ...)` exactly as you would a permanent key.

**No API change is needed.** `initialize` takes an opaque string; the plugin
neither knows nor cares which kind it is. Rotating a token mid-app is
`initialize(apiKey: fresh, force: true)`.

Full details: [Client Tokens](https://docs.platform.decart.ai/getting-started/client-tokens)
· [Authentication](https://docs.platform.decart.ai/getting-started/authentication)

---

## Quickstart

Copy-pasteable, minus your own permission and error UI.

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

    await _vton.initialize(apiKey: const String.fromEnvironment('DECART_API_KEY'));

    _vton.connectionStates.listen((s) => setState(() => _state = s));
    _vton.errors.listen((e) => debugPrint('decart: $e'));

    await _vton.connect(
      model: VtonModel.lucyVtonLatest,
      initialOutfit: const VtonOutfit(
        prompt: 'Substitute the current top with a navy blue hoodie '
            'with a white drawstring',
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

          // The transformed try-on video.
          const VtonRemoteView(fit: VtonVideoFit.cover),

          // Optional: the raw camera, as a self-view.
          if (_state.isLive)
            const Positioned(
              right: 12, top: 12, width: 96, height: 128,
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

Changing the outfit with a garment photo instead of (or as well as) a prompt:

```dart
final Uint8List garment = await File('parka.jpg').readAsBytes();

await _vton.setOutfit(
  prompt: 'Substitute the current top with this jacket, worn open',
  referenceImage: garment,
);
```

---

## The one thing that trips everyone up

**An outfit update replaces the entire state. Fields you leave out are cleared.**

That is how the Decart realtime API works, and it is worth internalising before
you write your third `setOutfit` call:

```dart
await vton.setOutfit(prompt: 'a red parka', referenceImage: garmentBytes);
await vton.setOutfit(prompt: 'in charcoal grey');   // ← garmentBytes is now GONE
```

To change one thing and keep the rest, build the next state from the last one:

```dart
await vton.setOutfit(
  outfit: vton.currentOutfit!.copyWith(prompt: 'in charcoal grey'),
);
```

`currentOutfit` holds the last update this app successfully applied.
`VtonOutfit.copyWith` also has explicit `clearPrompt` / `clearReferenceImage`
flags for when removal is what you actually want.

Calling `setOutfit()` with **neither** a prompt nor an image throws
`ArgumentError` rather than silently wiping the effect.

---

## Writing good prompts and reference images

Straight from Decart's model documentation, because it makes a large difference
to output quality.

**Prompts** — use the *substitute* or *add* pattern, and change one thing at a
time:

| | |
| --- | --- |
| ✅ | `Substitute the current top with a navy blue hoodie with a white cross logo on the chest` |
| ✅ | `Add a wide-brimmed straw hat to the person's head` |
| ❌ | `Put a jacket on` — too vague |
| ❌ | `Red hoodie` — a fragment, not an instruction |
| ❌ | `Red hoodie and sunglasses and change the background` — several unrelated changes |

`enhance: true` (the default) lets the server expand a short prompt. Turn it off
when you have written something detailed and do not want it rewritten.

**Reference images** — the model wants the garment, not a photo of someone
wearing it:

- clean product shot of the item alone, plain or white background
- at least 512×512, ideally under 5 MB
- JPEG, PNG or WebP
- if your source is a person wearing the garment, extract the garment first

Pairing a reference image *with* a descriptive prompt gives the clearest signal
of what to apply.

---

## API reference

### `DecartVton`

Singleton — `DecartVton()` always returns the same instance.

| Member | Description |
| --- | --- |
| `initialize({apiKey, signalingBaseUrl, httpBaseUrl, logLevel, force})` | Creates the native client. Call once. `force: true` recreates it, e.g. to rotate a client token. |
| `connect({model, initialOutfit, camera, mirror, resolution, video, connectTimeout})` | Opens a session and starts publishing the camera. Completes when the session is live. |
| `setOutfit({prompt, referenceImage, enhance, outfit, timeout})` | Replaces the whole try-on state. Completes when the server acks. |
| `switchCamera()` | Flips front/back. **Reconnects** — see limitations. |
| `checkConnectivity({timeout})` | STUN-only pre-flight probe. No session, no cost. |
| `disconnect()` | Ends the session, releases the camera, keeps the client. |
| `dispose()` | Releases everything. The instance is unusable afterwards. |
| `connectionState` · `isConnected` · `sessionId` · `model` · `cameraFacing` · `currentOutfit` · `isInitialized` | Synchronous state. |
| `connectionStates` | `Stream<VtonConnectionState>`, broadcast. |
| `events` | `Stream<VtonEvent>`, broadcast, sealed hierarchy. |
| `errors` | `Stream<DecartVtonException>`, broadcast — out-of-band failures. |

### Widgets

| Widget | Description |
| --- | --- |
| `VtonRemoteView({fit, mirror})` | Renders the transformed try-on video. Rebinds itself across reconnects. |
| `VtonLocalPreview({fit, mirror})` | Renders the raw camera feed. Mirrored by default. |

Both are native platform views (`TextureViewRenderer` on Android, LiveKit
`VideoView` on iOS). Safe to place in the tree before connecting — they render
transparent until a track exists.

### Values

| Type | Description |
| --- | --- |
| `VtonModel` | `lucyVtonLatest` (recommended), `lucyVton3`, `lucyVton2`, `lucyLatest`, `lucy21`, `lucy25`, `lucyRestyleLatest`, `lucyRestyle2`. Carries native `width`/`height`/`fps` and `supportsReferenceImage`. |
| `VtonOutfit` | Immutable `{prompt, referenceImage, enhance}` with `copyWith`. |
| `VtonResolution` | `p720` (default), `p1080`. |
| `VtonCameraFacing` | `front`, `back`. |
| `VtonMirrorMode` | `off`, `on`, `auto` (default) — pre-flips *outgoing* frames. |
| `VtonVideoConfig` | Bitrate / framerate / codec / simulcast overrides. |
| `VtonLogLevel` | `debug`, `info`, `warn` (default), `error`. Android only. |
| `VtonConnectionState` | `idle`, `connecting`, `connected`, `generating`, `reconnecting`, `disconnected`, `error`. Has `isLive` and `isInSession`. |
| `VtonConnectivityReport` | `{quality, transport, roundTripMs}` with `isUsable`. |

### Events

`VtonEvent` is `sealed`, so `switch` is exhaustively checked:

`VtonConnectionStateChanged` · `VtonSessionStarted` · `VtonGenerationTick` ·
`VtonRemoteStreamUpdated` · `VtonLocalStreamUpdated` ·
`VtonConnectionQualityChanged` · `VtonErrorOccurred`

Generate full dartdoc with `dart doc .`.

---

## Lifecycle handling

Holding a WebRTC session open while the app is backgrounded drains battery,
keeps the camera claimed, and gets killed by the OS anyway — often leaving the
native SDK reconnecting into a dead camera. Decart's streaming guide recommends
disconnecting on background and reconnecting on foreground.

`VtonLifecycleObserver` does exactly that, and only resurrects sessions *it*
ended:

```dart
late final VtonLifecycleObserver _observer;

@override
void initState() {
  super.initState();
  _observer = VtonLifecycleObserver(
    model: VtonModel.lucyVtonLatest,
    outfit: () => DecartVton().currentOutfit,   // restore what the user picked
    onError: (e) => debugPrint('reconnect failed: $e'),
  )..attach();
}

@override
void dispose() {
  _observer.detach();
  super.dispose();
}
```

---

## Errors

Everything throws `DecartVtonException`. A raw `PlatformException` never
escapes.

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

Full `VtonErrorCode` set: `notInitialized`, `notConnected`, `invalidApiKey`,
`invalidInput`, `invalidOptions`, `modelNotFound`, `permissionDenied`,
`cameraUnavailable`, `connectionTimeout`, `webrtc`, `websocket`, `signaling`,
`network`, `server`, `promptRejected`, `cancelled`, `unknown`.

---

## Known limitations

Kept honest, including the parts that are inconvenient.

1. **iOS requires Swift Package Manager.** Forced by upstream; CocoaPods-only
   projects cannot build this plugin. See [iOS setup](#ios).
2. **iOS 17.0 minimum.** Forced by `DecartSDK`'s own `Package.swift`. Adopting
   this plugin drops iOS 16 and below.
3. **`switchCamera()` reconnects the session.** Neither native SDK exposes an
   in-session camera flip on its public API at the wrapped versions, so the
   honest implementation is disconnect → rebuild capture → reconnect. Expect
   roughly a second of black frames and a new `sessionId`. The previous outfit
   is restored automatically.
4. **No audio.** Audio publishing is unimplemented in the Decart Android SDK at
   0.7.x, so the plugin exposes no audio API on either platform rather than
   offering something that only half works.
5. **No batch / queue API.** Decart's job-based API for pre-recorded video files
   is not wrapped. This package is realtime-only. Adding it would be a
   self-contained follow-up — see `IMPLEMENTATION.md`.
6. **Android rendering uses hybrid composition.** Correct on every device, but
   it costs more than the texture-layer path. Noticeable mainly on low-end
   hardware. See `IMPLEMENTATION.md` for the faster route.
7. **`errors` is chattier on Android.** The Android SDK has a dedicated error
   flow; the iOS SDK mostly throws. Do not read iOS's quieter `errors` stream as
   a sign of a healthier session.
8. **`VtonLogLevel` is Android-only.** The iOS SDK has no runtime log-level
   control; it keys off the `ENABLE_DECART_SDK_DUBUG_LOGS` environment variable.
9. **Applies the Kotlin Gradle Plugin.** Flutter 3.44+ warns that plugins doing
   this will fail to build on some future release, and points at its "Built-in
   Kotlin" migration. Builds fine today; migration is a TODO.
10. **`signalingBaseUrl` is Android-only.** The iOS SDK takes a single base URL
   and derives the `wss://` signalling endpoint from it. Only relevant if you
   point the plugin at a non-default environment.
11. **No camera preview before `connect()`.** The capture track is created as
   part of connecting, so `VtonLocalPreview` is blank until then.
12. **iOS Simulator cannot capture video.** Physical device only.
13. **Verification status.** The Dart layer is covered by unit tests. The
    native layers were written against the pinned SDK sources but the
    end-to-end build and on-device run are the adopter's first job — see
    `tool/verify.sh` and the note at the end of `IMPLEMENTATION.md`.

---

## Running the example

```bash
git clone <this repo> && cd decart_vton_flutter

# Generates example/android and example/ios and applies the required settings.
tool/bootstrap_example.sh

# Add your key.
echo 'DECART_API_KEY=dct_your_key_here' > example/.env

# contract + analyze + format + tests + Android build (add --ios on macOS).
tool/verify.sh

# Or just the toolchain-free consistency check:
tool/verify.sh --contract

cd example && flutter run     # physical device
```

The example exercises the full core use case: connect with the camera, render
the transformed stream, change the outfit mid-session by prompt, by garment
image, and by both, toggle `enhance`, switch cameras, show live connection
quality and session duration, and disconnect cleanly.

---

## Licence

MIT. See `LICENSE`.

This package is an independent wrapper. Decart, Lucy and the Decart SDKs are the
property of Decart AI; your use of the service is governed by their terms.
