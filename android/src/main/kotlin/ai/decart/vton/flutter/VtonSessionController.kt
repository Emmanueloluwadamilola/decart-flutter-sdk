package ai.decart.vton.flutter

import ai.decart.sdk.DecartClient
import ai.decart.sdk.DecartClientConfig
import ai.decart.sdk.ImageUtils
import ai.decart.sdk.LogLevel
import ai.decart.sdk.RealtimeModel
import ai.decart.sdk.realtime.CheckConnectivityOptions
import ai.decart.sdk.realtime.ConnectOptions
import ai.decart.sdk.realtime.InitialPrompt
import ai.decart.sdk.realtime.FacingMode
import ai.decart.sdk.realtime.MirrorMode
import ai.decart.sdk.realtime.RealTimeClient
import ai.decart.sdk.realtime.RealtimeMediaStream
import ai.decart.vton.flutter.ChannelCodec.bool
import ai.decart.vton.flutter.ChannelCodec.bytes
import ai.decart.vton.flutter.ChannelCodec.long
import ai.decart.vton.flutter.ChannelCodec.stringOrNull
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Base64
import android.util.Base64OutputStream
import io.livekit.android.room.track.CameraPosition
import io.livekit.android.room.track.LocalVideoTrack
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Everything stateful about a Decart session on Android.
 *
 * Kept separate from [DecartVtonPlugin] so the plugin class stays a thin
 * dispatcher: the plugin decodes the channel call and this class talks to the
 * SDK. All public methods here are expected to be invoked on the main
 * dispatcher (the plugin's scope guarantees that).
 */
internal class VtonSessionController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val events: VtonEventDispatcher,
    private val views: VtonVideoViewRegistry,
) {

    private var client: DecartClient? = null
    private var realtime: RealTimeClient? = null

    private var localStream: RealtimeMediaStream? = null
    private var remoteStream: RealtimeMediaStream? = null

    private var model: RealtimeModel? = null
    private var supportsReferenceImage: Boolean = true
    private var cameraFacing: FacingMode = FacingMode.FRONT
    private var mirrorMode: MirrorMode = MirrorMode.AUTO

    private val collectors = mutableListOf<Job>()

    // ── lifecycle ────────────────────────────────────────────────────────────

    fun initialize(args: Map<String, Any?>) {
        release()

        val clientToken = args["clientToken"] as? String
        if (clientToken.isNullOrBlank()) {
            throw VtonPluginException(
                ErrorCodes.INVALID_API_KEY,
                "clientToken must be a non-empty string.",
            )
        }

        val created = DecartClient(
            context = context.applicationContext,
            config = DecartClientConfig(
                apiKey = clientToken,
                baseUrl = args.stringOrNull("signalingBaseUrl") ?: "wss://api.decart.ai",
                httpBaseUrl = args.stringOrNull("httpBaseUrl") ?: "https://api.decart.ai",
                logLevel = logLevel(args.stringOrNull("logLevel")),
            ),
        )
        client = created
        realtime = created.realtime
        startCollectors(created.realtime)
    }

    /**
     * Opens a session and returns the server-assigned session id when it is
     * already known by the time `connect` resolves.
     *
     * Ordering matters here. The local stream is created *before* `connect` so
     * that (a) the preview is live while the handshake runs, and (b) preview
     * and publish share one LiveKit `Room` — which the SDK explicitly
     * recommends, and which is what makes the local `VtonLocalPreview` able to
     * find an `EglBase`.
     */
    suspend fun connect(args: Map<String, Any?>): String? {
        val realtimeClient = requireRealtime()
        ensureCameraPermission()

        // Any previous session's resources go first — connect() on the SDK also
        // calls disconnect(), but it does not own our caller-created stream.
        teardownStreams()

        val requestedModel = ChannelCodec.realtimeModel(args)
        val requestedConfig = ChannelCodec.realtimeConfiguration(args)
        val requestedFacing = ChannelCodec.facing(args.stringOrNull("facing"))
        val requestedMirror = ChannelCodec.mirror(args.stringOrNull("mirror"))
        val requestedResolution = ChannelCodec.resolution(args.stringOrNull("resolution"))

        model = requestedModel
        supportsReferenceImage = args.bool("supportsReferenceImage", true)
        cameraFacing = requestedFacing
        mirrorMode = requestedMirror

        val prompt = args.stringOrNull("prompt")?.takeIf { it.isNotBlank() }
        val imageBase64 = encodeReferenceImage(args)
        val enhance = args.bool("enhance", true)

        val stream = try {
            realtimeClient.createLocalVideoStream(
                model = requestedModel,
                facing = requestedFacing,
                configuration = requestedConfig,
                mirror = requestedMirror,
            )
        } catch (e: Throwable) {
            throw VtonPluginException(
                cameraFailureCode(e),
                "Could not start the camera: ${e.message ?: e::class.java.simpleName}. " +
                    "Check that android.permission.CAMERA is granted and that no other " +
                    "app holds the camera.",
                cause = e,
            )
        }
        localStream = stream
        views.setLocal(stream)
        events.send(ChannelCodec.localStreamEvent())

        val remote = try {
            realtimeClient.connect(
                options = ConnectOptions(
                    model = requestedModel,
                    initialPrompt = prompt?.let { InitialPrompt(text = it, enhance = enhance) },
                    // Note: when only a prompt is supplied the SDK sends a
                    // `prompt` initial-state message rather than a `set_image`
                    // one. That is harmless at connect time (there is no image
                    // to clear on a fresh session) and matches what iOS ends up
                    // doing. Mid-session updates DO need the routing — see
                    // setOutfit().
                    initialImage = imageBase64,
                    resolution = requestedResolution,
                    realtimeConfiguration = requestedConfig,
                    publishCamera = true,
                    facing = requestedFacing,
                    mirror = requestedMirror,
                ),
                localStream = stream,
            )
        } catch (e: Throwable) {
            // Do not leak the camera if the handshake failed.
            teardownStreams()
            throw e
        }

        remoteStream = remote
        views.setRemote(remote)

        return realtimeClient.sessionId
    }

    /**
     * Applies a complete try-on state.
     *
     * The branch below is the whole reason this wrapper exists on Android.
     * The iOS SDK's single `setPrompt` routes to a `set_image` signalling
     * message whenever the model declares `hasReferenceImage`; the Android SDK
     * does no such routing and would send a plain `prompt` message. That
     * difference is observable: a `prompt` message leaves a previously-set
     * garment image in place, while `set_image` with a null image clears it.
     * Replicating iOS's rule here is what makes `setOutfit` mean the same thing
     * on both platforms.
     */
    suspend fun setOutfit(args: Map<String, Any?>) {
        val realtimeClient = requireRealtime()
        if (!realtimeClient.isConnected()) {
            throw VtonPluginException(
                ErrorCodes.NOT_CONNECTED,
                "No live session. Call connect() before setOutfit().",
            )
        }

        val prompt = args.stringOrNull("prompt")?.takeIf { it.isNotBlank() }
        val hasImage = hasReferenceImage(args)
        val enhance = args.bool("enhance", true)
        val timeoutMs = args.long("timeoutMs", 30_000L)

        if (prompt == null && !hasImage) {
            throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "setOutfit needs a prompt, a reference image, or both.",
            )
        }
        if (hasImage && !supportsReferenceImage) {
            throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Model ${model?.name} does not accept a reference image.",
            )
        }
        val imageBase64 = encodeReferenceImage(args)

        if (supportsReferenceImage) {
            // set_image carries prompt + image + enhance atomically, and a null
            // image explicitly clears the previous one. This is the whole-state
            // replace the API documents.
            realtimeClient.setImage(
                imageBase64 = imageBase64,
                prompt = prompt,
                enhance = enhance,
                timeout = timeoutMs,
            )
        } else {
            realtimeClient.setPrompt(
                prompt = prompt ?: "",
                enhance = enhance,
                timeoutMs = timeoutMs,
            )
        }
    }

    /**
     * Produces the Base64 string required by the Android SDK off the UI thread.
     *
     * File-backed input is streamed into the encoder so neither Dart nor
     * Kotlin holds a second raw-image copy. The resulting Base64 string is
     * unavoidable because that is the SDK's public input type.
     */
    private suspend fun encodeReferenceImage(args: Map<String, Any?>): String? {
        val bytes = args.bytes("referenceImage")?.takeIf { it.isNotEmpty() }
        val path = args.stringOrNull("referenceImagePath")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        if (bytes != null && path != null) {
            throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Pass referenceImage or referenceImagePath, not both.",
            )
        }
        if (bytes != null) {
            return withContext(Dispatchers.Default) {
                ImageUtils.byteArrayToBase64(bytes)
            }
        }
        if (path == null) return null

        return withContext(Dispatchers.IO) {
            try {
                encodeImageFile(File(path))
            } catch (e: VtonPluginException) {
                throw e
            } catch (e: Throwable) {
                throw VtonPluginException(
                    ErrorCodes.INVALID_INPUT,
                    "Could not read reference image at '$path': " +
                        (e.message ?: e::class.java.simpleName),
                    cause = e,
                )
            }
        }
    }

    private fun hasReferenceImage(args: Map<String, Any?>): Boolean =
        args.bytes("referenceImage")?.isNotEmpty() == true ||
            args.stringOrNull("referenceImagePath")?.isNotBlank() == true

    private fun encodeImageFile(file: File): String {
        if (!file.isFile) {
            throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Reference image path is not a readable file: ${file.path}",
            )
        }
        val size = file.length()
        if (size <= 0L || size > MAX_REFERENCE_IMAGE_BYTES) {
            throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Reference images must be non-empty and 5 MB or smaller.",
            )
        }
        val header = file.inputStream().buffered().use { input ->
            val buffer = ByteArray(12)
            var count = 0
            while (count < buffer.size) {
                val read = input.read(buffer, count, buffer.size - count)
                if (read < 0) break
                count += read
            }
            buffer.copyOf(count)
        }
        if (!isSupportedImage(header)) {
            throw VtonPluginException(
                ErrorCodes.INVALID_INPUT,
                "Reference image must be valid JPEG, PNG, or WebP data.",
            )
        }

        val encodedSize = (((size + 2L) / 3L) * 4L).toInt()
        val encoded = ByteArrayOutputStream(encodedSize)
        Base64OutputStream(encoded, Base64.NO_WRAP).use { base64 ->
            file.inputStream().buffered().use { input -> input.copyTo(base64) }
        }
        return encoded.toString(Charsets.US_ASCII.name())
    }

    private fun isSupportedImage(bytes: ByteArray): Boolean {
        val jpeg = bytes.size >= 3 &&
            bytes[0] == 0xff.toByte() &&
            bytes[1] == 0xd8.toByte() &&
            bytes[2] == 0xff.toByte()
        val png = bytes.size >= 8 &&
            bytes.sliceArray(0 until 8).contentEquals(
                byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a),
            )
        val webp = bytes.size >= 12 &&
            String(bytes, 0, 4, Charsets.US_ASCII) == "RIFF" &&
            String(bytes, 8, 4, Charsets.US_ASCII) == "WEBP"
        return jpeg || png || webp
    }

    /**
     * Replaces the capturer behind the already-published LiveKit track.
     *
     * `restartTrack` moves the existing renderers to the replacement WebRTC
     * track and updates the current sender without reconnecting the Room. A new
     * mirror processor is supplied because Decart's Android stream factory
     * chooses that processor from the initial camera only.
     */
    fun switchCamera(args: Map<String, Any?>): String {
        val realtimeClient = requireRealtime()
        if (!realtimeClient.isConnected()) {
            throw VtonPluginException(
                ErrorCodes.NOT_CONNECTED,
                "No live session. Call connect() before switchCamera().",
            )
        }

        val track = localStream?.videoTrack as? LocalVideoTrack
            ?: throw VtonPluginException(
                ErrorCodes.CAMERA_UNAVAILABLE,
                "The live session does not have a switchable local camera track.",
            )
        val targetFacing = ChannelCodec.facing(args.stringOrNull("facing"))
        val targetPosition = if (targetFacing == FacingMode.BACK) {
            CameraPosition.BACK
        } else {
            CameraPosition.FRONT
        }
        val shouldMirror = when (mirrorMode) {
            MirrorMode.OFF -> false
            MirrorMode.ON -> true
            MirrorMode.AUTO -> targetFacing == FacingMode.FRONT
        }

        try {
            track.restartTrack(
                track.options.copy(
                    deviceId = null,
                    position = targetPosition,
                ),
                if (shouldMirror) AndroidMirrorProcessorFactory.create() else null,
            )
        } catch (e: Throwable) {
            throw VtonPluginException(
                cameraFailureCode(e),
                "Could not switch to the ${ChannelCodec.facingToWire(targetFacing)} camera: " +
                    "${e.message ?: e::class.java.simpleName}.",
                cause = e,
            )
        }

        cameraFacing = targetFacing
        events.send(ChannelCodec.localStreamEvent())
        return ChannelCodec.facingToWire(cameraFacing)
    }

    suspend fun checkConnectivity(args: Map<String, Any?>): Map<String, Any?> {
        val realtimeClient = requireRealtime()
        val report = realtimeClient.checkConnectivity(
            CheckConnectivityOptions(
                iceGatherTimeoutMs = args.long("timeoutMs", 5_000L),
            ),
        )
        return mapOf(
            "quality" to ChannelCodec.qualityToWire(report.quality),
            "transport" to ChannelCodec.transportToWire(report.metrics.transport),
            "roundTripMs" to report.metrics.rttMs?.toInt(),
        )
    }

    fun isConnected(): Boolean = realtime?.isConnected() ?: false

    fun disconnect() {
        realtime?.disconnect()
        teardownStreams()
    }

    fun release() {
        collectors.forEach { it.cancel() }
        collectors.clear()
        try {
            realtime?.disconnect()
        } catch (_: Throwable) {
            // best effort
        }
        teardownStreams()
        try {
            client?.release()
        } catch (_: Throwable) {
            // best effort
        }
        client = null
        realtime = null
        model = null
    }

    // ── internals ────────────────────────────────────────────────────────────

    private fun requireRealtime(): RealTimeClient = realtime
        ?: throw VtonPluginException(
            ErrorCodes.NOT_INITIALIZED,
            "initialize() has not been called, or the client was released.",
        )

    /**
     * Disposes the caller-owned local stream.
     *
     * The SDK is explicit that failing to dispose a caller-created stream leaks
     * the underlying LiveKit `Room` and its native resources. The remote stream
     * is SDK-owned and is torn down by `disconnect()`, so it is only dropped
     * from our references here.
     */
    private fun teardownStreams() {
        views.clearStreams()
        localStream?.let { runCatching { it.dispose() } }
        localStream = null
        remoteStream = null
    }

    private fun startCollectors(realtimeClient: RealTimeClient) {
        collectors += scope.launch {
            realtimeClient.connectionState.collect { state ->
                events.send(ChannelCodec.connectionStateEvent(state))
            }
        }
        collectors += scope.launch {
            realtimeClient.errors.collect { error ->
                val (code, message) = error.toChannelError()
                events.send(ChannelCodec.errorEvent(code, message))
            }
        }
        collectors += scope.launch {
            realtimeClient.sessionStarted.collect { started ->
                if (started != null) {
                    events.send(
                        ChannelCodec.sessionStartedEvent(
                            started.sessionId,
                            started.subscribeToken,
                        ),
                    )
                }
            }
        }
        collectors += scope.launch {
            realtimeClient.generationTicks.collect { tick ->
                events.send(ChannelCodec.generationTickEvent(tick.seconds))
            }
        }
        collectors += scope.launch {
            realtimeClient.remoteStreamUpdates.collect { stream ->
                remoteStream = stream
                views.setRemote(stream)
                events.send(ChannelCodec.remoteStreamEvent())
            }
        }
        collectors += scope.launch {
            realtimeClient.localStreamUpdates.collect { stream ->
                // Only adopt streams we did not create ourselves; connect()
                // already registered its own and re-registering would rebind
                // the renderer for no reason.
                if (stream !== localStream) {
                    localStream = stream
                    views.setLocal(stream)
                    events.send(ChannelCodec.localStreamEvent())
                }
            }
        }
        collectors += scope.launch {
            realtimeClient.connectionQuality.collect { report ->
                if (report != null) {
                    events.send(
                        ChannelCodec.connectionQualityEvent(
                            quality = report.quality,
                            rttMs = report.metrics.rttMs,
                            packetLoss = report.metrics.packetLoss,
                            jitterMs = report.metrics.upstreamJitterMs,
                        ),
                    )
                }
            }
        }
    }

    // The SDK's LogLevel has exactly four cases (DEBUG/INFO/WARN/ERROR), which
    // is why VtonLogLevel on the Dart side has four too.
    private fun logLevel(wire: String?): LogLevel = when (wire) {
        "debug" -> LogLevel.DEBUG
        "info" -> LogLevel.INFO
        "error" -> LogLevel.ERROR
        else -> LogLevel.WARN
    }

    /**
     * Fails fast with a clear code when CAMERA has not been granted.
     *
     * Without this the failure arrives much later and much less legibly — LiveKit
     * opens a capture session that produces no frames, and the connection
     * eventually times out with a WebRTC error that says nothing about
     * permissions. Mirrors `ensureCameraAuthorised()` on iOS.
     */
    private fun ensureCameraPermission() {
        val granted = context.checkSelfPermission(Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            throw VtonPluginException(
                ErrorCodes.PERMISSION_DENIED,
                "android.permission.CAMERA has not been granted. Request it at " +
                    "runtime (for example with the permission_handler package) " +
                    "before calling connect().",
            )
        }
    }

    private fun cameraFailureCode(e: Throwable): String =
        if (e is SecurityException) ErrorCodes.PERMISSION_DENIED else ErrorCodes.CAMERA_UNAVAILABLE

    private companion object {
        const val MAX_REFERENCE_IMAGE_BYTES = 5L * 1024L * 1024L
    }
}
