import 'dart:async';
import 'dart:io';

// Uint8List comes from foundation.dart's re-export of dart:typed_data;
// importing it directly is flagged as unnecessary.
import 'package:flutter/foundation.dart';

import 'decart_vton_platform.dart';
import 'models/vton_connection_state.dart';
import 'models/vton_error.dart';
import 'models/vton_event.dart';
import 'models/vton_model.dart';
import 'models/vton_outfit.dart';

/// Supplies a fresh, short-lived Decart client token (`ek_…`).
///
/// The callback should call an authenticated endpoint owned by the host app.
/// That backend keeps the permanent `dct_…` credential and mints the client
/// token. The plugin can invoke this callback more than once, including for
/// reconnects, and never persists the returned token.
///
/// Do not return a cached token or ask an end user to paste one. Treat the
/// endpoint URL as public application configuration and keep authorization in
/// the host app's normal network/session layer.
///
/// See Decart's [client-token guide](https://docs.platform.decart.ai/getting-started/client-tokens)
/// for backend token creation examples.
typedef VtonClientTokenProvider = Future<String> Function();

/// Entry point for realtime virtual try-on.
///
/// `DecartVton` is a singleton: `DecartVton()` always returns the same
/// instance. That mirrors the native reality — each platform holds one client
/// and one session — and means widgets like `VtonRemoteView` can find the
/// session without you threading a controller through the tree.
///
/// ## Typical lifecycle
///
/// ```dart
/// final vton = DecartVton();
///
/// await vton.initialize(clientTokenProvider: fetchClientToken);
/// await vton.connect(
///   model: VtonModel.lucyVtonLatest,
///   initialOutfit: const VtonOutfit(
///     prompt: 'Substitute the current top with a navy blue hoodie',
///   ),
/// );
///
/// // ... show a VtonRemoteView, change outfits, then:
/// await vton.disconnect();
/// await vton.dispose();
/// ```
///
/// ## Permissions
///
/// This package does **not** request camera permission for you — permission
/// UX belongs to your app. Grant `CAMERA` (Android) / `NSCameraUsageDescription`
/// (iOS) before calling [connect], or [connect] fails with
/// [VtonErrorCode.permissionDenied].
class DecartVton {
  /// Returns the shared instance.
  factory DecartVton() => _instance ??= DecartVton._(DecartVtonPlatform());

  /// Creates an isolated instance against a custom platform binding.
  ///
  /// Intended for tests. Instances created this way are not returned by
  /// `DecartVton()`.
  @visibleForTesting
  DecartVton.forTesting(DecartVtonPlatform platform) : this._(platform);

  DecartVton._(this._platform);

  static DecartVton? _instance;

  /// Drops the cached singleton. Tests only.
  @visibleForTesting
  static void resetInstanceForTesting() => _instance = null;

  final DecartVtonPlatform _platform;

  final StreamController<VtonEvent> _eventController =
      StreamController<VtonEvent>.broadcast();
  final StreamController<VtonConnectionState> _stateController =
      StreamController<VtonConnectionState>.broadcast();
  final StreamController<DecartVtonException> _errorController =
      StreamController<DecartVtonException>.broadcast();

  StreamSubscription<VtonEvent>? _nativeEvents;

  bool _initialized = false;
  bool _disposed = false;
  VtonConnectionState _connectionState = VtonConnectionState.idle;
  VtonModel? _model;
  VtonOutfit? _currentOutfit;
  String? _sessionId;
  VtonCameraFacing _facing = VtonCameraFacing.front;
  _ConnectRequest? _lastConnect;
  _ClientConfiguration? _clientConfiguration;
  bool _nativeClientCredentialUnused = false;
  bool _sessionWasDisconnected = false;
  Future<void> _operationTail = Future<void>.value();

  // ─────────────────────────────────────────────────────────── observers ────

  /// Every session event, as a broadcast stream.
  ///
  /// See [VtonEvent] for the sealed hierarchy and an exhaustive-`switch`
  /// example.
  Stream<VtonEvent> get events => _eventController.stream;

