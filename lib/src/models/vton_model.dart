/// The realtime models this plugin can drive.
///
/// Values, dimensions and frame rates are taken verbatim from the native SDKs'
/// model registries (`RealtimeModels.kt` on Android, `Models.swift` on iOS) at
/// `decart-android` 0.7.10 / `decart-ios` v0.6.10.
///
/// For virtual try-on you want one of the `lucyVton*` entries. The other
/// realtime models are included because the underlying SDKs accept them on the
/// same code path and there is no reason to artificially block them — but note
/// that [supportsReferenceImage] is `false` for the restyle models, which
/// changes how [DecartVton.setOutfit] behaves (see that method's docs).
enum VtonModel {
  /// Virtual try-on, always the newest VTON revision (resolved server-side).
  ///
  /// This is the recommended default.
  lucyVtonLatest._('lucy-vton-latest', 1280, 720, 30, true),

  /// Virtual try-on, pinned to revision 3.5 at 720p.
  lucyVton35._('lucy-vton-3.5', 1280, 720, 30, true),

  /// Virtual try-on, pinned to revision 3.
  lucyVton3._('lucy-vton-3', 1088, 624, 30, true),

  /// Virtual try-on, pinned to revision 2.
  lucyVton2._('lucy-vton-2', 1088, 624, 30, true),

  /// General realtime video editing, always the newest revision.
  lucyLatest._('lucy-latest', 1088, 624, 30, true),

  /// General realtime video editing, pinned to 2.1.
  lucy21._('lucy-2.1', 1088, 624, 30, true),

  /// General realtime video editing, pinned to 2.5 (720p native).
  lucy25._('lucy-2.5', 1280, 720, 30, true),

  /// Style transfer, always the newest revision.
  ///
  /// Does **not** accept a reference image.
  lucyRestyleLatest._('lucy-restyle-latest', 1280, 704, 30, false),

  /// Style transfer, pinned to revision 2.
  ///
  /// Does **not** accept a reference image.
  lucyRestyle2._('lucy-restyle-2', 1280, 704, 30, false);

  const VtonModel._(
    this.id,
    this.width,
    this.height,
    this.fps,
    this.supportsReferenceImage,
  );

  /// The wire identifier the Decart API expects (for example `lucy-vton-latest`).
  final String id;

  /// Native capture width the model expects, in pixels.
  ///
  /// The plugin configures the camera with these dimensions. Capturing at a
  /// different size forces a scale somewhere in the pipeline, which costs
  /// latency and quality — see the streaming best-practices doc.
  final int width;

  /// Native capture height the model expects, in pixels.
  final int height;

  /// Native capture frame rate the model expects.
  final int fps;

  /// Whether this model accepts a garment/character reference image.
  ///
  /// When `false`, any [Uint8List] passed to [DecartVton.setOutfit] is rejected
  /// with a [DecartVtonException] rather than silently dropped, and outfit
  /// updates are sent as plain prompt messages.
  final bool supportsReferenceImage;

  /// Looks a model up by its wire [id], or returns `null` if unknown.
  static VtonModel? fromId(String id) {
    for (final model in VtonModel.values) {
      if (model.id == id) return model;
    }
    return null;
  }
}

/// Output resolution requested from the realtime server.
///
/// Always choose a resolution supported by the selected model. VTON 3.5 and
/// `lucy-vton-latest` currently support only 720p.
enum VtonResolution {
  /// 720p output.
  p720('720p'),

  /// 1080p output. Costs more bandwidth and adds latency.
  p1080('1080p');

  const VtonResolution(this.wireValue);

  /// The string the API expects in the `resolution` query parameter.
  final String wireValue;
}

/// Which physical camera to capture from.
enum VtonCameraFacing {
  /// The user-facing (selfie) camera. The default, and the useful one for
  /// try-on.
  front,

  /// The world-facing camera.
  back;

  /// The opposite facing, used by [DecartVton.switchCamera].
  VtonCameraFacing get flipped => this == VtonCameraFacing.front
      ? VtonCameraFacing.back
      : VtonCameraFacing.front;
}

/// Whether the captured video is horizontally flipped **before** it is sent.
///
/// This is not a display-time mirror. The native SDKs pre-flip the outgoing
/// frames so that anything the server bakes into the returned pixels (such as a
/// watermark) is not itself reversed when the result is displayed.
enum VtonMirrorMode {
  /// Never pre-flip.
  off,

  /// Always pre-flip.
  on,

  /// Pre-flip only when capturing from the front camera. The default.
  auto,
}

/// Verbosity of the native SDK's own logging.
///
/// **Android only.** The Decart iOS SDK has no runtime log-level control at
/// v0.6.10 — it prints errors unconditionally and everything else only when the
/// `ENABLE_DECART_SDK_DUBUG_LOGS=YES` environment variable is set in the Xcode
/// scheme. This value is silently ignored on iOS rather than pretending to work.
///
/// Note also that the Android SDK forces LiveKit's own logger and the native
/// WebRTC logger to `OFF` regardless of this setting, so this controls Decart's
/// logging only.
enum VtonLogLevel {
  /// Everything the SDK logs.
  debug,

  /// Informational and above.
  info,

  /// Warnings and errors only. The default.
  warn,

  /// Errors only.
  error,
}

/// Optional overrides for how video is captured and published.
///
/// The defaults are chosen to be identical on both platforms; the two native
/// SDKs ship *different* defaults (Android VP8 / 2 Mbps, iOS H.264 / 3.5 Mbps),
/// which would otherwise make the same Dart code behave differently per
/// platform. Leave this `null` unless you have measured a reason not to.
class VtonVideoConfig {
  /// Creates a video configuration.
  const VtonVideoConfig({
    this.maxBitrate = 2500000,
    this.maxFramerate = 30,
    this.preferredCodec = 'vp8',
    this.simulcast = true,
  });

  /// Upper bound on publish bitrate, in bits per second.
  final int maxBitrate;

  /// Upper bound on publish frame rate.
  ///
  /// Should normally match [VtonModel.fps].
  final int maxFramerate;

  /// Preferred video codec. `vp8` is recommended for mobile by the Decart
  /// streaming best-practices guide; `h264` and `vp9` are also accepted.
  final String preferredCodec;

  /// Whether to publish simulcast layers.
  final bool simulcast;

  /// Serialises to the platform-channel representation.
  Map<String, Object?> toMap() => <String, Object?>{
    'maxBitrate': maxBitrate,
    'maxFramerate': maxFramerate,
    'preferredCodec': preferredCodec,
    'simulcast': simulcast,
  };

  @override
  String toString() =>
      'VtonVideoConfig(maxBitrate: $maxBitrate, '
      'maxFramerate: $maxFramerate, preferredCodec: $preferredCodec, '
      'simulcast: $simulcast)';
}
