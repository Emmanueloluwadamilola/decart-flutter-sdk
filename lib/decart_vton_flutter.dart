/// Realtime virtual try-on for Flutter, wrapping the native Decart
/// Android and iOS SDKs (Lucy VTON).
///
/// Start with [DecartVton]:
///
/// ```dart
/// final vton = DecartVton();
/// await vton.initialize(clientTokenProvider: fetchClientToken);
/// await vton.connect(model: VtonModel.lucyVtonLatest);
/// await vton.setOutfit(prompt: 'Substitute the current top with a red parka');
/// ```
///
/// …and render the result with [VtonRemoteView].
library;

export 'src/decart_vton.dart' show DecartVton, VtonClientTokenProvider;
export 'src/models/vton_connection_state.dart'
    show VtonConnectionQuality, VtonConnectionState, VtonConnectivityReport;
export 'src/models/vton_error.dart' show DecartVtonException, VtonErrorCode;
export 'src/models/vton_event.dart'
    show
        VtonConnectionQualityChanged,
        VtonConnectionStateChanged,
        VtonErrorOccurred,
        VtonEvent,
        VtonGenerationTick,
        VtonLocalStreamUpdated,
        VtonRemoteStreamUpdated,
        VtonSessionStarted;
export 'src/models/vton_model.dart'
    show
        VtonCameraFacing,
        VtonLogLevel,
        VtonMirrorMode,
        VtonModel,
        VtonResolution,
        VtonVideoConfig;
export 'src/models/vton_outfit.dart' show VtonOutfit;
export 'src/vton_lifecycle_observer.dart' show VtonLifecycleObserver;
export 'src/widgets/vton_video_view.dart'
    show VtonLocalPreview, VtonRemoteView, VtonVideoFit;