  /// Connection-state transitions, as a broadcast stream.
  ///
  /// A convenience projection of [events]; the current value is available
  /// synchronously from [connectionState].
  Stream<VtonConnectionState> get connectionStates => _stateController.stream;

  /// Non-fatal errors reported mid-session, as a broadcast stream.
  ///
  /// Fatal errors are thrown by the method that caused them; this stream is for
  /// problems that arrive out-of-band (a signalling hiccup during an otherwise
  /// live session, for example).
  ///
  /// **Platform divergence:** the Android SDK exposes a dedicated error flow and
  /// therefore reports more here. The iOS SDK mostly throws instead, so on iOS
  /// this stream is quieter and a comparable failure tends to show up as a
  /// transition to [VtonConnectionState.error] or [VtonConnectionState.reconnecting].
  /// Do not treat silence on this stream as "iOS is healthier".
  Stream<DecartVtonException> get errors => _errorController.stream;

  /// The current connection state, synchronously.
  VtonConnectionState get connectionState => _connectionState;

  /// Whether a session is live and can accept outfit updates.
  bool get isConnected => _connectionState.isLive;

  /// Whether [initialize] or [initializeForDevelopment] completed successfully.
  bool get isInitialized => _initialized;

  /// The model the current (or most recent) session is using.
  VtonModel? get model => _model;

  /// Which camera is currently capturing.
  VtonCameraFacing get cameraFacing => _facing;

  /// Server-assigned identifier for the current session, once known.
  ///
  /// Worth including in bug reports and analytics.
  String? get sessionId => _sessionId;

  /// The last outfit that was successfully applied.
  ///
  /// This is client-side bookkeeping — it records what this app last sent and
  /// got acked, not what the server believes. Use it to build the next update:
  ///
  /// ```dart
  /// await vton.setOutfit(
  ///   outfit: vton.currentOutfit!.copyWith(prompt: 'in charcoal grey'),
  /// );
  /// ```
  VtonOutfit? get currentOutfit => _currentOutfit;

  // ───────────────────────────────────────────────────────────── methods ────

  /// Configures and creates the native Decart client.
  ///
  /// Call once before [connect]. Calling it again while already initialised is
  /// a no-op unless [force] is set. The client created here is reused for the
  /// first connection instead of immediately minting a duplicate token. Later
  /// connections and lifecycle restorations request a fresh token; an
  /// in-session camera switch does not. If the initial token expires before it
  /// is used, the first connection refreshes it and retries once.
  ///
  /// [clientTokenProvider] must obtain a fresh `ek_…` client token from your
  /// own backend. Permanent Decart credentials are rejected and must never be
  /// embedded in a mobile app. There is deliberately no raw API-key overload
  /// on this production method; see [initializeForDevelopment] for local debug
  /// prototypes.
  ///
  /// Throws [DecartVtonException] with [VtonErrorCode.invalidApiKey] when the
  /// provider returns a blank or permanent credential.
  ///
  /// **Platform divergence on the base URLs.** Android accepts
  /// [signalingBaseUrl] and [httpBaseUrl] independently. The iOS SDK takes only
  /// one base URL and derives the signalling endpoint from it by swapping
  /// `https://` for `wss://`, so on iOS [signalingBaseUrl] is ignored. Unless
  /// you are pointing at a non-default environment the two defaults already
  /// agree, and this never matters; if you do override them, keep them
  /// consistent with that rule.
  Future<void> initialize({
    required VtonClientTokenProvider clientTokenProvider,
    String signalingBaseUrl = 'wss://api.decart.ai',
    String httpBaseUrl = 'https://api.decart.ai',
    VtonLogLevel logLevel = VtonLogLevel.warn,
    bool force = false,
  }) => _serialize(
    () => _initializeWithConfiguration(
      _ClientConfiguration(
        credentialProvider: clientTokenProvider,
        credentialKind: _CredentialKind.clientToken,
        signalingBaseUrl: signalingBaseUrl,
        httpBaseUrl: httpBaseUrl,
        logLevel: logLevel,
      ),
      force: force,
    ),
  );

