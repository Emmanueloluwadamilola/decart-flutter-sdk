import AVFoundation
import DecartSDK
import Flutter
import Foundation

/// The one place on the iOS side that knows the platform-channel wire format.
///
/// Its counterparts are `lib/src/decart_vton_platform.dart` and
/// `ChannelCodec.kt`. Change a key here and change it in both of those too —
/// the contract is written out in IMPLEMENTATION.md.
enum ChannelCodec {

    // MARK: - Argument decoding

    static func requireArgs(_ arguments: Any?) throws -> [String: Any] {
        if arguments == nil { return [:] }
        guard let map = arguments as? [String: Any] else {
            throw VtonPluginError(
                code: ErrorCodes.invalidInput,
                message: "Expected a map of arguments but received \(type(of: arguments))."
            )
        }
        return map
    }

    static func string(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    static func int(_ args: [String: Any], _ key: String, _ fallback: Int) -> Int {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        return fallback
    }

    static func bool(_ args: [String: Any], _ key: String, _ fallback: Bool) -> Bool {
        if let value = args[key] as? Bool { return value }
        if let value = args[key] as? NSNumber { return value.boolValue }
        return fallback
    }

    /// Standard-codec `Uint8List` arrives as `FlutterStandardTypedData`.
    static func bytes(_ args: [String: Any], _ key: String) -> Data? {
        if let typed = args[key] as? FlutterStandardTypedData {
            return typed.data.isEmpty ? nil : typed.data
        }
        if let data = args[key] as? Data {
            return data.isEmpty ? nil : data
        }
        return nil
    }

    static func map(_ args: [String: Any], _ key: String) -> [String: Any]? {
        args[key] as? [String: Any]
    }

    // MARK: - Enum mapping

    static func position(_ wire: String?) -> AVCaptureDevice.Position {
        wire == "back" ? .back : .front
    }

    static func mirror(_ wire: String?) -> MirrorMode {
        switch wire {
        case "off": return .off
        case "on": return .on
        default: return .auto
        }
    }

    static func resolution(_ wire: String?) -> Resolution? {
        switch wire {
        case "720p": return .p720
        case "1080p": return .p1080
        default: return nil
        }
    }

    /// Collapses the iOS SDK's seven-case state onto the shared wire vocabulary.
    ///
    /// All seven map one-to-one; the Dart enum was widened to the union of both
    /// platforms specifically so nothing has to be lost here.
    static func connectionStateToWire(_ state: DecartRealtimeConnectionState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .generating: return "generating"
        case .reconnecting: return "reconnecting"
        case .disconnected: return "disconnected"
        case .error: return "error"
        }
    }

    /// Same four-to-five mapping as `ChannelCodec.qualityToWire` on Android.
    static func qualityToWire(_ quality: ConnectionQuality) -> String {
        switch quality {
        case .good: return "excellent"
        case .fair: return "good"
        case .poor: return "poor"
        case .critical: return "unusable"
        }
    }

    static func transportToWire(_ transport: ConnectivityTransport) -> String {
        transport.rawValue
    }

    // MARK: - Configuration building

    /// Builds a `ModelDefinition` from what Dart sent.
    ///
    /// Deliberately constructed rather than looked up in `Models.realtime(_:)`:
    /// the Dart `VtonModel` enum is the single source of truth for dimensions,
    /// frame rate and reference-image support, so a new server-side model needs
    /// one Dart edit rather than three.
    static func modelDefinition(_ args: [String: Any]) -> ModelDefinition {
        ModelDefinition(
            name: string(args, "model") ?? "lucy-vton-latest",
            urlPath: "/v1/stream",
            fps: int(args, "fps", 30),
            width: int(args, "width", 1088),
            height: int(args, "height", 624),
            hasReferenceImage: bool(args, "supportsReferenceImage", true)
        )
    }

    static func realtimeConfiguration(
        _ args: [String: Any],
        model: ModelDefinition,
        initialPrompt: DecartPrompt
    ) -> RealtimeConfiguration {
        let video = map(args, "video")
        return RealtimeConfiguration(
            model: model,
            initialPrompt: initialPrompt,
            resolution: resolution(string(args, "resolution")),
            connection: RealtimeConfiguration.ConnectionConfig(
                connectionTimeout: TimeInterval(int(args, "connectTimeoutMs", 30_000)) / 1000.0
            ),
            media: RealtimeConfiguration.MediaConfig(
                video: RealtimeConfiguration.VideoConfig(
                    maxBitrate: video.map { int($0, "maxBitrate", 2_500_000) } ?? 2_500_000,
                    maxFramerate: video.map { int($0, "maxFramerate", 30) } ?? 30,
                    // The iOS SDK defaults to h264 and Android to vp8. Dart
                    // pins vp8 on both so the same code behaves the same way;
                    // see VtonVideoConfig.
                    preferredCodec: video.flatMap { string($0, "preferredCodec") } ?? "vp8",
                    simulcast: video.map { bool($0, "simulcast", true) } ?? true
                )
            )
        )
    }

    // MARK: - Event payloads

    static func connectionStateEvent(_ state: DecartRealtimeConnectionState) -> [String: Any?] {
        ["type": "connectionState", "state": connectionStateToWire(state)]
    }

    static func sessionStartedEvent(sessionId: String) -> [String: Any?] {
        // The iOS SDK does not surface `subscribeToken` at v0.6.9 — Android
        // does. The key is still sent (as nil) so the payload shape matches.
        ["type": "sessionStarted", "sessionId": sessionId, "subscribeToken": nil]
    }

    static func generationTickEvent(seconds: Double) -> [String: Any?] {
        ["type": "generationTick", "seconds": seconds]
    }

    static func remoteStreamEvent() -> [String: Any?] {
        ["type": "remoteStreamUpdated"]
    }

    static func localStreamEvent() -> [String: Any?] {
        ["type": "localStreamUpdated"]
    }

    static func errorEvent(code: String, message: String) -> [String: Any?] {
        ["type": "error", "code": code, "message": message, "details": nil]
    }

    static func connectionQualityEvent(_ report: ConnectionQualityReport) -> [String: Any?] {
        [
            "type": "connectionQuality",
            "quality": qualityToWire(report.quality),
            "roundTripMs": report.metrics.rttMs.map { Int($0.rounded()) },
            "packetLoss": report.metrics.packetLoss,
            "jitterMs": report.metrics.upstreamJitterMs.map { Int($0.rounded()) }
        ]
    }
}
