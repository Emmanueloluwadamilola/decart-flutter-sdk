// `@preconcurrency` is doing real work here, not decoration.
//
// `FlutterMethodNotImplemented` is declared in Objective-C as `NSObject* const`
// and imported into Swift as a mutable global. Under the Swift 6 language mode
// any reference to it is an error:
//
//   Reference to var 'FlutterMethodNotImplemented' is not concurrency-safe
//   because it involves shared mutable state
//
// …even though the engine writes it once at load and never touches it again.
// `nonisolated(unsafe)` on a local copy does NOT help: the initializer
// expression still reads the global, so the error just moves to that line
// (verified — it did exactly that).
//
// `@preconcurrency import` is the mechanism the language provides for this
// case: it downgrades concurrency diagnostics for declarations coming out of a
// module that predates strict concurrency, without weakening checking on any of
// our own code. The alternative — dropping the whole target to
// `.swiftLanguageMode(.v5)` — would silence the checker everywhere, including
// on the parts of this plugin where it has already caught real isolation bugs.
@preconcurrency import Flutter
import UIKit

/// Carries the non-`Sendable` parts of a method call across the isolation
/// boundary into the `@MainActor` task that services it.
///
/// Swift 6 uses region-based isolation to decide whether a value is "sent" into
/// another isolation domain. `FlutterMethodCall` is an Objective-C class and
/// `FlutterResult` is a plain — not `@Sendable` — closure, so capturing either
/// in `Task { @MainActor in … }` is rejected:
///
///   SendingRisksDataRace: Sending 'result' risks causing data races
///
/// `@preconcurrency import` does not fix this. That attribute downgrades
/// *Sendable-conformance* diagnostics on imported declarations; sending
/// diagnostics come from region isolation and are a separate analysis. (Learned
/// the hard way: `@preconcurrency` did clear the `FlutterMethodNotImplemented`
/// error, then this one appeared behind it.)
///
/// The assertion `@unchecked Sendable` makes here is true rather than
/// convenient. The engine delivers the call on the platform thread; we service
/// it on the main actor, which is that same thread; `reply` is called exactly
/// once on each path. Nothing is ever accessed concurrently, and the fields are
/// immutable after init.
///
/// The alternative was `.swiftLanguageMode(.v5)` on the whole target, which
/// would switch the concurrency checker off everywhere — including on the parts
/// of this plugin where it has already caught genuine isolation bugs. One
/// narrow, documented box is the better trade.
private final class CallBox: @unchecked Sendable {
    let method: String
    let arguments: Any?
    let reply: FlutterResult

    init(_ call: FlutterMethodCall, _ reply: @escaping FlutterResult) {
        method = call.method
        arguments = call.arguments
        self.reply = reply
    }
}

/// iOS entry point for `decart_vton_flutter`.
///
/// Deliberately thin, mirroring `DecartVtonPlugin.kt`: decode the call, hand it
/// to `VtonSessionController`, turn the outcome into a channel reply.
///
/// ## Threading and Swift 6 isolation
///
/// `handle(_:result:)` is a nonisolated ObjC protocol witness invoked on the
/// platform thread. `VtonSessionController` is `@MainActor` (and therefore
/// `Sendable`), so the work is wrapped in `Task { @MainActor in … }` and
/// `FlutterResult` is consequently always called on the main thread, which the
/// Flutter engine requires.
///
/// The controller is read into a local `let` before the `Task` on purpose:
/// capturing `self` — a non-`Sendable` `NSObject` subclass — in a main-actor
/// closure is a data-race error under Swift 6. Capturing the `Sendable`
/// controller instead is not.
public class DecartVtonPlugin: NSObject, FlutterPlugin {

    private static let methodChannelName = "ai.decart.vton/methods"
    private static let eventChannelName = "ai.decart.vton/events"
    private static let viewTypeName = "ai.decart.vton/video_view"

    private let eventDispatcher: VtonEventDispatcher
    private let views: VtonVideoViewRegistry
    private let controller: VtonSessionController

    /// Not an `override` of `NSObject.init()`, deliberately: adding actor
    /// isolation to an override of a nonisolated declaration is an error, and
    /// `VtonSessionController`'s initialiser is `@MainActor`. Constructing the
    /// pieces in `register(with:)` — which already runs on the main actor —
    /// and injecting them here keeps this initialiser nonisolated.
    init(
        controller: VtonSessionController,
        eventDispatcher: VtonEventDispatcher,
        views: VtonVideoViewRegistry
    ) {
        self.controller = controller
        self.eventDispatcher = eventDispatcher
        self.views = views
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Plugin registration runs on the platform (main) thread during engine
        // startup, so asserting main-actor isolation here is safe and avoids
        // deferring registration past the first Dart call.
        let (controller, dispatcher, registry) = MainActor.assumeIsolated {
            let dispatcher = VtonEventDispatcher()
            let registry = VtonVideoViewRegistry()
            let controller = VtonSessionController(events: dispatcher, views: registry)
            return (controller, dispatcher, registry)
        }

        let instance = DecartVtonPlugin(
            controller: controller,
            eventDispatcher: dispatcher,
            views: registry
        )

        let methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(dispatcher)

        registrar.register(
            VtonVideoViewFactory(registry: registry),
            withId: viewTypeName
        )

        registrar.publish(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Everything the task needs, boxed once on the platform thread. See CallBox.
        let box = CallBox(call, result)
        let session = controller
        Task { @MainActor in
            do {
                let args = try ChannelCodec.requireArgs(box.arguments)

                switch box.method {
                case "initialize":
                    try await session.initialize(args)
                    box.reply(nil)

                case "connect":
                    let sessionId = try await session.connect(args)
                    let payload: [String: Any] =
                        sessionId.map { ["sessionId": $0] } ?? ["sessionId": NSNull()]
                    box.reply(payload)

                case "setOutfit":
                    try await session.setOutfit(args)
                    box.reply(nil)

                case "disconnect":
                    await session.disconnect()
                    box.reply(nil)

                case "release":
                    await session.release()
                    box.reply(nil)

                case "isConnected":
                    box.reply(session.isConnected())

                case "checkConnectivity":
                    let report = try await session.checkConnectivity(args)
                    var payload: [String: Any] = [:]
                    for (key, value) in report {
                        payload[key] = value ?? NSNull()
                    }
                    box.reply(payload)

                default:
                    box.reply(FlutterMethodNotImplemented)
                }
            } catch {
                let (code, message) = classifyError(error)
                box.reply(FlutterError(code: code, message: message, details: nil))
            }
        }
    }

    /// Called when the Flutter engine detaches this plugin.
    ///
    /// Releasing here matters: a LiveKit room and a running capture session
    /// survive a Dart hot restart and would otherwise keep the camera claimed
    /// (and the green privacy indicator lit) with nothing driving it.
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        let dispatcher = eventDispatcher
        let session = controller
        Task { @MainActor in
            await session.release()
            dispatcher.clear()
        }
    }
}