  /// Configures the native client with a permanent API key for local
  /// development and disposable prototypes only.
  ///
  /// This convenience method accepts a `dct_…` key directly so a developer can
  /// test without first deploying a token server. It throws [StateError] in
  /// profile and release builds, preventing this path from being shipped as a
  /// production authentication strategy.
  ///
  /// Even in debug builds, the key is compiled into the application and can be
  /// extracted. Use a separate test key, keep it out of source control, rotate
  /// it after shared testing, and never distribute the resulting build.
  /// Production apps must use [initialize] with a [VtonClientTokenProvider].
  /// Follow Decart's
  /// [client-token guide](https://docs.platform.decart.ai/getting-started/client-tokens)
  /// before moving the integration to production.
  Future<void> initializeForDevelopment({
    required String apiKey,
    String signalingBaseUrl = 'wss://api.decart.ai',
    String httpBaseUrl = 'https://api.decart.ai',
    VtonLogLevel logLevel = VtonLogLevel.warn,
    bool force = false,
  }) => _serialize(() {
    _assertNotDisposed();
    if (!kDebugMode) {
      throw StateError(
        'initializeForDevelopment() is disabled in profile and release builds. '
        'Use initialize(clientTokenProvider: ...) with short-lived ek_ tokens.',
      );
    }
    return _initializeWithConfiguration(
      _ClientConfiguration(
        credentialProvider: () async => apiKey,
        credentialKind: _CredentialKind.developmentApiKey,
        signalingBaseUrl: signalingBaseUrl,
        httpBaseUrl: httpBaseUrl,
        logLevel: logLevel,
      ),
      force: force,
    );
  });

  /// Opens a realtime session and starts publishing the camera.
  ///
  /// Completes once the session is established — that is, once the native SDK
  /// reports a connected state and the transformed track is available. From
  /// that point a `VtonRemoteView` will show output and [setOutfit] is legal.
  ///
  /// [initialOutfit] is applied as part of the connection handshake rather than
  /// as a follow-up call, which is a round-trip faster than connecting and then
  /// calling [setOutfit].
  ///
  /// Any existing session is torn down first, so calling [connect] twice is
  /// safe (though wasteful — to change the outfit, use [setOutfit]; reconnecting
  /// is never necessary for that).
  ///
  /// Throws [DecartVtonException]:
  /// - [VtonErrorCode.notInitialized] if [initialize] has not run;
  /// - [VtonErrorCode.permissionDenied] if camera permission is missing;
  /// - [VtonErrorCode.cameraUnavailable] on the iOS Simulator, or if the camera
  ///   is held by another app;
  /// - [VtonErrorCode.connectionTimeout] if setup exceeds [connectTimeout];
  /// - [VtonErrorCode.webrtc] if the network cannot carry WebRTC media —
  ///   run [checkConnectivity] first if you want to detect that up front.
  Future<void> connect({
    required VtonModel model,
    VtonOutfit? initialOutfit,
    VtonCameraFacing camera = VtonCameraFacing.front,
    VtonMirrorMode mirror = VtonMirrorMode.auto,
    VtonResolution? resolution,
    VtonVideoConfig? video,
    Duration connectTimeout = const Duration(seconds: 30),
  }) => _serialize(
    () => _connectUnsafe(
      model: model,
      initialOutfit: initialOutfit,
      camera: camera,
      mirror: mirror,
      resolution: resolution,
      video: video,
      connectTimeout: connectTimeout,
      refreshToken: true,
    ),
  );

