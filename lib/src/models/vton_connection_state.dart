/// Lifecycle of a realtime try-on session.
///
/// This is the **union** of the two native state machines. Android
/// (`ai.decart.sdk.ConnectionState`) has five states; iOS
/// (`DecartRealtimeConnectionState`) has seven. Rather than lossily collapsing
/// iOS down to Android's set, the Dart layer exposes all seven and documents
/// which ones a given platform can actually produce.
enum VtonConnectionState {
  /// Nothing has been started yet. Emitted on iOS only; on Android the initial
  /// state is [disconnected].
  idle,

  /// A connection attempt is in progress.
  connecting,

  /// Connected and ready to accept outfit updates, but the model is not yet
  /// producing transformed frames.
  connected,

  /// Connected and actively transforming video. This is the steady state of a
  /// working session.
  generating,

  /// The connection dropped unexpectedly and the SDK is retrying with backoff.
  ///
  /// Any [VtonRemoteView] rebinds itself automatically when the new stream
  /// arrives — you do not need to rebuild the widget.
  reconnecting,

  /// Not connected. Either never connected, or cleanly torn down.
  disconnected,

  /// The session failed and will not retry. Emitted on iOS only; on Android a
  /// terminal failure surfaces as an entry on `DecartVton.errors` followed by
  /// [disconnected].
  error;

  /// Whether outfit updates can be sent right now.
  bool get isLive =>
      this == VtonConnectionState.connected ||
      this == VtonConnectionState.generating;

  /// Whether a session exists in some form, including one that is still
  /// establishing or recovering.
  bool get isInSession =>
      this == VtonConnectionState.connecting ||
      this == VtonConnectionState.connected ||
      this == VtonConnectionState.generating ||
      this == VtonConnectionState.reconnecting;

  /// Parses the wire representation used on the platform channel.
  static VtonConnectionState fromWire(String? value) {
    switch (value) {
      case 'idle':
        return VtonConnectionState.idle;
      case 'connecting':
        return VtonConnectionState.connecting;
      case 'connected':
        return VtonConnectionState.connected;
      case 'generating':
        return VtonConnectionState.generating;
      case 'reconnecting':
        return VtonConnectionState.reconnecting;
      case 'error':
        return VtonConnectionState.error;
      case 'disconnected':
      default:
        return VtonConnectionState.disconnected;
    }
  }
}

/// A coarse verdict on whether the network is good enough for a smooth session.
enum VtonConnectionQuality {
  /// Comfortable headroom.
  excellent,

  /// Usable; occasional degradation possible.
  good,

  /// Marginal. Expect visible artefacts or latency spikes.
  poor,

  /// Effectively unusable.
  unusable,

  /// Not enough samples yet.
  unknown;

  /// Parses the wire representation used on the platform channel.
  static VtonConnectionQuality fromWire(String? value) {
    switch (value) {
      case 'excellent':
        return VtonConnectionQuality.excellent;
      case 'good':
        return VtonConnectionQuality.good;
      case 'poor':
        return VtonConnectionQuality.poor;
      case 'unusable':
      case 'failed':
        return VtonConnectionQuality.unusable;
      default:
        return VtonConnectionQuality.unknown;
    }
  }
}

/// Result of a pre-flight network probe.
///
/// Produced by `DecartVton.checkConnectivity()`, which opens a throwaway STUN
/// probe — no session is created and no GPU time is billed.
class VtonConnectivityReport {
  /// Creates a report.
  const VtonConnectivityReport({
    required this.quality,
    required this.transport,
    this.roundTripMs,
  });

  /// Overall verdict.
  final VtonConnectionQuality quality;

  /// How media would travel: `udp`, `relay` (TURN) or `failed`.
  ///
  /// `relay` means direct UDP could not be confirmed and a real session would
  /// need TURN; whether that relay path works is not verified by this probe.
  /// `failed` means no WebRTC connectivity was gathered, so a realtime session
  /// is unlikely to establish.
  final String transport;

  /// Measured round-trip time to the STUN server, in milliseconds, if known.
  final int? roundTripMs;

  /// Whether a realtime session is likely to succeed at all.
  bool get isUsable =>
      transport != 'failed' && quality != VtonConnectionQuality.unusable;

  @override
  String toString() =>
      'VtonConnectivityReport(quality: ${quality.name}, '
      'transport: $transport, roundTripMs: $roundTripMs)';
}
