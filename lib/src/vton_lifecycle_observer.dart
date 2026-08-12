import 'dart:async';

import 'package:flutter/widgets.dart';

import 'decart_vton.dart';
import 'models/vton_error.dart';
import 'models/vton_model.dart';
import 'models/vton_outfit.dart';

/// Disconnects the try-on session when the app is backgrounded and reconnects
/// it when the app returns to the foreground.
///
/// This is not automatic behaviour of the plugin, because "what should happen
/// when the user takes a phone call" is a product decision. But it *is* the
/// behaviour the Decart streaming best-practices guide recommends for mobile,
/// and getting it wrong is expensive: a WebRTC session held open in the
/// background drains battery, keeps the camera claimed, and will be killed by
/// the OS anyway — often in a way that leaves the native SDK reconnecting into
/// a dead camera.
///
/// ```dart
/// class _TryOnPageState extends State<TryOnPage> {
///   late final VtonLifecycleObserver _observer;
///
///   @override
///   void initState() {
///     super.initState();
///     _observer = VtonLifecycleObserver(
///       model: VtonModel.lucyVtonLatest,
///       outfit: () => DecartVton().currentOutfit,
///       onError: (e) => debugPrint('reconnect failed: $e'),
///     )..attach();
///   }
///
///   @override
///   void dispose() {
///     _observer.detach();
///     super.dispose();
///   }
/// }
/// ```
///
/// The observer only reconnects sessions **it** disconnected, so it will not
/// resurrect a session the user deliberately ended.
class VtonLifecycleObserver with WidgetsBindingObserver {
  /// Creates an observer.
  ///
  /// [model] is the model to reconnect with. [outfit] is called at reconnect
  /// time so the restored session comes back wearing whatever the user last
  /// chose; returning `null` reconnects with no initial outfit.
  VtonLifecycleObserver({
    required this.model,
    this.outfit,
    this.onError,
    this.camera = VtonCameraFacing.front,
    this.mirror = VtonMirrorMode.auto,
    this.resolution,
    DecartVton? instance,
  }) : _vton = instance ?? DecartVton();

  /// Model to reconnect with.
  final VtonModel model;

  /// Supplies the outfit to restore on reconnect.
  final VtonOutfit? Function()? outfit;

  /// Called when an automatic reconnect fails.
  ///
  /// Without this, a failed reconnect is silent — the user just sees a blank
  /// view. Wire it to whatever your app does with recoverable errors.
  final void Function(DecartVtonException error)? onError;

  /// Camera to reconnect with.
  final VtonCameraFacing camera;

  /// Mirror mode to reconnect with.
  final VtonMirrorMode mirror;

  /// Resolution to reconnect with.
  final VtonResolution? resolution;

  final DecartVton _vton;

  bool _attached = false;
  bool _weDisconnected = false;
  Future<void>? _inFlight;

  /// Starts observing app lifecycle changes.
  void attach() {
    if (_attached) return;
    WidgetsBinding.instance.addObserver(this);
    _attached = true;
  }

  /// Stops observing. Always call this from your `State.dispose`.
  void detach() {
    if (!_attached) return;
    WidgetsBinding.instance.removeObserver(this);
    _attached = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _run(_handleBackground);
      case AppLifecycleState.resumed:
        _run(_handleForeground);
      case AppLifecycleState.inactive:
        // Transient (notification shade, incoming call banner). Tearing the
        // session down here would thrash on every minor interruption.
        break;
    }
  }

  Future<void> _handleBackground() async {
    if (!_vton.isInitialized) return;
    if (!_vton.connectionState.isInSession) return;
    _weDisconnected = true;
    await _vton.disconnect();
  }

  /// Serialises lifecycle work so a fast background/foreground bounce cannot
  /// start a connect while a disconnect is still unwinding.
  ///
  /// The `catchError` is load-bearing, not defensive padding. Without it a
  /// single failure — say `disconnect()` throwing because the OS already tore
  /// the session down — would leave `_inFlight` in an error state, and every
  /// subsequent `.then()` would propagate that error instead of running its
  /// action. The observer would silently stop working for the rest of the
  /// app's life.
  void _run(Future<void> Function() action) {
    _inFlight = (_inFlight ?? Future<void>.value())
        .then((_) => action())
        .catchError((Object error, StackTrace stack) {
      if (error is DecartVtonException) {
        onError?.call(error);
      } else {
        onError?.call(
          DecartVtonException(
            VtonErrorCode.unknown,
            'Lifecycle transition failed: $error',
          ),
        );
      }
    });
  }

  Future<void> _handleForeground() async {
    if (!_weDisconnected) return;
    _weDisconnected = false;
    if (!_vton.isInitialized) return;
    try {
      await _vton.connect(
        model: model,
        initialOutfit: outfit?.call(),
        camera: camera,
        mirror: mirror,
        resolution: resolution,
      );
    } on DecartVtonException catch (e) {
      onError?.call(e);
    }
  }
}