  Future<void> _connectUnsafe({
    required VtonModel model,
    required VtonOutfit? initialOutfit,
    required VtonCameraFacing camera,
    required VtonMirrorMode mirror,
    required VtonResolution? resolution,
    required VtonVideoConfig? video,
    required Duration connectTimeout,
    required bool refreshToken,
  }) async {
    _assertNotDisposed();
    _assertInitialized();

    if (initialOutfit != null) {
      await _validateOutfit(initialOutfit, model);
    }
    if ((model == VtonModel.lucyVtonLatest || model == VtonModel.lucyVton35) &&
        resolution == VtonResolution.p1080) {
      throw const DecartVtonException.local(
        VtonErrorCode.invalidInput,
        'VTON 3.5 supports only 720p output. Use VtonResolution.p720 or leave '
        'resolution unset.',
      );
    }
    var reusedInitialCredential = false;
    if (refreshToken) {
      if (_nativeClientCredentialUnused) {
        // initialize() has already created a native client with a credential
        // that has not opened a session. Consume it rather than calling the
        // application's token endpoint twice for the common
        // initialize() -> connect() sequence.
        _nativeClientCredentialUnused = false;
        reusedInitialCredential = true;
      } else {
        await _refreshNativeClient();
        _nativeClientCredentialUnused = false;
      }
    }

    _model = model;
    _facing = camera;
    _sessionId = null;
    _lastConnect = _ConnectRequest(
      model: model,
      camera: camera,
      mirror: mirror,
      resolution: resolution,
      video: video,
      connectTimeout: connectTimeout,
    );

    final effectiveVideo = video ?? const VtonVideoConfig();
    final connectArguments = <String, Object?>{
      'model': model.id,
      'width': model.width,
      'height': model.height,
      'fps': model.fps,
      'supportsReferenceImage': model.supportsReferenceImage,
      'facing': camera.name,
      'mirror': mirror.name,
      'resolution': resolution?.wireValue,
      'connectTimeoutMs': connectTimeout.inMilliseconds,
      'video': effectiveVideo.toMap(),
      'prompt': initialOutfit?.prompt,
      'referenceImage': initialOutfit?.referenceImage,
      'referenceImagePath': initialOutfit?.hasReferenceImagePath == true
          ? initialOutfit!.referenceImagePath!.trim()
          : null,
      'enhance': initialOutfit?.enhance ?? true,
    };

    String? sessionId;
    try {
      sessionId = await _platform.connect(connectArguments);
    } on DecartVtonException catch (error) {
      if (!reusedInitialCredential ||
          error.code != VtonErrorCode.invalidApiKey) {
        rethrow;
      }

      // The initialized client may have sat unused long enough for its token
      // to expire. Refresh only after an authoritative auth rejection, then
      // retry once. A second failure is returned to the caller unchanged.
      await _refreshNativeClient();
      _nativeClientCredentialUnused = false;
      sessionId = await _platform.connect(connectArguments);
    }

    _sessionId ??= sessionId;
    _currentOutfit = initialOutfit;
    _sessionWasDisconnected = false;
  }

  /// Replaces the entire try-on state on the live session.
  ///
  /// ## Whole-state semantics — read this once
  ///
  /// This maps onto the SDK's set-image / set-prompt message, which **replaces
  /// the whole state**. Anything you leave out is *cleared server-side*:
  ///
  /// ```dart
  /// await vton.setOutfit(prompt: 'a red hoodie', referenceImage: garment);
  /// await vton.setOutfit(prompt: 'in charcoal grey');   // garment is now GONE
  /// ```
  ///
  /// To change one field and keep the rest, pass a whole outfit built from the
  /// previous one:
  ///
  /// ```dart
  /// await vton.setOutfit(
  ///   outfit: vton.currentOutfit!.copyWith(prompt: 'in charcoal grey'),
  /// );
  /// ```
  ///
  /// ## Arguments
  ///
  /// Either pass [outfit], or pass some combination of [prompt], one of
  /// [referenceImage] or [referenceImagePath], and [enhance] — not both forms
  /// at once. Prefer [referenceImagePath] when the image already exists on
  /// disk; native code reads it without copying all of its bytes through Dart.
  ///
  /// At least one of a non-blank prompt or a reference image is required. An
  /// update with neither would clear everything, which is almost never what
  /// anyone means, so it throws [ArgumentError] before touching the platform
  /// channel. If you really do want to drop the garment image and keep only
  /// text, that is `setOutfit(prompt: '…')` — explicit and legal.
  ///
  /// ## Timing
  ///
  /// Completes when the **server acks** the change, not when the request is
  /// sent — so awaiting it is a meaningful "the outfit is applied" signal. The
  /// transformed video takes a further moment to reflect it.
  ///
  /// Throws:
  /// - [ArgumentError] for the argument-shape violations above;
  /// - [DecartVtonException] with [VtonErrorCode.notConnected] if there is no
  ///   live session;
  /// - [VtonErrorCode.invalidInput] if a [referenceImage] is supplied for a
  ///   model where [VtonModel.supportsReferenceImage] is `false`;
  /// - [VtonErrorCode.promptRejected] if the server nacks the update;
  /// - [VtonErrorCode.cancelled] if a later `setOutfit` supersedes this one.
  Future<void> setOutfit({
    String? prompt,
    Uint8List? referenceImage,
    String? referenceImagePath,
    bool enhance = true,
    VtonOutfit? outfit,
    Duration timeout = const Duration(seconds: 30),
  }) => _serialize(
    () => _setOutfitUnsafe(
      prompt: prompt,
      referenceImage: referenceImage,
      referenceImagePath: referenceImagePath,
      enhance: enhance,
      outfit: outfit,
      timeout: timeout,
    ),
  );

