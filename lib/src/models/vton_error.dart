/// A normalised failure category.
///
/// The two native SDKs use *different* error-code vocabularies for the same
/// conditions (Android's `ErrorCodes.WEBRTC_ICE_ERROR` versus iOS's
/// `DecartError.webRTCError` / `"WEB_RTC_ERROR"`, for example). This enum is the
/// single vocabulary the Dart layer speaks; the original native string is still
/// available on [DecartVtonException.nativeCode] for bug reports.
enum VtonErrorCode {
  /// `DecartVton.initialize` has not been called, or was called and failed.
  notInitialized,

  /// The call requires a live session and there is none.
  notConnected,

  /// The API key was missing, malformed, expired or rejected.
  ///
  /// If you are using a short-lived client token (`ek_…`), an expired token
  /// produces this and the fix is to mint a fresh one.
  invalidApiKey,

  /// An argument was rejected by the server or the native SDK.
  invalidInput,

  /// A configuration object was internally inconsistent.
  invalidOptions,

  /// The requested model name is not known to the server.
  modelNotFound,

  /// Camera permission has not been granted.
  ///
  /// The plugin does not request permissions for you — see the README.
  permissionDenied,

  /// The camera could not be opened (in use by another app, or absent, which is
  /// the usual cause on the iOS Simulator).
  cameraUnavailable,

  /// Connection setup did not complete within the timeout.
  connectionTimeout,

  /// A WebRTC-layer failure: ICE, DTLS or peer-connection error.
  ///
  /// Frequently a network-path problem. WebRTC needs outbound UDP on ports 3478
  /// and 7882.
  webrtc,

  /// The signalling WebSocket failed or closed unexpectedly.
  websocket,

  /// The signalling protocol produced an unexpected or malformed message.
  signaling,

  /// General network failure below the SDK.
  network,

  /// The server returned an error.
  server,

  /// An outfit update was sent but the server nacked it or never acked it.
  promptRejected,

  /// The native SDK cancelled an in-flight operation, commonly during session
  /// teardown. Public Dart operations are serialized and do not overtake one
  /// another.
  cancelled,

  /// Anything that could not be classified. Check [DecartVtonException.nativeCode].
  unknown;

  /// Maps a native SDK error code string onto this enum.
  ///
  /// Accepts both the Android (`ai.decart.sdk.ErrorCodes`) and iOS
  /// (`DecartError.errorCode`) vocabularies, plus the plugin's own codes.
  static VtonErrorCode fromNative(String? code) {
    switch (code) {
      case 'NOT_INITIALIZED':
        return VtonErrorCode.notInitialized;
      case 'NOT_CONNECTED':
        return VtonErrorCode.notConnected;
      case 'INVALID_API_KEY':
        return VtonErrorCode.invalidApiKey;
      case 'INVALID_INPUT':
      case 'INVALID_BASE_URL':
        return VtonErrorCode.invalidInput;
      case 'INVALID_OPTIONS':
        return VtonErrorCode.invalidOptions;
      case 'MODEL_NOT_FOUND':
        return VtonErrorCode.modelNotFound;
      case 'PERMISSION_DENIED':
        return VtonErrorCode.permissionDenied;
      case 'CAMERA_UNAVAILABLE':
        return VtonErrorCode.cameraUnavailable;
      case 'CONNECTION_TIMEOUT':
      case 'WEBRTC_TIMEOUT_ERROR':
        return VtonErrorCode.connectionTimeout;
      // Android: WEBRTC_ICE_ERROR / WEBRTC_SERVER_ERROR. iOS: WEB_RTC_ERROR.
      case 'WEBRTC_ICE_ERROR':
      case 'WEBRTC_SERVER_ERROR':
      case 'WEB_RTC_ERROR':
      case 'WEBRTC_ERROR':
        return VtonErrorCode.webrtc;
      case 'WEBRTC_WEBSOCKET_ERROR':
      case 'WEBSOCKET_ERROR':
        return VtonErrorCode.websocket;
      case 'WEBRTC_SIGNALING_ERROR':
        return VtonErrorCode.signaling;
      case 'NETWORK_ERROR':
        return VtonErrorCode.network;
      case 'SERVER_ERROR':
      case 'PROCESSING_ERROR':
      // Only reachable through the batch/queue API, which this package does not
      // wrap — but `DecartError.queueError` shares the error surface, so map it
      // rather than let it degrade to `unknown`.
      case 'QUEUE_ERROR':
        return VtonErrorCode.server;
      case 'PROMPT_REJECTED':
      case 'SET_IMAGE_REJECTED':
        return VtonErrorCode.promptRejected;
      case 'CANCELLED':
      case 'SUPERSEDED':
        return VtonErrorCode.cancelled;
      // Explicit rather than falling through, so the contract checker can see
      // that the native `UNKNOWN` code is handled deliberately.
      case 'UNKNOWN':
        return VtonErrorCode.unknown;
      default:
        return VtonErrorCode.unknown;
    }
  }
}

/// The normalized exception type for native SDK and plugin-domain failures.
///
/// A raw `PlatformException` never escapes the plugin: everything crossing the
/// method channel is funnelled through one converter, so callers can catch this
/// type and switch on [code]. Invalid arguments can still throw [ArgumentError],
/// and invalid lifecycle or widget state can throw [StateError].
class DecartVtonException implements Exception {
  /// Creates an exception.
  const DecartVtonException(
    this.code,
    this.message, {
    this.nativeCode,
    this.details,
  });

  /// Convenience constructor for failures raised entirely within the Dart
  /// layer, before anything reached the platform.
  const DecartVtonException.local(this.code, this.message)
    : nativeCode = null,
      details = null;

  /// The normalised failure category.
  final VtonErrorCode code;

  /// A human-readable description. Suitable for logs; usually too technical to
  /// show a user verbatim.
  final String message;

  /// The original native SDK error code, if the failure came from native.
  ///
  /// Useful when [code] is [VtonErrorCode.unknown] and you are filing a bug.
  final String? nativeCode;

  /// Any extra structured detail the native side attached.
  final Object? details;

  @override
  String toString() {
    final native = nativeCode != null && nativeCode != code.name
        ? ' (native: $nativeCode)'
        : '';
    return 'DecartVtonException(${code.name})$native: $message';
  }
}
