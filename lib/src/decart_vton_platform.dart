import 'dart:async';

import 'package:flutter/services.dart';

import 'models/vton_connection_state.dart';
import 'models/vton_error.dart';
import 'models/vton_event.dart';

/// Channel plumbing. Internal to the package.
///
/// This is the **only** file in the Dart layer that knows about
/// [MethodChannel], [EventChannel], [PlatformException] or untyped maps. Every
/// argument is built here and every reply is parsed here, so the wire contract
/// lives in exactly one place per side (the Kotlin and Swift mirrors are
/// `ChannelCodec.kt` and `ChannelCodec.swift`).
///
/// If this package ever migrates to Pigeon, this file is the only Dart file
/// that has to change.
class DecartVtonPlatform {
  /// Creates a platform binding.
  ///
  /// The channel names are injectable so tests can run several isolated
  /// instances without stepping on each other.
  DecartVtonPlatform({
    String methodChannelName = methodChannelDefaultName,
    String eventChannelName = eventChannelDefaultName,
  })  : _methods = MethodChannel(methodChannelName),
        _events = EventChannel(eventChannelName);

  /// Default name of the method channel.
  static const String methodChannelDefaultName = 'ai.decart.vton/methods';

  /// Default name of the event channel.
  static const String eventChannelDefaultName = 'ai.decart.vton/events';

  /// Platform view type registered by both native sides.
  static const String videoViewType = 'ai.decart.vton/video_view';

  final MethodChannel _methods;
  final EventChannel _events;

  /// The raw method channel. Exposed for tests only.
  MethodChannel get methodChannel => _methods;

  // ───────────────────────────────────────────────────────────── methods ────

  /// Creates the native client.
  Future<void> initialize({
    required String apiKey,
    required String signalingBaseUrl,
    required String httpBaseUrl,
    required String logLevel,
  }) =>
      _invokeVoid('initialize', <String, Object?>{
        'apiKey': apiKey,
        'signalingBaseUrl': signalingBaseUrl,
        'httpBaseUrl': httpBaseUrl,
        'logLevel': logLevel,
      });

  /// Opens a realtime session. Completes when the session is established.
  ///
  /// Returns the server-assigned session id when the platform provides one.
  Future<String?> connect(Map<String, Object?> args) async {
    final result = await _invoke<Map<Object?, Object?>>('connect', args);
    return result?['sessionId'] as String?;
  }

  /// Replaces the whole try-on state.
  Future<void> setOutfit(Map<String, Object?> args) =>
      _invokeVoid('setOutfit', args);

  /// Tears the session down but keeps the native client alive.
  Future<void> disconnect() =>
      _invokeVoid('disconnect', const <String, Object?>{});

  /// Releases the native client and every resource it owns.
  Future<void> release() => _invokeVoid('release', const <String, Object?>{});

  /// Whether the native side currently has a live session.
  Future<bool> isConnected() async {
    final result =
        await _invoke<bool>('isConnected', const <String, Object?>{});
    return result ?? false;
  }

  /// Runs a STUN-only pre-flight probe.
  Future<VtonConnectivityReport> checkConnectivity({
    required int timeoutMs,
  }) async {
    final result = await _invoke<Map<Object?, Object?>>(
      'checkConnectivity',
      <String, Object?>{'timeoutMs': timeoutMs},
    );
    return VtonConnectivityReport(
      quality: VtonConnectionQuality.fromWire(result?['quality'] as String?),
      transport: (result?['transport'] as String?) ?? 'failed',
      roundTripMs: _asInt(result?['roundTripMs']),
    );
  }

  // ────────────────────────────────────────────────────────────── events ────

  /// Decoded stream of native events.
  ///
  /// Unrecognised event types are dropped rather than thrown on, so adding a
  /// new native event never breaks an older Dart layer.
  Stream<VtonEvent> get events => _events
      .receiveBroadcastStream()
      .map<VtonEvent?>(_decodeEvent)
      .where((VtonEvent? e) => e != null)
      .cast<VtonEvent>()
      .handleError(_rethrowAsDecartException);

  static VtonEvent? _decodeEvent(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<Object?, Object?>();
    switch (map['type'] as String?) {
      case 'connectionState':
        return VtonConnectionStateChanged(
          VtonConnectionState.fromWire(map['state'] as String?),
        );
      case 'sessionStarted':
        final id = map['sessionId'] as String?;
        if (id == null) return null;
        return VtonSessionStarted(
          sessionId: id,
          subscribeToken: map['subscribeToken'] as String?,
        );
      case 'generationTick':
        final seconds = _asDouble(map['seconds']) ?? 0;
        return VtonGenerationTick(
          Duration(milliseconds: (seconds * 1000).round()),
        );
      case 'remoteStreamUpdated':
        return const VtonRemoteStreamUpdated();
      case 'localStreamUpdated':
        return const VtonLocalStreamUpdated();
      case 'connectionQuality':
        return VtonConnectionQualityChanged(
          quality: VtonConnectionQuality.fromWire(map['quality'] as String?),
          roundTripMs: _asInt(map['roundTripMs']),
          packetLoss: _asDouble(map['packetLoss']),
          jitterMs: _asInt(map['jitterMs']),
        );
      case 'error':
        final nativeCode = map['code'] as String?;
        return VtonErrorOccurred(
          DecartVtonException(
            VtonErrorCode.fromNative(nativeCode),
            (map['message'] as String?) ?? 'Unknown native error',
            nativeCode: nativeCode,
            details: map['details'],
          ),
        );
      default:
        return null;
    }
  }

  static Never _rethrowAsDecartException(Object error, StackTrace stackTrace) {
    if (error is PlatformException) {
      Error.throwWithStackTrace(_convert(error), stackTrace);
    }
    Error.throwWithStackTrace(error, stackTrace);
  }

  // ─────────────────────────────────────────────────────────── internals ────

  Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e, s) {
      Error.throwWithStackTrace(_convert(e), s);
    } on MissingPluginException catch (e, s) {
      Error.throwWithStackTrace(
        DecartVtonException(
          VtonErrorCode.notInitialized,
          'The decart_vton_flutter plugin is not registered on this platform. '
          'This package supports Android and iOS only. (${e.message})',
        ),
        s,
      );
    }
  }

  Future<void> _invokeVoid(String method, Map<String, Object?> args) async {
    await _invoke<void>(method, args);
  }

  static DecartVtonException _convert(PlatformException e) =>
      DecartVtonException(
        VtonErrorCode.fromNative(e.code),
        e.message ?? 'The platform reported an error with no message.',
        nativeCode: e.code,
        details: e.details,
      );

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is num) return value.toInt();
    return null;
  }

  static double? _asDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return null;
  }
}