  Future<void> _setOutfitUnsafe({
    required String? prompt,
    required Uint8List? referenceImage,
    required String? referenceImagePath,
    required bool enhance,
    required VtonOutfit? outfit,
    required Duration timeout,
  }) async {
    _assertNotDisposed();
    _assertInitialized();

    if (outfit != null &&
        (prompt != null ||
            referenceImage != null ||
            referenceImagePath != null ||
            enhance != true)) {
      throw ArgumentError(
        'Pass either outfit:, or the individual prompt:/referenceImage:/'
        'referenceImagePath:/enhance: arguments — not both. Mixing them is '
        'ambiguous about which wins.',
      );
    }

    final model = _model;
    if (model == null) {
      throw const DecartVtonException.local(
        VtonErrorCode.notConnected,
        'setOutfit() requires a live session. Call connect() first.',
      );
    }

    // Validate the raw arguments *before* constructing a VtonOutfit, so callers
    // get this method's contextual message rather than the value class's assert.
    await _validateFields(
      prompt: outfit?.prompt ?? prompt,
      referenceImage: outfit?.referenceImage ?? referenceImage,
      referenceImagePath: outfit?.referenceImagePath ?? referenceImagePath,
      model: model,
    );

    final effective =
        outfit ??
        VtonOutfit(
          prompt: prompt,
          referenceImage: referenceImage,
          referenceImagePath: referenceImagePath,
          enhance: enhance,
        );

    if (!_connectionState.isLive) {
      throw DecartVtonException.local(
        VtonErrorCode.notConnected,
        'setOutfit() requires a live session; the current state is '
        '${_connectionState.name}. Wait for VtonConnectionState.connected or '
        'generating before sending outfit updates.',
      );
    }

    await _platform.setOutfit(<String, Object?>{
      'prompt': effective.hasPrompt ? effective.prompt!.trim() : null,
      'referenceImage': effective.hasReferenceImage
          ? effective.referenceImage
          : null,
      'referenceImagePath': effective.hasReferenceImagePath
          ? effective.referenceImagePath!.trim()
          : null,
      'enhance': effective.enhance,
      'timeoutMs': timeout.inMilliseconds,
    });

    _currentOutfit = effective;
  }

  /// Flips between the front and back cameras.
  ///
  /// The existing published video track is updated in place, so this does not
  /// disconnect, request another client token, create a new Decart session, or
  /// lose [currentOutfit]. A short camera-capture interruption can still occur
  /// while the device opens the other lens.
  ///
  /// Returns the camera now in use.
  ///
  /// Throws [DecartVtonException] with [VtonErrorCode.notConnected] if there is
  /// no session to switch.
  Future<VtonCameraFacing> switchCamera() => _serialize(() async {
    _assertNotDisposed();
    _assertInitialized();
    if (_lastConnect == null || !_connectionState.isLive) {
      throw const DecartVtonException.local(
        VtonErrorCode.notConnected,
        'switchCamera() requires a live session.',
      );
    }

    final target = _facing.flipped;
    final selected = await _platform.switchCamera(facing: target.name);
    _facing = selected == VtonCameraFacing.back.name
        ? VtonCameraFacing.back
        : VtonCameraFacing.front;
    return _facing;
  });

