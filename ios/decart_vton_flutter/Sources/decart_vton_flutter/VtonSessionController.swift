import AVFoundation
import DecartSDK
import Flutter
import Foundation
@preconcurrency import LiveKit

/// Everything stateful about a Decart session on iOS.
///
/// Mirrors `VtonSessionController.kt`. Where the two diverge, the divergence is
/// forced by the SDKs and is commented at the site.
///
/// ## Threading
///
/// The whole class is `@MainActor`. `DecartClient.createLocalCameraStream` is
/// already main-actor-isolated, `VideoView` is UIKit, and `FlutterResult` must
/// be called on the platform thread — pinning everything to the main actor
/// removes a category of Swift 6 concurrency errors and a category of runtime
/// crashes at the same time. The SDK's own `connect`/`setPrompt` do their work
/// off the main actor internally, so this does not serialise the network path.
@MainActor
final class VtonSessionController {

    private let events: VtonEventDispatcher
    private let views: VtonVideoViewRegistry

    private var client: DecartClient?
    private var manager: DecartRealtimeManager?
    private var localStream: RealtimeMediaStream?
    private var model: ModelDefinition?
    private var cameraPosition: AVCaptureDevice.Position = .front

    private var eventTasks: [Task<Void, Never>] = []

    /// Last values seen on the `events` stream, so a `DecartRealtimeState`
    /// snapshot can be turned into the discrete events the Dart layer expects.
    private var lastConnectionState: DecartRealtimeConnectionState = .idle
    private var lastSessionId: String?
    private var lastTick: Double?

    init(events: VtonEventDispatcher, views: VtonVideoViewRegistry) {
        self.events = events
        self.views = views
    }

    // MARK: - Lifecycle

    func initialize(_ args: [String: Any]) async throws {
        await release()

        guard let clientToken = ChannelCodec.string(args, "clientToken")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !clientToken.isEmpty
        else {
            throw VtonPluginError(
                code: ErrorCodes.invalidApiKey,
                message: "clientToken must be a non-empty string."
            )
        }

        // `DecartConfiguration.init` calls fatalError() on an empty key or an
        // unparseable URL. Validating here keeps a bad argument from taking the
        // whole app down.
        let baseURL = ChannelCodec.string(args, "httpBaseUrl") ?? "https://api.decart.ai"
        guard URL(string: baseURL) != nil else {
            throw VtonPluginError(
                code: ErrorCodes.invalidInput,
                message: "httpBaseUrl is not a valid URL: \(baseURL)"
            )
        }

        client = DecartClient(
            decartConfiguration: DecartConfiguration(baseURL: baseURL, apiKey: clientToken)
        )

        // Two arguments are accepted on the channel and deliberately ignored
        // here, both documented on the Dart side:
        //
        //  - `logLevel`: the iOS SDK's DecartLogger keys off the
        //    ENABLE_DECART_SDK_DUBUG_LOGS environment variable and exposes no
        //    runtime level. Documented on VtonLogLevel.
        //  - `signalingBaseUrl`: DecartConfiguration takes a single base URL
        //    and derives the wss:// signalling endpoint from it, so there is
        //    nowhere to put an independent value. Documented on
        //    DecartVton.initialize.
    }

    func connect(_ args: [String: Any]) async throws -> String? {
        guard let client else {
            throw VtonPluginError(
                code: ErrorCodes.notInitialized,
                message: "initialize() has not been called, or the client was released."
            )
        }

        try ensureCameraAuthorised()
        await teardownSession()

        let modelDefinition = ChannelCodec.modelDefinition(args)
        model = modelDefinition
        cameraPosition = ChannelCodec.position(ChannelCodec.string(args, "facing"))
        let mirror = ChannelCodec.mirror(ChannelCodec.string(args, "mirror"))

        let initialPrompt = DecartPrompt(
            text: ChannelCodec.string(args, "prompt") ?? "",
            referenceImageData: ChannelCodec.bytes(args, "referenceImage"),
            enrich: ChannelCodec.bool(args, "enhance", true)
        )

        let configuration = ChannelCodec.realtimeConfiguration(
            args,
            model: modelDefinition,
            initialPrompt: initialPrompt
        )

        // Surface `connecting` immediately. The manager does not exist yet, so
        // its `events` stream cannot report it, and without this the Dart side
        // sits on `idle` for the whole handshake.
        emitConnectionState(.connecting)

        let realtimeManager = try client.createRealtimeManager(options: configuration)
        manager = realtimeManager
        startEventTasks(for: realtimeManager)

        let stream = client.createLocalCameraStream(
            model: modelDefinition,
            position: cameraPosition,
            mirror: mirror
        )
        localStream = stream
        views.setLocal(stream)
        events.send(ChannelCodec.localStreamEvent())

        do {
            let remote = try await realtimeManager.connect(localStream: stream)
            views.setRemote(remote)
            return realtimeManager.sessionId
        } catch {
            // Do not leave the camera running on a failed handshake.
            await teardownSession()
            emitConnectionState(.disconnected)
            throw error
        }
    }

