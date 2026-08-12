package ai.decart.vton.flutter

import ai.decart.sdk.realtime.RealtimeMediaStream
import android.content.Context
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.livekit.android.renderer.TextureViewRenderer
import io.livekit.android.room.Room
import io.livekit.android.room.track.VideoTrack
import livekit.org.webrtc.RendererCommon

/** Which track a video view is bound to. */
internal enum class VtonVideoSource { REMOTE, LOCAL }

/**
 * Owns the set of live video views and keeps them bound to the current tracks.
 *
 * Rebinding happens **here**, natively, rather than by telling Dart to tear
 * down and rebuild the platform view. The Decart SDK emits a fresh
 * [RealtimeMediaStream] after every automatic reconnect; round-tripping that
 * through Dart would mean destroying and recreating a platform view (a visible
 * black flash, plus a window of dropped frames) for something the native side
 * can fix in place.
 */
internal class VtonVideoViewRegistry {

    private val views = mutableListOf<VtonVideoPlatformView>()
    private var remote: RealtimeMediaStream? = null
    private var local: RealtimeMediaStream? = null

    fun register(view: VtonVideoPlatformView) {
        views.add(view)
        view.bind(streamFor(view.source))
    }

    fun unregister(view: VtonVideoPlatformView) {
        views.remove(view)
    }

    fun setRemote(stream: RealtimeMediaStream?) {
        remote = stream
        views.filter { it.source == VtonVideoSource.REMOTE }.forEach { it.bind(stream) }
    }

    fun setLocal(stream: RealtimeMediaStream?) {
        local = stream
        views.filter { it.source == VtonVideoSource.LOCAL }.forEach { it.bind(stream) }
    }

    /** Unbinds everything. Called on disconnect so views do not hold dead tracks. */
    fun clearStreams() {
        remote = null
        local = null
        views.forEach { it.bind(null) }
    }

    private fun streamFor(source: VtonVideoSource): RealtimeMediaStream? =
        if (source == VtonVideoSource.REMOTE) remote else local
}

/** Creates [VtonVideoPlatformView]s for the Flutter platform-view system. */
internal class VtonVideoViewFactory(
    private val registry: VtonVideoViewRegistry,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = (args as? Map<String, Any?>) ?: emptyMap()
        return VtonVideoPlatformView(
            context = context,
            source = if (params["source"] == "local") {
                VtonVideoSource.LOCAL
            } else {
                VtonVideoSource.REMOTE
            },
            scaleToFill = params["fit"] != "contain",
            mirror = params["mirror"] as? Boolean ?: false,
            registry = registry,
        )
    }
}

/**
 * A LiveKit [TextureViewRenderer] hosted inside a [FrameLayout], exposed to
 * Flutter as a platform view.
 *
 * The [FrameLayout] wrapper exists so the renderer can be destroyed and
 * recreated (which is necessary when the owning [Room] — and therefore the
 * `EglBase` — changes) without the platform view itself going away.
 * Re-`init`-ing an existing renderer against a different `EglBase` is not
 * reliable; the LiveKit sample works around it by recreating the whole
 * composable, and this is the equivalent.
 */
internal class VtonVideoPlatformView(
    private val context: Context,
    val source: VtonVideoSource,
    private val scaleToFill: Boolean,
    private val mirror: Boolean,
    private val registry: VtonVideoViewRegistry,
) : PlatformView {

    private val container = FrameLayout(context).apply {
        layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
        )
    }

    private var renderer: TextureViewRenderer? = null
    private var boundRoom: Room? = null
    private var boundTrack: VideoTrack? = null
    private var disposed = false

    init {
        registry.register(this)
    }

    /**
     * Points this view at [stream], creating or recreating the underlying
     * renderer as needed. Passing `null` detaches and releases.
     *
     * Must be called on the main thread — [TextureViewRenderer.init] touches
     * the view hierarchy. Every call site is on `Dispatchers.Main` or inside
     * the main-looper post in [VtonEventDispatcher].
     */
    fun bind(stream: RealtimeMediaStream?) {
        if (disposed) return

        val room = stream?.room
        val track = stream?.videoTrack
        if (room == null || track == null) {
            detachTrack()
            return
        }

        if (boundRoom !== room) {
            releaseRenderer()
            createRenderer(room)
            boundRoom = room
        }

        val activeRenderer = renderer ?: return
        if (boundTrack !== track) {
            boundTrack?.let { runCatching { it.removeRenderer(activeRenderer) } }
            runCatching { track.addRenderer(activeRenderer) }
            boundTrack = track
        }
    }

    private fun createRenderer(room: Room) {
        val created = TextureViewRenderer(context)
        created.init(room.lkObjects.eglBase.eglBaseContext, null)
        created.setEnableHardwareScaler(true)
        created.setMirror(mirror)
        created.setScalingType(
            if (scaleToFill) {
                RendererCommon.ScalingType.SCALE_ASPECT_FILL
            } else {
                RendererCommon.ScalingType.SCALE_ASPECT_FIT
            },
        )
        created.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
        )
        container.addView(created)
        renderer = created
    }

    private fun detachTrack() {
        val activeRenderer = renderer ?: return
        boundTrack?.let { runCatching { it.removeRenderer(activeRenderer) } }
        boundTrack = null
    }

    private fun releaseRenderer() {
        detachTrack()
        renderer?.let { active ->
            container.removeView(active)
            runCatching { active.release() }
        }
        renderer = null
        boundRoom = null
    }

    override fun getView(): View = container

    override fun dispose() {
        if (disposed) return
        disposed = true
        registry.unregister(this)
        releaseRenderer()
        container.removeAllViews()
    }
}