  /// Probes whether the network can carry a realtime session, without opening
  /// one.
  ///
  /// Uses a throwaway STUN probe: no session is created, no model time is
  /// billed. Worth running before you show a "start try-on" button on a network
  /// you do not control.
  ///
  /// The SDKs also offer a *deep* probe that opens a real short-lived session to
  /// measure true end-to-end latency. It is not exposed here because it costs
  /// real GPU time; see IMPLEMENTATION.md if you need it.
  Future<VtonConnectivityReport> checkConnectivity({
    Duration timeout = const Duration(seconds: 5),
  }) => _serialize(() async {
    _assertNotDisposed();
    _assertInitialized();
    return _platform.checkConnectivity(timeoutMs: timeout.inMilliseconds);
  });

  /// Ends the session and releases the camera, keeping the native client alive.
  ///
  /// Safe to call when not connected. Call this when the app is backgrounded —
  /// holding a WebRTC session open in the background burns battery and the
  /// session will be dropped by the OS anyway. See `VtonLifecycleObserver` for
  /// a ready-made way to wire that up.
  Future<void> disconnect() => _serialize(_disconnectUnsafe);

  Future<void> _disconnectUnsafe() async {
    if (_disposed || !_initialized) return;
    await _platform.disconnect();
    _sessionId = null;
    // Native state events travel over a separate asynchronous channel and can
    // arrive after this method completes. Remember the completed operation so
    // an immediate foreground transition does not mistake a stale `connected`
    // event for a still-live session and skip restoration.
    _sessionWasDisconnected = true;
  }

  /// Reopens the previous session after an app-lifecycle interruption.
  ///
  /// A fresh client token is requested and the latest outfit and camera facing
  /// are restored. Does nothing when there is no previous session.
  Future<void> resumeLastSession() => _serialize(() async {
    _assertNotDisposed();
    _assertInitialized();
    final previous = _lastConnect;
    if (previous == null ||
        (!_sessionWasDisconnected && _connectionState.isInSession)) {
      return;
    }
    await _connectUnsafe(
      model: previous.model,
      initialOutfit: _currentOutfit,
      camera: _facing,
      mirror: previous.mirror,
      resolution: previous.resolution,
      video: previous.video,
      connectTimeout: previous.connectTimeout,
      refreshToken: true,
    );
  });

  /// Releases every native resource, including the client itself.
  ///
  /// After this the instance is unusable and calling anything else throws
  /// [StateError] — but the cached singleton is cleared, so a subsequent
  /// `DecartVton()` hands back a fresh, usable instance. Hold onto the result
  /// of `DecartVton()` rather than a variable captured before `dispose`.
  Future<void> dispose() => _serialize(() async {
    if (_disposed) return;
    _disposed = true;
    // Without this, `DecartVton()` would keep returning the dead instance and
    // every call on it would throw StateError with no supported recovery.
    if (identical(_instance, this)) _instance = null;
    await _nativeEvents?.cancel();
    _nativeEvents = null;
    if (_initialized) {
      try {
        await _platform.release();
      } on DecartVtonException {
        // Best-effort teardown: a failure to release should not mask whatever
        // the caller was actually doing.
      }
    }
    _initialized = false;
    _clientConfiguration = null;
    _nativeClientCredentialUnused = false;
    await _eventController.close();
    await _stateController.close();
    await _errorController.close();
  });

  // ─────────────────────────────────────────────────────────── internals ────

