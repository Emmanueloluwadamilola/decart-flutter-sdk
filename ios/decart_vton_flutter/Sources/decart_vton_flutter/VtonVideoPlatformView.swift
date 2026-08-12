import DecartSDK
import Flutter
@preconcurrency import LiveKit
import UIKit

/// Which track a video view is bound to.
enum VtonVideoSource: Sendable {
    case remote
    case local
}

/// Owns the live video views and keeps them bound to the current tracks.
///
/// Rebinding happens here, natively, rather than by asking Dart to rebuild the
/// platform view. The SDK emits a fresh `RealtimeMediaStream` after every
/// automatic reconnect; recreating a `UiKitView` for that would mean a visible
/// black flash for something that is a one-line property assignment on
/// LiveKit's `VideoView`.
///
/// Mirrors `VtonVideoViewRegistry` in the Kotlin sources — keep the two in step.
///
/// ## Concurrency
///
/// Marked `@unchecked Sendable` rather than `@MainActor`. Everything that
/// touches this type already runs on the platform thread: platform views are
/// created there by the Flutter engine, and every `setRemote`/`setLocal` call
/// originates from `VtonSessionController`, which *is* `@MainActor`. Making the
/// registry itself main-actor-isolated would force `MainActor.assumeIsolated`
/// hops in `VtonVideoViewFactory.create` (a nonisolated ObjC protocol witness)
/// and in `FlutterPlatformView.view()`, neither of which can return a
/// non-`Sendable` `UIView` through `assumeIsolated`.
final class VtonVideoViewRegistry: @unchecked Sendable {

    /// Weak so a view that Flutter has torn down drops out on its own.
    ///
    /// `FlutterPlatformView` has no `dispose` hook (unlike Android's
    /// `PlatformView.dispose`), and unregistering from `deinit` would mean
    /// escaping `self` out of a deinitialiser — undefined behaviour. A weak
    /// table sidesteps the whole problem.
    private let views = NSHashTable<VtonVideoPlatformView>.weakObjects()

    private var remote: RealtimeMediaStream?
    private var local: RealtimeMediaStream?

    func register(_ view: VtonVideoPlatformView) {
        views.add(view)
        view.bind(stream(for: view.source))
    }

    func setRemote(_ stream: RealtimeMediaStream?) {
        remote = stream
        for view in views.allObjects where view.source == .remote {
            view.bind(stream)
        }
    }

    func setLocal(_ stream: RealtimeMediaStream?) {
        local = stream
        for view in views.allObjects where view.source == .local {
            view.bind(stream)
        }
    }

    /// Unbinds everything, so views do not hold dead tracks after a disconnect.
    func clearStreams() {
        remote = nil
        local = nil
        for view in views.allObjects {
            view.bind(nil)
        }
    }

    private func stream(for source: VtonVideoSource) -> RealtimeMediaStream? {
        source == .remote ? remote : local
    }
}

/// Creates `VtonVideoPlatformView`s for the Flutter platform-view system.
final class VtonVideoViewFactory: NSObject, FlutterPlatformViewFactory {

    private let registry: VtonVideoViewRegistry

    init(registry: VtonVideoViewRegistry) {
        self.registry = registry
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = args as? [String: Any] ?? [:]
        return VtonVideoPlatformView(
            frame: frame,
            source: (params["source"] as? String) == "local" ? .local : .remote,
            scaleToFill: (params["fit"] as? String) != "contain",
            mirror: (params["mirror"] as? Bool) ?? false,
            registry: registry
        )
    }
}

/// A LiveKit `VideoView` exposed to Flutter as a `UiKitView`.
///
/// `VideoView` handles renderer lifecycle internally (unlike the Android side,
/// where the renderer must be recreated when the owning `Room`'s `EglBase`
/// changes), so binding is just an assignment.
///
/// `@unchecked Sendable` for the same reason as the registry: this type is only
/// ever constructed and mutated on the platform thread, and `view()` is a
/// nonisolated ObjC protocol requirement returning a non-`Sendable` `UIView`,
/// which no actor-isolation annotation can express cleanly.
final class VtonVideoPlatformView: NSObject, FlutterPlatformView, @unchecked Sendable {

    let source: VtonVideoSource

    private let container: UIView
    private let videoView: VideoView

    init(
        frame: CGRect,
        source: VtonVideoSource,
        scaleToFill: Bool,
        mirror: Bool,
        registry: VtonVideoViewRegistry
    ) {
        self.source = source

        container = UIView(frame: frame)
        container.backgroundColor = .clear
        container.clipsToBounds = true

        videoView = VideoView(frame: container.bounds)
        videoView.layoutMode = scaleToFill ? .fill : .fit
        videoView.mirrorMode = mirror ? .mirror : .off
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(videoView)

        super.init()
        registry.register(self)
    }

    func view() -> UIView { container }

    /// Points this view at `stream`, or clears it when `stream` is nil.
    ///
    /// `VideoView` releases its renderer when `track` is set to nil, so this is
    /// also the teardown path — the registry calls it with nil on disconnect.
    func bind(_ stream: RealtimeMediaStream?) {
        videoView.track = stream?.videoTrack
    }
}
