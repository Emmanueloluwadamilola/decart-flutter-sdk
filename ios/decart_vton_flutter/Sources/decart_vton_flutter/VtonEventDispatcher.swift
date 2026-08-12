import Flutter
import Foundation

/// Carries an already-normalised event payload across an isolation boundary.
///
/// `[String: Any]` is not `Sendable`, and `DispatchQueue.async` takes a
/// `@Sendable` closure, so under Swift 6 the payload cannot simply be captured.
/// The box is `@unchecked Sendable` because the value it holds is immutable and
/// is only ever read on the main thread.
private final class EventPayloadBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// Bridges native events onto the Flutter `FlutterEventChannel`.
///
/// Mirrors `VtonEventDispatcher.kt`, and handles the same two problems:
///
/// 1. **Thread safety.** `FlutterEventSink` must be invoked on the platform
///    (main) thread. Most emissions here already originate on the main actor,
///    but the hop is unconditional so a future off-actor caller cannot
///    introduce an intermittent crash.
///
/// 2. **Events before Dart is listening.** The first `connecting` transition
///    can be emitted before the Dart `EventChannel` subscription completes;
///    without a buffer the Dart side would start out with a stale state.
///
/// `@unchecked Sendable`: all mutable state is touched only on the main thread,
/// which the `send` path enforces. The alternative — `@MainActor` — is not
/// available because `FlutterStreamHandler`'s requirements are nonisolated.
final class VtonEventDispatcher: NSObject, FlutterStreamHandler, @unchecked Sendable {

    private var sink: FlutterEventSink?
    private var pending: [[String: Any]] = []
    private let maxPending = 64

    func onListen(
        withArguments arguments: Any?,
        eventSink: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = eventSink
        let buffered = pending
        pending.removeAll()
        for event in buffered {
            eventSink(event)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    /// Emits `event` to Dart, or buffers it if nobody is listening yet.
    func send(_ event: [String: Any?]) {
        let payload = normalise(event)
        if Thread.isMainThread {
            deliver(payload)
            return
        }
        let box = EventPayloadBox(payload)
        DispatchQueue.main.async { [weak self] in
            self?.deliver(box.value)
        }
    }

    /// Drops buffered events. Called when the engine detaches.
    func clear() {
        pending.removeAll()
        sink = nil
    }

    private func deliver(_ event: [String: Any]) {
        guard let sink else {
            if pending.count >= maxPending { pending.removeFirst() }
            pending.append(event)
            return
        }
        sink(event)
    }

    /// Swift's `[String: Any?]` carries `.some(nil)` values that bridge to
    /// `NSNull` inconsistently. Normalising to `[String: Any]` with explicit
    /// `NSNull` keeps the payload shape identical to Android's, where a Kotlin
    /// map with null values encodes cleanly.
    private func normalise(_ event: [String: Any?]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in event {
            result[key] = value ?? NSNull()
        }
        return result
    }
}