  void _attachNativeEvents() {
    _nativeEvents ??= _platform.events.listen(
      _handleEvent,
      onError: (Object error, StackTrace stack) {
        final e = error is DecartVtonException
            ? error
            : DecartVtonException(
                VtonErrorCode.unknown,
                'Event channel failure: $error',
              );
        _emitError(e);
      },
    );
  }

  void _handleEvent(VtonEvent event) {
    switch (event) {
      case VtonConnectionStateChanged(:final state):
        _connectionState = state;
        if (!_stateController.isClosed) _stateController.add(state);
      case VtonSessionStarted(:final sessionId):
        _sessionId = sessionId;
      case VtonErrorOccurred(:final error):
        _emitError(error);
      case VtonGenerationTick():
      case VtonRemoteStreamUpdated():
      case VtonLocalStreamUpdated():
      case VtonConnectionQualityChanged():
        break;
    }
    if (!_eventController.isClosed) _eventController.add(event);
  }

  void _emitError(DecartVtonException error) {
    if (!_errorController.isClosed) _errorController.add(error);
  }

  Future<void> _initializeWithConfiguration(
    _ClientConfiguration configuration, {
    required bool force,
  }) async {
    _assertNotDisposed();
    if (_initialized && !force) return;
    final previousConfiguration = _clientConfiguration;
    _clientConfiguration = configuration;
    try {
      await _refreshNativeClient();
    } catch (_) {
      _clientConfiguration = previousConfiguration;
      rethrow;
    }
    _attachNativeEvents();
  }

  Future<void> _refreshNativeClient() async {
    final configuration = _clientConfiguration;
    if (configuration == null) {
      throw const DecartVtonException.local(
        VtonErrorCode.notInitialized,
        'Call initialize(clientTokenProvider: ...) before using the plugin, or '
        'initializeForDevelopment(apiKey: ...) in a local debug build.',
      );
    }
    final rawCredential = await configuration.credentialProvider();
    final credential = switch (configuration.credentialKind) {
      _CredentialKind.clientToken => _validateClientToken(rawCredential),
      _CredentialKind.developmentApiKey => _validateDevelopmentApiKey(
        rawCredential,
      ),
    };
    if (_initialized) {
      await _platform.release();
      _initialized = false;
      _nativeClientCredentialUnused = false;
    }
    try {
      await _platform.initialize(
        clientToken: credential,
        signalingBaseUrl: configuration.signalingBaseUrl,
        httpBaseUrl: configuration.httpBaseUrl,
        logLevel: configuration.logLevel.name,
      );
      _initialized = true;
      _nativeClientCredentialUnused = true;
    } catch (_) {
      // Do not claim a released or partially-created native client is usable.
      _initialized = false;
      _nativeClientCredentialUnused = false;
      rethrow;
    }
  }

  String _validateClientToken(String value) {
    final token = value.trim();
    if (!token.startsWith('ek_')) {
      throw const DecartVtonException.local(
        VtonErrorCode.invalidApiKey,
        'The token provider must return a short-lived Decart client token '
        'beginning with ek_. Permanent or unrecognized credentials are not '
        'accepted by this mobile SDK.',
      );
    }
    return token;
  }

  String _validateDevelopmentApiKey(String value) {
    final apiKey = value.trim();
    if (!apiKey.startsWith('dct_')) {
      throw const DecartVtonException.local(
        VtonErrorCode.invalidApiKey,
        'initializeForDevelopment() requires a Decart API key beginning with '
        'dct_. Use initialize(clientTokenProvider: ...) for ek_ client tokens.',
      );
    }
    return apiKey;
  }