    /// Applies a complete try-on state.
    ///
    /// Unlike Android, no routing is needed: the iOS SDK's `setPrompt` already
    /// branches on `model.hasReferenceImage` and sends a `set_image` signalling
    /// message for reference-image models. That is exactly the behaviour the
    /// Android side had to be taught — see `VtonSessionController.kt`.
    func setOutfit(_ args: [String: Any]) async throws {
        guard let manager else {
            throw VtonPluginError(
                code: ErrorCodes.notConnected,
                message: "No live session. Call connect() before setOutfit()."
            )
        }
        guard lastConnectionState.isConnected else {
            throw VtonPluginError(
                code: ErrorCodes.notConnected,
                message: "No live session; the current state is "
                    + "\(ChannelCodec.connectionStateToWire(lastConnectionState))."
            )
        }

        let prompt = ChannelCodec.string(args, "prompt")
        let image = ChannelCodec.bytes(args, "referenceImage")

        guard prompt != nil || image != nil else {
            throw VtonPluginError(
                code: ErrorCodes.invalidInput,
                message: "setOutfit needs a prompt, a reference image, or both."
            )
        }
        if image != nil, model?.hasReferenceImage == false {
            throw VtonPluginError(
                code: ErrorCodes.invalidInput,
                message: "Model \(model?.name ?? "?") does not accept a reference image."
            )
        }

        try await manager.setPrompt(
            DecartPrompt(
                text: prompt ?? "",
                referenceImageData: image,
                enrich: ChannelCodec.bool(args, "enhance", true)
            )
        )
    }

    func checkConnectivity(_ args: [String: Any]) async throws -> [String: Any?] {
        guard let client else {
            throw VtonPluginError(
                code: ErrorCodes.notInitialized,
                message: "initialize() has not been called."
            )
        }
        let report = await client.checkConnectivity(
            options: CheckConnectivityOptions(
                iceGatherTimeoutMs: ChannelCodec.int(args, "timeoutMs", 5_000)
            )
        )
        return [
            "quality": ChannelCodec.qualityToWire(report.quality),
            "transport": ChannelCodec.transportToWire(report.metrics.transport),
            "roundTripMs": report.metrics.rttMs
        ]
    }

    func isConnected() -> Bool {
        lastConnectionState.isConnected
    }

    func disconnect() async {
        await teardownSession()
        emitConnectionState(.disconnected)
    }

    func release() async {
        await teardownSession()
        client = nil
        model = nil
        // Without this, `isConnected()` keeps reporting the last live value
        // after release, because `teardownSession` does not touch
        // `lastConnectionState`. Android gets this for free by nulling its
        // `RealTimeClient`.
        emitConnectionState(.disconnected)
    }

    // MARK: - Internals

    /// Fails fast with a clear code when the camera has not been authorised.
    ///
    /// Without this the failure arrives much later and much less legibly — the
    /// capture session simply produces no frames and the connection eventually
    /// times out.
    private func ensureCameraAuthorised() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            throw VtonPluginError(
                code: ErrorCodes.permissionDenied,
                message: "Camera permission has not been requested yet. Call "
                    + "AVCaptureDevice.requestAccess(for: .video) (or your Flutter "
                    + "permissions package) before connect()."
            )
        case .denied, .restricted:
            throw VtonPluginError(
                code: ErrorCodes.permissionDenied,
                message: "Camera access is denied or restricted for this app. "
                    + "The user must enable it in Settings."
            )
        @unknown default:
            throw VtonPluginError(
                code: ErrorCodes.permissionDenied,
                message: "Camera authorisation status is unknown."
            )
        }
    }

    private func teardownSession() async {
        for task in eventTasks { task.cancel() }
        eventTasks.removeAll()

        views.clearStreams()

        if let manager {
            await manager.disconnect()
        }
        manager = nil

        // The camera track is caller-owned: the SDK's `createLocalCameraStream`
        // hands it over and does not stop it for us. Leaving it running holds
        // the capture device and keeps the green camera indicator lit.
        if let track = localStream?.videoTrack as? LocalVideoTrack {
            try? await track.stop()
        }
        localStream = nil

        lastSessionId = nil
        lastTick = nil
    }

    private func startEventTasks(for manager: DecartRealtimeManager) {
        eventTasks.append(
            Task { [weak self] in
                for await state in manager.events {
                    guard let self else { return }
                    self.handle(state: state)
                }
            }
        )
        eventTasks.append(
            Task { [weak self] in
                for await stream in manager.remoteStreamUpdates {
                    guard let self else { return }
                    self.handle(remoteStream: stream)
                }
            }
        )
        eventTasks.append(
            Task { [weak self] in
                for await report in manager.connectionQualityUpdates {
                    guard let self else { return }
                    self.handle(quality: report)
                }
            }
        )
    }

    private func handle(state: DecartRealtimeState) {
        if state.connectionState != lastConnectionState {
            emitConnectionState(state.connectionState)
            // Android forwards the SDK's dedicated `errors` flow onto the event
            // channel. The iOS SDK has no such flow — a mid-session failure it
            // does not throw from surfaces only as this state transition. Without
            // synthesising an error event here, `DecartVton.errors` would never
            // emit anything at all on iOS.
            if state.connectionState == .error {
                events.send(
                    ChannelCodec.errorEvent(
                        code: ErrorCodes.webrtcError,
                        message: "The realtime session entered an error state. "
                            + "The iOS SDK does not report a specific cause; check "
                            + "network reachability and the API key's validity."
                    )
                )
            }
        }
        if let sessionId = state.sessionId, sessionId != lastSessionId {
            lastSessionId = sessionId
            events.send(ChannelCodec.sessionStartedEvent(sessionId: sessionId))
        }
        if let tick = state.generationTick, tick != lastTick {
            lastTick = tick
            events.send(ChannelCodec.generationTickEvent(seconds: tick))
        }
    }

    private func handle(remoteStream: RealtimeMediaStream) {
        views.setRemote(remoteStream)
        events.send(ChannelCodec.remoteStreamEvent())
    }

    private func handle(quality: ConnectionQualityReport) {
        events.send(ChannelCodec.connectionQualityEvent(quality))
    }

    private func emitConnectionState(_ state: DecartRealtimeConnectionState) {
        lastConnectionState = state
        events.send(ChannelCodec.connectionStateEvent(state))
    }
}
