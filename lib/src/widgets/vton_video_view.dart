import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../decart_vton_platform.dart';

/// How a video track is fitted into the widget's box.
enum VtonVideoFit {
  /// Fill the box, cropping whatever does not fit. The usual choice for a
  /// full-bleed camera view.
  cover,

  /// Fit the whole frame inside the box, letterboxing as needed. The usual
  /// choice when the aspect ratio matters more than filling the space.
  contain,
}

/// Which native track a [VtonVideoView] is bound to.
///
/// Not exported from the package barrel; internal to the widget layer.
enum VtonVideoSource {
  /// The transformed video coming back from the model.
  remote,

  /// The raw camera feed being published.
  local,
}

/// Renders the **transformed** try-on video returned by the model.
///
/// This is a native view — a LiveKit `TextureViewRenderer` on Android and a
/// LiveKit `VideoView` on iOS — hosted in the Flutter tree as a platform view.
/// A `MethodChannel` cannot carry video frames, so there is no pure-Dart
/// alternative.
///
/// The view binds itself to whatever the current remote track is, and **rebinds
/// automatically** when the SDK reconnects and produces a new one. You do not
/// need to rebuild it in response to `VtonRemoteStreamUpdated`.
///
/// Before a session is connected the view renders as an empty (transparent)
/// native surface, so it is safe to place it in the tree ahead of `connect()`.
/// You will usually want to stack a placeholder behind it.
///
/// ```dart
/// Stack(
///   fit: StackFit.expand,
///   children: [
///     const ColoredBox(color: Color(0xFF101014)),
///     const VtonRemoteView(fit: VtonVideoFit.cover),
///   ],
/// )
/// ```
class VtonRemoteView extends StatelessWidget {
  /// Creates a view bound to the transformed remote track.
  const VtonRemoteView({
    super.key,
    this.fit = VtonVideoFit.cover,
    this.mirror = false,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
  });

  /// How the frame is fitted into the widget's box.
  final VtonVideoFit fit;

  /// Whether to mirror the rendered output horizontally.
  ///
  /// Usually leave this `false`. The SDK already pre-flips the *outgoing*
  /// frames according to `VtonMirrorMode`, and flipping again at display time
  /// would reverse anything the server baked into the returned pixels.
  final bool mirror;

  /// Gesture recognizers the platform view should claim.
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  @override
  Widget build(BuildContext context) => VtonVideoView(
    source: VtonVideoSource.remote,
    fit: fit,
    mirror: mirror,
    gestureRecognizers: gestureRecognizers,
  );
}

/// Renders the **raw camera** feed being published, before transformation.
///
/// Useful as a small picture-in-picture self-view next to [VtonRemoteView] so
/// the user can see they are framed correctly even while the model output is
/// still warming up.
class VtonLocalPreview extends StatelessWidget {
  /// Creates a view bound to the local camera track.
  const VtonLocalPreview({
    super.key,
    this.fit = VtonVideoFit.cover,
    this.mirror = true,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
  });

  /// How the frame is fitted into the widget's box.
  final VtonVideoFit fit;

  /// Whether to mirror the preview horizontally.
  ///
  /// Defaults to `true` because an un-mirrored front-camera self-view feels
  /// wrong to most people. This affects display only; it does not change what
  /// is sent to the server.
  final bool mirror;

  /// Gesture recognizers the platform view should claim.
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  @override
  Widget build(BuildContext context) => VtonVideoView(
    source: VtonVideoSource.local,
    fit: fit,
    mirror: mirror,
    gestureRecognizers: gestureRecognizers,
  );
}

/// Shared platform-view host.
///
/// Not exported from the package barrel; [VtonRemoteView] and
/// [VtonLocalPreview] are the public entry points.
class VtonVideoView extends StatelessWidget {
  /// Creates the platform view host.
  const VtonVideoView({
    super.key,
    required this.source,
    required this.fit,
    required this.mirror,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
  });

  /// Which native track to bind to.
  final VtonVideoSource source;

  /// How the frame is fitted.
  final VtonVideoFit fit;

  /// Whether to mirror at display time.
  final bool mirror;

  /// Gesture recognizers the platform view should claim.
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  Map<String, Object?> get _creationParams => <String, Object?>{
    'source': source.name,
    'fit': fit.name,
    'mirror': mirror,
  };

  @override
  Widget build(BuildContext context) {
    // `defaultTargetPlatform` rather than `dart:io`, so importing this library
    // does not break a web build of a package that merely depends on us.
    if (kIsWeb) return const _UnsupportedPlatform();

    if (defaultTargetPlatform == TargetPlatform.android) {
      // Hybrid composition (`initExpensiveAndroidView`) rather than the cheaper
      // texture-layer path. The LiveKit renderers manage their own EGL surface
      // and do not survive the texture-layer copy reliably across the device
      // matrix; hybrid composition composites any native view correctly at the
      // cost of a little extra GPU work. See IMPLEMENTATION.md.
      return PlatformViewLink(
        viewType: DecartVtonPlatform.videoViewType,
        surfaceFactory:
            (BuildContext context, PlatformViewController controller) {
              return AndroidViewSurface(
                controller: controller as AndroidViewController,
                gestureRecognizers: gestureRecognizers,
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
              );
            },
        onCreatePlatformView: (PlatformViewCreationParams params) {
          return PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: DecartVtonPlatform.videoViewType,
              layoutDirection: TextDirection.ltr,
              creationParams: _creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create();
        },
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: DecartVtonPlatform.videoViewType,
        layoutDirection: TextDirection.ltr,
        creationParams: _creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: gestureRecognizers,
      );
    }

    return const _UnsupportedPlatform();
  }
}

class _UnsupportedPlatform extends StatelessWidget {
  const _UnsupportedPlatform();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF000000),
    child: Center(
      child: Text(
        'decart_vton_flutter supports Android and iOS only.',
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
      ),
    ),
  );
}