  /// Chains operations while keeping the tail successful after a failure.
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then<T>((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _validateOutfit(VtonOutfit outfit, VtonModel model) =>
      _validateFields(
        prompt: outfit.prompt,
        referenceImage: outfit.referenceImage,
        referenceImagePath: outfit.referenceImagePath,
        model: model,
      );

  Future<void> _validateFields({
    required String? prompt,
    required Uint8List? referenceImage,
    required String? referenceImagePath,
    required VtonModel model,
  }) async {
    final hasPrompt = prompt != null && prompt.trim().isNotEmpty;
    final hasImageBytes = referenceImage != null && referenceImage.isNotEmpty;
    final hasImagePath =
        referenceImagePath != null && referenceImagePath.trim().isNotEmpty;
    if (hasImageBytes && hasImagePath) {
      throw ArgumentError(
        'Pass either referenceImage or referenceImagePath, not both.',
      );
    }
    final hasImage = hasImageBytes || hasImagePath;
    if (!hasPrompt && !hasImage) {
      throw ArgumentError(
        'An outfit update needs at least a non-blank prompt or a reference '
        'image. The Decart realtime API replaces the entire state on every '
        'update, so an empty update would clear the try-on effect rather than '
        'leave it unchanged. If clearing is genuinely what you want, '
        'disconnect() instead.',
      );
    }
    if (hasImage && !model.supportsReferenceImage) {
      throw DecartVtonException.local(
        VtonErrorCode.invalidInput,
        'Model ${model.id} does not accept a reference image. Use one of the '
        'lucy-vton models (VtonModel.lucyVtonLatest) for garment images, or '
        'send a prompt only.',
      );
    }
    if (hasImageBytes) _validateReferenceImage(referenceImage);
    if (hasImagePath) {
      await _validateReferenceImagePath(referenceImagePath.trim());
    }
  }

  Future<void> _validateReferenceImagePath(String path) async {
    RandomAccessFile? handle;
    try {
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const FileSystemException('Path is not a regular file.');
      }
      if (stat.size > _maxReferenceImageBytes) {
        throw const DecartVtonException.local(
          VtonErrorCode.invalidInput,
          'Reference images must be 5 MB or smaller.',
        );
      }
      handle = await file.open();
      final header = await handle.read(12);
      _validateReferenceImage(header, totalLength: stat.size);
    } on DecartVtonException {
      rethrow;
    } on FileSystemException catch (error) {
      throw DecartVtonException.local(
        VtonErrorCode.invalidInput,
        'Could not read reference image at "$path": ${error.message}',
      );
    } finally {
      await handle?.close();
    }
  }

  static const int _maxReferenceImageBytes = 5 * 1024 * 1024;

  void _validateReferenceImage(Uint8List bytes, {int? totalLength}) {
    if ((totalLength ?? bytes.length) > _maxReferenceImageBytes) {
      throw const DecartVtonException.local(
        VtonErrorCode.invalidInput,
        'Reference images must be 5 MB or smaller.',
      );
    }
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
    final png =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a;
    final webp =
        bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    if (!jpeg && !png && !webp) {
      throw const DecartVtonException.local(
        VtonErrorCode.invalidInput,
        'Reference images must contain JPEG, PNG, or WebP data.',
      );
    }
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw const DecartVtonException.local(
        VtonErrorCode.notInitialized,
        'Call DecartVton().initialize(clientTokenProvider: ...) before using '
        'the plugin, or initializeForDevelopment(apiKey: ...) in a local '
        'debug build.',
      );
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError(
        'This DecartVton instance has been disposed and cannot be reused.',
      );
    }
  }
}

/// Snapshot of the arguments a session was opened with, so lifecycle recovery
/// can rebuild an identical session.
class _ConnectRequest {
  const _ConnectRequest({
    required this.model,
    required this.camera,
    required this.mirror,
    required this.resolution,
    required this.video,
    required this.connectTimeout,
  });

  final VtonModel model;
  final VtonCameraFacing camera;
  final VtonMirrorMode mirror;
  final VtonResolution? resolution;
  final VtonVideoConfig? video;
  final Duration connectTimeout;
}

class _ClientConfiguration {
  const _ClientConfiguration({
    required this.credentialProvider,
    required this.credentialKind,
    required this.signalingBaseUrl,
    required this.httpBaseUrl,
    required this.logLevel,
  });

  final Future<String> Function() credentialProvider;
  final _CredentialKind credentialKind;
  final String signalingBaseUrl;
  final String httpBaseUrl;
  final VtonLogLevel logLevel;
}

enum _CredentialKind { clientToken, developmentApiKey }
