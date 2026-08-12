import 'dart:async';

// Uint8List comes from foundation.dart's re-export of dart:typed_data;
// importing it directly is flagged as unnecessary.
import 'package:flutter/foundation.dart';

import 'decart_vton_platform.dart';
import 'models/vton_connection_state.dart';
import 'models/vton_error.dart';
import 'models/vton_event.dart';
import 'models/vton_model.dart';
import 'models/vton_outfit.dart';

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
/// await vton.initialize(apiKey: dotenv.env['DECART_API_KEY']!);
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

  /// Whether [initialize] has completed successfully.
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

  /// Creates the native Decart client.
  ///
  /// Call once before [connect]. Calling it again while already initialised is
  /// a no-op unless [force] is set, in which case the existing client is
  /// released first (useful when rotating a short-lived client token).
  ///
  /// [apiKey] is passed through opaquely. In development that is a permanent
  /// key (`dct_…`) loaded from `.env`; in production it should be a short-lived
  /// client token (`ek_…`) minted by your own backend. The plugin cannot tell
  /// the difference and does not need to — see the README's security section.
  ///
  /// Throws [DecartVtonException] with [VtonErrorCode.invalidApiKey] if the key
  /// is blank.
  ///
  /// **Platform divergence on the base URLs.** Android accepts
  /// [signalingBaseUrl] and [httpBaseUrl] independently. The iOS SDK takes only
  /// one base URL and derives the signalling endpoint from it by swapping
  /// `https://` for `wss://`, so on iOS [signalingBaseUrl] is ignored. Unless
  /// you are pointing at a non-default environment the two defaults already
  /// agree, and this never matters; if you do override them, keep them
  /// consistent with that rule.
  Future<void> initialize({
    required String apiKey,
    String signalingBaseUrl = 'wss://api.decart.ai',
    String httpBaseUrl = 'https://api.decart.ai',
    VtonLogLevel logLevel = VtonLogLevel.warn,
    bool force = false,
  }) async {
    _assertNotDisposed();
    if (apiKey.trim().isEmpty) {
      throw const DecartVtonException.local(
        VtonErrorCode.invalidApiKey,
        'apiKey must not be empty. In development, load DECART_API_KEY from '
        'your .env file; in production, fetch a short-lived client token from '
        'your backend.',
      );
    }
    if (_initialized && !force) return;
    if (_initialized && force) {
      await _platform.release();
      _initialized = false;
    }

    await _platform.initialize(
      apiKey: apiKey.trim(),
      signalingBaseUrl: signalingBaseUrl,
      httpBaseUrl: httpBaseUrl,
      logLevel: logLevel.name,
    );
    _initialized = true;
    _attachNativeEvents();
  }

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
  }) async {
    _assertNotDisposed();
    _assertInitialized();

    if (initialOutfit != null) {
      _validateOutfit(initialOutfit, model);
    }

    _model = model;
    _facing = camera;
    _sessionId = null;
    _lastConnect = _ConnectRequest(
      model: model,
      mirror: mirror,
      resolution: resolution,
      video: video,
      connectTimeout: connectTimeout,
    );

    final effectiveVideo = video ?? const VtonVideoConfig();
    final sessionId = await _platform.connect(<String, Object?>{
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
      'enhance': initialOutfit?.enhance ?? true,
    });

    _sessionId ??= sessionId;
    _currentOutfit = initialOutfit;
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
  /// Either pass [outfit], or pass some combination of [prompt],
  /// [referenceImage] and [enhance] — not both forms at once.
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
    bool enhance = true,
    VtonOutfit? outfit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _assertNotDisposed();
    _assertInitialized();

    if (outfit != null &&
        (prompt != null || referenceImage != null || enhance != true)) {
      throw ArgumentError(
        'Pass either outfit:, or the individual prompt:/referenceImage:/'
        'enhance: arguments — not both. Mixing them is ambiguous about which '
        'wins.',
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
    _validateFields(
      prompt: outfit?.prompt ?? prompt,
      referenceImage: outfit?.referenceImage ?? referenceImage,
      model: model,
    );

    final effective = outfit ??
        VtonOutfit(
          prompt: prompt,
          referenceImage: referenceImage,
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
      'referenceImage':
          effective.hasReferenceImage ? effective.referenceImage : null,
      'enhance': effective.enhance,
      'timeoutMs': timeout.inMilliseconds,
    });

    _currentOutfit = effective;
  }

  /// Flips between the front and back cameras.
  ///
  /// **This reconnects the session.** Neither native SDK exposes an in-session
  /// camera flip on its public API at the versions this plugin targets
  /// (`decart-android` 0.7.9, `decart-ios` v0.6.9), so the honest
  /// implementation is: tear the session down, rebuild the capture stream on
  /// the other camera, and connect again with the same model, settings and
  /// [currentOutfit]. Expect roughly a second of black frames and a new
  /// [sessionId].
  ///
  /// It is implemented in Dart rather than natively precisely so that both
  /// platforms do the identical thing. See IMPLEMENTATION.md for the faster
  /// per-platform path if the reconnect is unacceptable for your use case.
  ///
  /// Returns the camera now in use.
  ///
  /// Throws [DecartVtonException] with [VtonErrorCode.notConnected] if there is
  /// no session to switch.
  Future<VtonCameraFacing> switchCamera() async {
    _assertNotDisposed();
    _assertInitialized();
    final previous = _lastConnect;
    if (previous == null || !_connectionState.isInSession) {
      throw const DecartVtonException.local(
        VtonErrorCode.notConnected,
        'switchCamera() requires a live session.',
      );
    }

    final target = _facing.flipped;
    await disconnect();
    await connect(
      model: previous.model,
      initialOutfit: _currentOutfit,
      camera: target,
      mirror: previous.mirror,
      resolution: previous.resolution,
      video: previous.video,
      connectTimeout: previous.connectTimeout,
    );
    return _facing;
  }

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
  }) {
    _assertNotDisposed();
    _assertInitialized();
    return _platform.checkConnectivity(timeoutMs: timeout.inMilliseconds);
  }

  /// Ends the session and releases the camera, keeping the native client alive.
  ///
  /// Safe to call when not connected. Call this when the app is backgrounded —
  /// holding a WebRTC session open in the background burns battery and the
  /// session will be dropped by the OS anyway. See `VtonLifecycleObserver` for
  /// a ready-made way to wire that up.
  Future<void> disconnect() async {
    if (_disposed || !_initialized) return;
    await _platform.disconnect();
    _sessionId = null;
  }

  /// Releases every native resource, including the client itself.
  ///
  /// After this the instance is unusable and calling anything else throws
  /// [StateError] — but the cached singleton is cleared, so a subsequent
  /// `DecartVton()` hands back a fresh, usable instance. Hold onto the result
  /// of `DecartVton()` rather than a variable captured before `dispose`.
  Future<void> dispose() async {
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
    await _eventController.close();
    await _stateController.close();
    await _errorController.close();
  }

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

  void _validateOutfit(VtonOutfit outfit, VtonModel model) => _validateFields(
        prompt: outfit.prompt,
        referenceImage: outfit.referenceImage,
        model: model,
      );

  void _validateFields({
    required String? prompt,
    required Uint8List? referenceImage,
    required VtonModel model,
  }) {
    final hasPrompt = prompt != null && prompt.trim().isNotEmpty;
    final hasImage = referenceImage != null && referenceImage.isNotEmpty;
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
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw const DecartVtonException.local(
        VtonErrorCode.notInitialized,
        'Call DecartVton().initialize(apiKey: ...) before using the plugin.',
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

/// Snapshot of the arguments a session was opened with, so [DecartVton.switchCamera]
/// can rebuild an identical session on the other camera.
class _ConnectRequest {
  const _ConnectRequest({
    required this.model,
    required this.mirror,
    required this.resolution,
    required this.video,
    required this.connectTimeout,
  });

  final VtonModel model;
  final VtonMirrorMode mirror;
  final VtonResolution? resolution;
  final VtonVideoConfig? video;
  final Duration connectTimeout;
}
