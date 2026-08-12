package ai.decart.vton.flutter

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Bridges native events onto the Flutter [EventChannel].
 *
 * Two things this handles that a bare `EventSink` does not:
 *
 * 1. **Thread safety.** `EventSink.success` must be called on the platform
 *    (main) thread. The Decart SDK's flows are collected on `Dispatchers.Main`
 *    already, but LiveKit callbacks and the SDK's internal coroutines are not
 *    all guaranteed to be, so every emission is hopped through a main-looper
 *    [Handler]. Getting this wrong produces an intermittent crash that only
 *    reproduces under load.
 *
 * 2. **Events emitted before Dart is listening.** `initialize()` starts flow
 *    collection immediately, but Dart subscribes a moment later. Without a
 *    buffer, the first `connectionState` emission is dropped and the Dart side
 *    starts out with a stale idea of the state. Events are queued (bounded)
 *    until the first listener attaches.
 */
internal class VtonEventDispatcher : EventChannel.StreamHandler {

    private val handler = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<Map<String, Any?>>()
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (events != null) {
            while (pending.isNotEmpty()) {
                events.success(pending.removeFirst())
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Emits [event] to Dart, or buffers it if nobody is listening yet. */
    fun send(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver(event)
        } else {
            handler.post { deliver(event) }
        }
    }

    private fun deliver(event: Map<String, Any?>) {
        val target = sink
        if (target == null) {
            // Bounded so a long-running app with no Dart listener (which should
            // not happen, but might during a hot restart) cannot grow without
            // limit. Oldest events are the least useful, so drop from the front.
            if (pending.size >= MAX_PENDING) pending.removeFirst()
            pending.addLast(event)
            return
        }
        target.success(event)
    }

    /** Drops buffered events. Called when the engine detaches. */
    fun clear() {
        pending.clear()
        sink = null
    }

    private companion object {
        const val MAX_PENDING = 64
    }
}
