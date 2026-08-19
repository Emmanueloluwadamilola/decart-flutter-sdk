import DecartSDK
import Foundation

/// Error codes this plugin can put on the wire.
///
/// These strings are shared with the Android side on purpose: `VtonErrorCode`
/// in Dart has one vocabulary to recognise rather than two. Where the native
/// SDK already has a code (`INVALID_API_KEY`, `WEBSOCKET_ERROR`) that spelling
/// is reused.
enum ErrorCodes {
    static let notInitialized = "NOT_INITIALIZED"
    static let notConnected = "NOT_CONNECTED"
    static let permissionDenied = "PERMISSION_DENIED"
    static let cameraUnavailable = "CAMERA_UNAVAILABLE"

    static let invalidApiKey = "INVALID_API_KEY"
    static let invalidInput = "INVALID_INPUT"
    static let connectionTimeout = "CONNECTION_TIMEOUT"
    static let webrtcError = "WEBRTC_ERROR"
    static let websocketError = "WEBSOCKET_ERROR"
    static let promptRejected = "PROMPT_REJECTED"
    static let cancelled = "CANCELLED"
    static let unknown = "UNKNOWN"
}

/// A failure raised by the plugin itself rather than by the Decart SDK.
struct VtonPluginError: Error {
    let code: String
    let message: String
}

/// Classifies an arbitrary error into a `(code, message)` pair for the method
/// channel.
///
/// `DecartError` already carries an `errorCode`, so that branch is exact. The
/// message-sniffing fallbacks below cover the SDK's plain-`Error` paths — every
/// literal is one that exists in `decart-ios` v0.6.10. When those strings change
/// the worst case is a demotion to `UNKNOWN`, with the message still intact on
/// the Dart side.
func classifyError(_ error: Error) -> (code: String, message: String) {
    if let pluginError = error as? VtonPluginError {
        return (pluginError.code, pluginError.message)
    }

    if let decartError = error as? DecartError {
        let message = decartError.errorDescription ?? String(describing: decartError)
        // Normalise the two codes whose spelling differs from Android's so the
        // Dart mapping does not need a per-platform table.
        switch decartError.errorCode {
        case "WEB_RTC_ERROR":
            return (ErrorCodes.webrtcError, message)
        default:
            return (decartError.errorCode, message)
        }
    }

    if error is CancellationError {
        return (ErrorCodes.cancelled, "The operation was cancelled.")
    }

    let text = (error as NSError).localizedDescription
    let lower = text.lowercased()

    // AVFoundation permission failures surface as AVError / camera errors.
    if lower.contains("permission") || lower.contains("not authorized")
        || lower.contains("denied") {
        return (
            ErrorCodes.permissionDenied,
            "Camera access is not authorised. Add NSCameraUsageDescription to "
                + "Info.plist and request permission before connecting. (\(text))"
        )
    }
    if lower.contains("camera") {
        return (ErrorCodes.cameraUnavailable, text)
    }
    if lower.contains("timeout") || lower.contains("timed out") {
        return (ErrorCodes.connectionTimeout, text)
    }
    if lower.contains("superseded") {
        return (ErrorCodes.cancelled, text)
    }
    if lower.contains("websocket") {
        return (ErrorCodes.websocketError, text)
    }
    if lower.contains("failed to send prompt") || lower.contains("failed to send image") {
        return (ErrorCodes.promptRejected, text)
    }

    return (ErrorCodes.unknown, text)
}
