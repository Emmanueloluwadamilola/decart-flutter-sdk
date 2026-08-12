import 'dart:async';
import 'dart:typed_data';

import 'package:decart_vton_flutter/decart_vton_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The key lives in example/.env, which is git-ignored. See .env.example.
  await dotenv.load(isOptional: true);
  runApp(const TryOnApp());
}

/// Preset prompts, written in the "substitute" / "add" style the model
/// documentation recommends. Vague fragments like "red hoodie" produce
/// noticeably worse results.
const List<(String, String)> _presets = <(String, String)>[
  (
    'Navy hoodie',
    'Substitute the current top with a navy blue hoodie with a white drawstring',
  ),
  (
    'Leather jacket',
    'Substitute the current top with a black leather biker jacket with silver zips',
  ),
  (
    'White shirt',
    'Substitute the current top with a crisp white cotton oxford shirt, buttoned',
  ),
  (
    'Straw hat',
    "Add a wide-brimmed straw hat to the person's head",
  ),
  (
    'Round glasses',
    "Add thin round gold-framed glasses to the person's face",
  ),
];

class TryOnApp extends StatelessWidget {
  const TryOnApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Decart VTON example',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const TryOnPage(),
      );
}

class TryOnPage extends StatefulWidget {
  const TryOnPage({super.key});

  @override
  State<TryOnPage> createState() => _TryOnPageState();
}

class _TryOnPageState extends State<TryOnPage> {
  final DecartVton _vton = DecartVton();
  final TextEditingController _promptController = TextEditingController();
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  VtonLifecycleObserver? _lifecycle;

  VtonConnectionState _state = VtonConnectionState.idle;
  VtonConnectionQuality _quality = VtonConnectionQuality.unknown;
  Duration _elapsed = Duration.zero;
  String? _status;
  String? _garmentName;
  Uint8List? _garment;
  bool _enhance = true;
  bool _busy = false;

  static const VtonModel _model = VtonModel.lucyVtonLatest;

  @override
  void initState() {
    super.initState();
    _promptController.text = _presets.first.$2;
    _bootstrap();
  }

  @override
  void dispose() {
    _lifecycle?.detach();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _promptController.dispose();
    unawaited(_vton.dispose());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final key = dotenv.maybeGet('DECART_API_KEY') ?? '';
    if (key.isEmpty) {
      setState(() => _status =
          'No DECART_API_KEY found. Copy example/.env.example to example/.env '
              'and add your key, then restart the app.');
      return;
    }

    try {
      await _vton.initialize(apiKey: key);
    } on DecartVtonException catch (e) {
      setState(() => _status = 'Initialize failed: ${e.message}');
      return;
    }

    _subs.add(_vton.connectionStates.listen((VtonConnectionState s) {
      if (mounted) setState(() => _state = s);
    }));
    _subs.add(_vton.errors.listen((DecartVtonException e) {
      if (mounted) setState(() => _status = '${e.code.name}: ${e.message}');
    }));
    _subs.add(_vton.events.listen((VtonEvent event) {
      if (!mounted) return;
      switch (event) {
        case VtonGenerationTick(:final elapsed):
          setState(() => _elapsed = elapsed);
        case VtonConnectionQualityChanged(:final quality):
          setState(() => _quality = quality);
        case VtonSessionStarted():
        case VtonConnectionStateChanged():
        case VtonRemoteStreamUpdated():
        case VtonLocalStreamUpdated():
        case VtonErrorOccurred():
          break;
      }
    }));

    // Disconnect on background, reconnect on foreground, wearing whatever the
    // user last chose. Recommended by the Decart streaming best-practices guide.
    _lifecycle = VtonLifecycleObserver(
      model: _model,
      outfit: () => _vton.currentOutfit,
      onError: (DecartVtonException e) {
        if (mounted) setState(() => _status = 'Reconnect failed: ${e.message}');
      },
    )..attach();

    if (mounted) setState(() => _status = 'Ready. Tap Connect.');
  }

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    if (!await _ensureCameraPermission()) return;

