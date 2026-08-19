import 'package:flutter/foundation.dart';

import 'vton_connection_state.dart';
import 'vton_error.dart';

/// Something that happened during a realtime session.
///
/// This is a Dart 3 `sealed` hierarchy, so a `switch` over it is checked for
/// exhaustiveness by the analyser:
///
/// ```dart
/// vton.events.listen((event) {
///   switch (event) {
///     case VtonConnectionStateChanged(:final state): _onState(state);
///     case VtonSessionStarted(:final sessionId):     _log(sessionId);
///     case VtonGenerationTick(:final elapsed):       _tick(elapsed);
///     case VtonRemoteStreamUpdated():                break;
///     case VtonLocalStreamUpdated():                 break;
///     case VtonConnectionQualityChanged(:final quality): _quality(quality);
///     case VtonErrorOccurred(:final error):          _error(error);
///   }
/// });
/// ```
@immutable
sealed class VtonEvent {
  /// Const constructor for subclasses.
  const VtonEvent();
}

/// The session moved to a new [state].
final class VtonConnectionStateChanged extends VtonEvent {
  /// Creates the event.
  const VtonConnectionStateChanged(this.state);

  /// The new state.
  final VtonConnectionState state;

  @override
  String toString() => 'VtonConnectionStateChanged(${state.name})';
}

/// The server accepted the session and assigned it an id.
final class VtonSessionStarted extends VtonEvent {
  /// Creates the event.
  const VtonSessionStarted({required this.sessionId, this.subscribeToken});

  /// Server-assigned session identifier. Worth logging — support requests are
  /// much easier to answer with one.
  final String sessionId;

  /// Token a *viewer* client could use to subscribe to the same room without
  /// seeing the publisher's API key.
  ///
  /// Emitted on Android only; the iOS SDK does not surface it at v0.6.10.
  /// Building a viewer experience on top of it is outside this plugin's scope.
  final String? subscribeToken;

  @override
  String toString() => 'VtonSessionStarted($sessionId)';
}

/// A once-per-second heartbeat while the model is generating.
///
/// Useful for showing session duration and for enforcing your own time caps.
final class VtonGenerationTick extends VtonEvent {
  /// Creates the event.
  const VtonGenerationTick(this.elapsed);

  /// Time elapsed since generation started.
  final Duration elapsed;

  @override
  String toString() => 'VtonGenerationTick(${elapsed.inSeconds}s)';
}

/// A new transformed video track arrived.
///
/// This happens once at connect and again after every automatic reconnect.
/// **You do not need to act on it** — any live [VtonRemoteView] is re-bound
/// natively. It is exposed for logging and analytics.
final class VtonRemoteStreamUpdated extends VtonEvent {
  /// Creates the event.
  const VtonRemoteStreamUpdated();

  @override
  String toString() => 'VtonRemoteStreamUpdated()';
}

/// A new local camera track was created (initial capture, or camera switch).
final class VtonLocalStreamUpdated extends VtonEvent {
  /// Creates the event.
  const VtonLocalStreamUpdated();

  @override
  String toString() => 'VtonLocalStreamUpdated()';
}

/// A refreshed in-session network-quality sample.
///
/// Arrives every few seconds while publishing. The [quality] level is debounced
/// natively; the raw metrics are not.
final class VtonConnectionQualityChanged extends VtonEvent {
  /// Creates the event.
  const VtonConnectionQualityChanged({
    required this.quality,
    this.roundTripMs,
    this.packetLoss,
    this.jitterMs,
  });

  /// The debounced quality verdict.
  final VtonConnectionQuality quality;

  /// Round-trip time in milliseconds, if measured.
  final int? roundTripMs;

  /// Upstream packet loss as a fraction between 0 and 1, if measured.
  final double? packetLoss;

  /// Upstream jitter in milliseconds, if measured.
  final int? jitterMs;

  @override
  String toString() =>
      'VtonConnectionQualityChanged(${quality.name}, '
      'rtt: $roundTripMs, loss: $packetLoss, jitter: $jitterMs)';
}

/// A non-fatal error was reported mid-session.
///
/// Fatal errors are thrown from the method that caused them instead. Note the
/// platform divergence documented on `DecartVton.errors`: Android reports more
/// mid-session errors here than iOS does, because the Android SDK has a
/// dedicated error flow and the iOS SDK mostly throws.
final class VtonErrorOccurred extends VtonEvent {
  /// Creates the event.
  const VtonErrorOccurred(this.error);

  /// The error.
  final DecartVtonException error;

  @override
  String toString() => 'VtonErrorOccurred($error)';
}
