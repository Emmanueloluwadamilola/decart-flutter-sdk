package ai.decart.vton.flutter

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Android entry point for `decart_vton_flutter`.
 *
 * Deliberately thin: decode the call, hand it to [VtonSessionController], turn
 * whatever comes back (or is thrown) into a channel reply. Everything stateful
 * lives in the controller; everything wire-format lives in [ChannelCodec].
 *
 * ## Threading
 *
 * `onMethodCall` arrives on the platform thread, which is also the main thread.
 * The coroutine scope uses [Dispatchers.Main] so suspending SDK calls resume
 * there and `MethodChannel.Result` is only ever touched from the main thread —
 * calling it from anywhere else is a hard crash in the Flutter embedding.
 * Events take the same care via [VtonEventDispatcher].
 */
class DecartVtonPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    private val events = VtonEventDispatcher()
    private val views = VtonVideoViewRegistry()

    private var scope: CoroutineScope? = null
    private var controller: VtonSessionController? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val coroutineScope = CoroutineScope(Dispatchers.Main.immediate + SupervisorJob())
        scope = coroutineScope

        controller = VtonSessionController(
            context = binding.applicationContext,
            scope = coroutineScope,
            events = events,
            views = views,
        )

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler(this@DecartVtonPlugin)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).apply {
            setStreamHandler(events)
        }

        binding.platformViewRegistry.registerViewFactory(
            VIEW_TYPE,
            VtonVideoViewFactory(views),
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Release native resources before tearing the channels down; a leaked
        // LiveKit Room survives a hot restart and holds the camera hostage.
        controller?.release()
        controller = null

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null

        events.clear()
        scope?.cancel()
        scope = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val activeController = controller
        val activeScope = scope
        if (activeController == null || activeScope == null) {
            result.error(
                ErrorCodes.NOT_INITIALIZED,
                "The plugin is detached from the Flutter engine.",
                null,
            )
            return
        }

        activeScope.launch {
            try {
                val args = if (call.arguments == null) {
                    emptyMap()
                } else {
                    ChannelCodec.requireArgs(call.arguments)
                }

                when (call.method) {
                    "initialize" -> {
                        activeController.initialize(args)
                        result.success(null)
                    }

                    "connect" -> {
                        val sessionId = activeController.connect(args)
                        result.success(mapOf("sessionId" to sessionId))
                    }

                    "setOutfit" -> {
                        activeController.setOutfit(args)
                        result.success(null)
                    }

                    "disconnect" -> {
                        activeController.disconnect()
                        result.success(null)
                    }

                    "release" -> {
                        activeController.release()
                        result.success(null)
                    }

                    "isConnected" -> result.success(activeController.isConnected())

                    "checkConnectivity" ->
                        result.success(activeController.checkConnectivity(args))

                    else -> result.notImplemented()
                }
            } catch (e: CancellationException) {
                // The scope was cancelled (engine detach). Replying would be a
                // use-after-free on the messenger; rethrow so the coroutine
                // machinery unwinds normally.
                throw e
            } catch (e: Throwable) {
                val (code, message) = e.toChannelError()
                result.error(code, message, null)
            }
        }
    }

    private companion object {
        const val METHOD_CHANNEL = "ai.decart.vton/methods"
        const val EVENT_CHANNEL = "ai.decart.vton/events"
        const val VIEW_TYPE = "ai.decart.vton/video_view"
    }
}
