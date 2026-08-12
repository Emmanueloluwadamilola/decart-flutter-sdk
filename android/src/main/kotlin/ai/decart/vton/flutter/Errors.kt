package ai.decart.vton.flutter

import ai.decart.sdk.DecartError
import kotlinx.coroutines.TimeoutCancellationException

/**
 * Error codes this plugin can put on the wire.
 *
 * Where a code matches one the native SDK already uses (`INVALID_API_KEY`,
 * `WEBRTC_*`) the SDK's spelling is kept, so that the Dart-side
 * `VtonErrorCode.fromNative` has a single vocabulary to recognise for both
 * platforms. The plugin-specific ones are the four at the top.
 */
internal object ErrorCodes {
    const val NOT_INITIALIZED = "NOT_INITIALIZED"
    const val NOT_CONNECTED = "NOT_CONNECTED"
    const val PERMISSION_DENIED = "PERMISSION_DENIED"
    const val CAMERA_UNAVAILABLE = "CAMERA_UNAVAILABLE"

    const val INVALID_API_KEY = "INVALID_API_KEY"
    const val INVALID_INPUT = "INVALID_INPUT"
    const val CONNECTION_TIMEOUT = "CONNECTION_TIMEOUT"
    const val WEBRTC_ERROR = "WEBRTC_ERROR"
    const val WEBSOCKET_ERROR = "WEBSOCKET_ERROR"
    const val PROMPT_REJECTED = "PROMPT_REJECTED"
    const val CANCELLED = "CANCELLED"
    const val UNKNOWN = "UNKNOWN"
}

/** A failure raised by the plugin itself rather than by the Decart SDK. */
internal class VtonPluginException(
    val code: String,
    override val message: String,
    val details: Any? = null,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * Classifies an arbitrary throwable into a `(code, message)` pair for the
 * method channel.
 *
 * The Decart SDK's suspend functions signal failure with plain [Exception]s
 * carrying human-readable messages ("Not connected", "Prompt send timed out",
 * "Failed to send image", "livekit_room_info timeout (…)"), so some of this is
 * necessarily message sniffing. Every branch below is derived from a literal
 * that exists in `decart-android` 0.7.9 — see the comments. When the SDK
 * changes those strings the worst case is a demotion to `UNKNOWN`, with the
 * original message still intact on the Dart side.
 */
internal fun Throwable.toChannelError(): Pair<String, String> {
    val text = message ?: this::class.java.simpleName

    return when {
        this is VtonPluginException -> code to text

        // Kotlin coroutine timeout, e.g. an outer withTimeout around connect().
        this is TimeoutCancellationException -> ErrorCodes.CONNECTION_TIMEOUT to text

        // Android throws SecurityException when CAMERA has not been granted.
        this is SecurityException ->
            ErrorCodes.PERMISSION_DENIED to
                "Camera permission is not granted. Request android.permission.CAMERA " +
                "before calling connect(). ($text)"

        // RealTimeClient.requireSessionManager() / requirePromptSessionManager().
        this is IllegalStateException && text.startsWith("Not connected") ->
            ErrorCodes.NOT_CONNECTED to text
        this is IllegalStateException && text.startsWith("Cannot send message") ->
            ErrorCodes.NOT_CONNECTED to text

        this is IllegalArgumentException -> ErrorCodes.INVALID_INPUT to text

        // SignalingChannel.awaitAckMessage timeout messages.
        text.contains("timed out", ignoreCase = true) ||
            text.contains("timeout", ignoreCase = true) ->
            ErrorCodes.CONNECTION_TIMEOUT to text

        // SignalingChannel ack-failure messages.
        text.startsWith("Failed to send prompt") ||
            text.startsWith("Failed to send image") ->
            ErrorCodes.PROMPT_REJECTED to text

        text.contains("superseded", ignoreCase = true) -> ErrorCodes.CANCELLED to text

        text.contains("WebSocket", ignoreCase = true) -> ErrorCodes.WEBSOCKET_ERROR to text

        text.contains("api key", ignoreCase = true) ||
            text.contains("unauthorized", ignoreCase = true) ->
            ErrorCodes.INVALID_API_KEY to text

        text.contains("camera", ignoreCase = true) ->
            ErrorCodes.CAMERA_UNAVAILABLE to text

        else -> ErrorCodes.UNKNOWN to text
    }
}

/**
 * The SDK's own [DecartError] already carries a code; pass it through
 * unchanged so the Dart mapping sees the authoritative value.
 */
internal fun DecartError.toChannelError(): Pair<String, String> = code to message