    await _guard('Connecting…', () async {
      await _vton.connect(
        model: _model,
        initialOutfit: _buildOutfit(),
        camera: VtonCameraFacing.front,
        mirror: VtonMirrorMode.auto,
        resolution: VtonResolution.p720,
      );
      _setStatus('Connected. Session ${_vton.sessionId ?? '—'}');
    });
  }

  Future<void> _apply() async {
    await _guard('Applying outfit…', () async {
      await _vton.setOutfit(outfit: _buildOutfit());
      _setStatus('Outfit applied.');
    });
  }

  /// Demonstrates the "change one field, keep the rest" pattern.
  ///
  /// Calling `setOutfit(prompt: ...)` here instead would silently clear the
  /// garment image, because the API replaces the whole state on every update.
  Future<void> _applyPromptKeepingGarment(String prompt) async {
    final current = _vton.currentOutfit;
    _promptController.text = prompt;
    await _guard('Applying outfit…', () async {
      await _vton.setOutfit(
        outfit: current == null
            ? VtonOutfit(prompt: prompt, enhance: _enhance)
            : current.copyWith(prompt: prompt, enhance: _enhance),
      );
      _setStatus('Outfit applied.');
    });
  }

  Future<void> _pickGarment() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 90,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _garment = bytes;
      _garmentName = picked.name;
    });
    if (_vton.isConnected) await _apply();
  }

  Future<void> _clearGarment() async {
    setState(() {
      _garment = null;
      _garmentName = null;
    });
    if (_vton.isConnected) await _apply();
  }

  Future<void> _switchCamera() async {
    await _guard('Switching camera (reconnects)…', () async {
      final facing = await _vton.switchCamera();
      _setStatus('Now using the ${facing.name} camera.');
    });
  }

  Future<void> _disconnect() async {
    await _guard('Disconnecting…', () async {
      await _vton.disconnect();
      _setStatus('Disconnected.');
    });
  }

  VtonOutfit? _buildOutfit() {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty && _garment == null) return null;
    return VtonOutfit(
      prompt: prompt.isEmpty ? null : prompt,
      referenceImage: _garment,
      enhance: _enhance,
    );
  }

  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) return true;
    _setStatus(
      status.isPermanentlyDenied
          ? 'Camera permission is permanently denied — enable it in Settings.'
          : 'Camera permission is required for try-on.',
    );
    return false;
  }

  Future<void> _guard(String pending, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = pending;
    });
    try {
      await action();
    } on ArgumentError catch (e) {
      _setStatus('Invalid request: ${e.message}');
    } on DecartVtonException catch (e) {
      _setStatus('${e.code.name}: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setStatus(String message) {
    if (mounted) setState(() => _status = message);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final live = _state.isLive;
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D10),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(child: _buildStage(live)),
            _buildControls(live),
          ],
        ),
      ),
    );
  }

  Widget _buildStage(bool live) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ColoredBox(color: Color(0xFF17171C)),
          // The transformed try-on output.
          const VtonRemoteView(),
          if (!live)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _state == VtonConnectionState.connecting
                      ? 'Connecting…'
                      : 'Not connected',
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
              ),
            ),
          // Raw camera, as a small self-view.
          if (live)
            Positioned(
              right: 12,
              top: 12,
              width: 96,
              height: 128,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: const VtonLocalPreview(),
              ),
            ),
          Positioned(left: 12, top: 12, child: _buildBadge()),
        ],
      );

  Widget _buildBadge() {
    final label = switch (_state) {
      VtonConnectionState.generating => 'live · ${_elapsed.inSeconds}s',
      VtonConnectionState.connected => 'connected',
      VtonConnectionState.connecting => 'connecting',
      VtonConnectionState.reconnecting => 'reconnecting',
      VtonConnectionState.error => 'error',
      VtonConnectionState.disconnected => 'disconnected',
      VtonConnectionState.idle => 'idle',
    };
    final colour = switch (_state) {
      VtonConnectionState.generating ||
      VtonConnectionState.connected =>
        const Color(0xFF3DDC84),
      VtonConnectionState.connecting ||
      VtonConnectionState.reconnecting =>
        const Color(0xFFFFC107),
      VtonConnectionState.error => const Color(0xFFFF5252),
      _ => Colors.white38,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x8C000000),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 8, color: colour),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
          if (_quality != VtonConnectionQuality.unknown) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              'net: ${_quality.name}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildControls(bool live) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        color: const Color(0xFF0D0D10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _presets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (BuildContext context, int i) {
                  final (String label, String prompt) = _presets[i];
                  return ActionChip(
                    label: Text(label),
                    onPressed: live && !_busy
                        ? () => _applyPromptKeepingGarment(prompt)
                        : null,
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promptController,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Prompt',
                helperText: 'Try: "Substitute the current top with …" '
                    'or "Add … to the person\'s head"',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickGarment,
                    icon: const Icon(Icons.checkroom, size: 18),
                    label: Text(
                      _garmentName == null ? 'Garment image' : 'Change garment',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (_garment != null) ...<Widget>[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Remove garment image',
                    onPressed: _busy ? null : _clearGarment,
                    icon: const Icon(Icons.close),
                  ),
                ],
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Let the server expand short prompts',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('enhance', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _enhance,
                        onChanged: _busy
                            ? null
                            : (bool v) => setState(() => _enhance = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : (live ? _apply : _connect),
                    child: Text(live ? 'Apply outfit' : 'Connect'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Switch camera (reconnects)',
                  onPressed: _busy || !live ? null : _switchCamera,
                  icon: const Icon(Icons.cameraswitch),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Disconnect',
                  onPressed: _busy || !_state.isInSession ? null : _disconnect,
                  icon: const Icon(Icons.stop),
                ),
              ],
            ),
            if (_status != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _status!,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          ],
        ),
      );
}
