package ai.decart.vton.flutter

import ai.decart.sdk.ConnectionState
import ai.decart.sdk.RealtimeModel
import ai.decart.sdk.realtime.ConnectionQuality
import ai.decart.sdk.realtime.ConnectivityTransport
import ai.decart.sdk.realtime.FacingMode
import ai.decart.sdk.realtime.MirrorMode
import ai.decart.sdk.realtime.RealtimeConfiguration
import ai.decart.sdk.realtime.Resolution

/**
 * The one place on the Android side that knows the platform-channel wire format.
 *
 * Its Dart counterpart is `lib/src/decart_vton_platform.dart` and its iOS
 * counterpart is `ChannelCodec.swift`. If you change a key here, change it in
 * both of those too — the contract is written out in IMPLEMENTATION.md.
 */
internal object ChannelCodec {

    // ── argument decoding ────────────────────────────────────────────────────

    fun requireArgs(arguments: Any?): Map<String, Any?> {
        @Suppress("UNCHECKED_CAST")
        return (arguments as? Map<String, Any?>)
            ?: throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Expected a map of arguments but received ${arguments?.javaClass?.simpleName ?: "null"}.",
            )
    }

    fun Map<String, Any?>.string(key: String): String =
        this[key] as? String
            ?: throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Missing required String argument '$key'.",
            )

    fun Map<String, Any?>.stringOrNull(key: String): String? = this[key] as? String

    fun Map<String, Any?>.int(key: String, fallback: Int): Int = when (val v = this[key]) {
        is Int -> v
        is Long -> v.toInt()
        is Number -> v.toInt()
        else -> fallback
    }

    fun Map<String, Any?>.long(key: String, fallback: Long): Long = when (val v = this[key]) {
        is Long -> v
        is Int -> v.toLong()
        is Number -> v.toLong()
        else -> fallback
    }

    fun Map<String, Any?>.bool(key: String, fallback: Boolean): Boolean =
        this[key] as? Boolean ?: fallback

    fun Map<String, Any?>.bytes(key: String): ByteArray? = this[key] as? ByteArray

    @Suppress("UNCHECKED_CAST")
    fun Map<String, Any?>.map(key: String): Map<String, Any?>? =
        this[key] as? Map<String, Any?>

    // ── enum mapping ─────────────────────────────────────────────────────────

    fun facing(wire: String?): FacingMode =
        if (wire == "back") FacingMode.BACK else FacingMode.FRONT

    fun facingToWire(facing: FacingMode): String =
        if (facing == FacingMode.BACK) "back" else "front"

    fun mirror(wire: String?): MirrorMode = when (wire) {
        "off" -> MirrorMode.OFF
        "on" -> MirrorMode.ON
        else -> MirrorMode.AUTO
    }

    fun resolution(wire: String?): Resolution? = when (wire) {
        "720p" -> Resolution.P720
        "1080p" -> Resolution.P1080
        else -> null
    }

    fun connectionStateToWire(state: ConnectionState): String = when (state) {
        ConnectionState.DISCONNECTED -> "disconnected"
        ConnectionState.CONNECTING -> "connecting"
        ConnectionState.CONNECTED -> "connected"
        ConnectionState.GENERATING -> "generating"
        ConnectionState.RECONNECTING -> "reconnecting"
    }

    /**
     * Maps the SDK's four-level quality scale onto the Dart five-level one.
     *
     * The extra Dart level is `unknown`, which the SDK expresses as "no report
     * yet" rather than as an enum case, so it is never produced here.
     * iOS's [ConnectionQuality] has the same four cases and maps identically.
     */
    fun qualityToWire(quality: ConnectionQuality): String = when (quality) {
        ConnectionQuality.GOOD -> "excellent"
        ConnectionQuality.FAIR -> "good"
        ConnectionQuality.POOR -> "poor"
        ConnectionQuality.CRITICAL -> "unusable"
    }

    fun transportToWire(transport: ConnectivityTransport): String =
        transport.name.lowercase()

    // ── configuration building ───────────────────────────────────────────────

    /**
     * Builds a [RealtimeModel] from the values Dart sent.
     *
     * Deliberately constructed from the wire payload rather than looked up in
     * `RealtimeModels`: the Dart [VtonModel] enum is the single source of truth
     * for dimensions and frame rate, and building the model here means a new
     * server-side model can be supported by editing one Dart enum instead of
     * two native registries.
     */
    fun realtimeModel(args: Map<String, Any?>): RealtimeModel = RealtimeModel(
        name = args.string("model"),
        urlPath = "/v1/stream",
        fps = args.int("fps", 30),
        width = args.int("width", 1088),
        height = args.int("height", 624),
    )

    fun realtimeConfiguration(args: Map<String, Any?>): RealtimeConfiguration {
        val video = args.map("video")
        return RealtimeConfiguration(
            connection = RealtimeConfiguration.ConnectionConfig(
                connectionTimeoutMs = args.long("connectTimeoutMs", 30_000L),
            ),
            media = RealtimeConfiguration.MediaConfig(
                video = RealtimeConfiguration.VideoConfig(
                    maxBitrate = video?.int("maxBitrate", 2_500_000) ?: 2_500_000,
                    maxFramerate = video?.int("maxFramerate", 30) ?: 30,
                    preferredCodec = video?.stringOrNull("preferredCodec") ?: "vp8",
                    simulcast = video?.bool("simulcast", true) ?: true,
                ),
            ),
        )
    }

    // ── event payloads ───────────────────────────────────────────────────────

    fun connectionStateEvent(state: ConnectionState): Map<String, Any?> =
        mapOf("type" to "connectionState", "state" to connectionStateToWire(state))

    fun sessionStartedEvent(sessionId: String, subscribeToken: String?): Map<String, Any?> =
        mapOf(
            "type" to "sessionStarted",
            "sessionId" to sessionId,
            "subscribeToken" to subscribeToken,
        )

    fun generationTickEvent(seconds: Double): Map<String, Any?> =
        mapOf("type" to "generationTick", "seconds" to seconds)

    fun remoteStreamEvent(): Map<String, Any?> = mapOf("type" to "remoteStreamUpdated")

    fun localStreamEvent(): Map<String, Any?> = mapOf("type" to "localStreamUpdated")

    fun errorEvent(code: String, message: String, details: Any? = null): Map<String, Any?> =
        mapOf(
            "type" to "error",
            "code" to code,
            "message" to message,
            "details" to details,
        )

    fun connectionQualityEvent(
        quality: ConnectionQuality,
        rttMs: Double?,
        packetLoss: Double?,
        jitterMs: Double?,
    ): Map<String, Any?> = mapOf(
        "type" to "connectionQuality",
        "quality" to qualityToWire(quality),
        "roundTripMs" to rttMs?.let { Math.round(it).toInt() },
        "packetLoss" to packetLoss,
        "jitterMs" to jitterMs?.let { Math.round(it).toInt() },
    )
}
