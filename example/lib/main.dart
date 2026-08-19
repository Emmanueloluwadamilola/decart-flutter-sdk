import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:decart_vton_flutter/decart_vton_flutter.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TryOnApp());
}

const String _tokenEndpoint = String.fromEnvironment('DECART_TOKEN_ENDPOINT');
const String _developmentApiKey = String.fromEnvironment('DECART_API_KEY');
const int _maxReferenceImageBytes = 5 * 1024 * 1024;

Future<Uint8List> _readLimitedResponse(
  HttpClientResponse response, {
  required int maxBytes,
  required String description,
}) async {
  if (response.contentLength > maxBytes) {
    throw FormatException('$description is unexpectedly large.');
  }

  final output = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(const Duration(seconds: 10))) {
    if (output.length + chunk.length > maxBytes) {
      throw FormatException('$description is unexpectedly large.');
    }
    output.add(chunk);
  }
  return output.takeBytes();
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
  ('Straw hat', "Add a wide-brimmed straw hat to the person's head"),
  ('Round glasses', "Add thin round gold-framed glasses to the person's face"),
];

/// Ready-to-try direct JPEG garment references.
const List<(String, String)> _garmentPresets = <(String, String)>[
  (
    'Graphic tee',
    'https://www.artofbrilliance.co.uk/wp-content/uploads/2021/07/aob-tshirt.jpg',
  ),
  (
    'Sport set',
    'https://ng.jumia.is/unsafe/fit-in/680x680/filters:fill(white)/product/94/4870014/1.jpg?7253',
  ),
  (
    'Sand tee',
    'https://ng.jumia.is/unsafe/fit-in/680x680/filters:fill(white)/product/35/1949662/1.jpg?8767',
  ),
  (
    'Navy tee',
    'https://ng.jumia.is/unsafe/fit-in/680x680/filters:fill(white)/product/54/1456814/1.jpg?4481',
  ),
  (
    'Hoodie',
    'https://ng.jumia.is/unsafe/fit-in/680x680/filters:fill(white)/product/40/9702114/1.jpg?2705',
  ),
];

enum _ControlSection { prompt, garment }

class TryOnApp extends StatelessWidget {
  const TryOnApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Decart VTON example',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF090A0E),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF806BFF),
        brightness: Brightness.dark,
        surface: const Color(0xFF15161C),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF0E0F14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF292B35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF806BFF)),
        ),
      ),
    ),
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
  String? _status;
  String? _garmentName;
  Uint8List? _garment;
  String? _selectedGarmentUrl;
  String? _loadingGarmentUrl;
  _ControlSection? _openSection = _ControlSection.garment;
  bool _showCustomizer = false;
  bool _enhance = true;
  bool _busy = false;

  static const VtonModel _model = VtonModel.lucyVtonLatest;
  static const VtonResolution _resolution = VtonResolution.p720;

  @override
  void initState() {
    super.initState();
    _promptController.text = _presets.first.$2;
    _attachObservers();
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

  void _attachObservers() {
    _subs.add(
      _vton.connectionStates.listen((VtonConnectionState s) {
        if (mounted) setState(() => _state = s);
      }),
    );
    _subs.add(
      _vton.errors.listen((DecartVtonException e) {
        _reportFailure('${e.code.name}: ${e.message}');
      }),
    );
    _subs.add(
      _vton.events.listen((VtonEvent event) {
        if (!mounted) return;
        switch (event) {
          case VtonGenerationTick():
          case VtonConnectionQualityChanged():
          case VtonSessionStarted():
          case VtonConnectionStateChanged():
          case VtonRemoteStreamUpdated():
          case VtonLocalStreamUpdated():
          case VtonErrorOccurred():
            break;
        }
      }),
    );

    // Disconnect on background, reconnect on foreground, wearing whatever the
    // user last chose. Recommended by the Decart streaming best-practices guide.
    _lifecycle = VtonLifecycleObserver(
      onError: (DecartVtonException e) {
        _reportFailure('Reconnect failed: ${e.message}');
      },
    )..attach();

    _status = _tokenEndpoint.isNotEmpty && _developmentApiKey.isNotEmpty
        ? 'Invalid setup: configure only one authentication mode.'
        : _tokenEndpoint.isEmpty && _developmentApiKey.isEmpty
        ? 'Developer setup required before the camera can start.'
        : _tokenEndpoint.isNotEmpty
        ? 'Ready. Production client-token mode.'
        : 'Ready. Debug-only direct API-key mode.';
  }

  Future<String> _fetchClientToken() async {
    final uri = Uri.parse(_tokenEndpoint);
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException(
        'The client-token endpoint must be a complete HTTPS URL.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      request.headers.contentType = ContentType.json;
      request.write('{}');
      // Add your app's user/session authorization header here. Never put a
      // permanent Decart credential in this client.
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Token endpoint returned ${response.statusCode}',
          uri: uri,
        );
      }
      final bytes = await _readLimitedResponse(
        response,
        maxBytes: 64 * 1024,
        description: 'Token response',
      );
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Token response must be a JSON object.');
      }
      final token =
          payload['apiKey'] ?? payload['clientToken'] ?? payload['token'];
      if (token is! String || token.trim().isEmpty) {
        throw const FormatException(
          'Token response must contain apiKey, clientToken, or token.',
        );
      }
      return token.trim();
    } finally {
      client.close(force: true);
    }
  }

  // ── actions ───────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    await _guard('Preparing camera…', () async {
      if (!await _ensureDeveloperConfiguration()) return;
      if (!await _ensureCameraPermission()) return;
      if (!_vton.isInitialized) {
        if (_tokenEndpoint.isNotEmpty) {
          _setStatus('Creating a secure client-token session…');
          await _vton.initialize(clientTokenProvider: _fetchClientToken);
        } else {
          _setStatus('Creating a debug-only API-key session…');
          await _vton.initializeForDevelopment(apiKey: _developmentApiKey);
        }
      }
      _setStatus('Connecting camera…');
      await _vton.connect(
        model: _model,
        initialOutfit: _buildOutfit(),
        camera: VtonCameraFacing.front,
        mirror: VtonMirrorMode.auto,
        // VTON 3.5 is served at 1280x720 and supports only 720p output.
        resolution: _resolution,
      );
      _setStatus('Connected. Session ${_vton.sessionId ?? '—'}');
    });
  }

  Future<bool> _ensureDeveloperConfiguration() async {
    if (_tokenEndpoint.isNotEmpty && _developmentApiKey.isNotEmpty) {
      throw const FormatException(
        'Configure either DECART_TOKEN_ENDPOINT or DECART_API_KEY, not both.',
      );
    }
    if (_tokenEndpoint.isNotEmpty || _developmentApiKey.isNotEmpty) return true;
    if (!mounted) return false;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        icon: const Icon(Icons.settings_outlined),
        title: const Text('Developer configuration missing'),
        content: const Text(
          'This example does not ask users for credentials. Configure either '
          'the production client-token endpoint or the debug-only API key '
          'before launching it:\n\n'
          'cp -n example/env.example example/.env\n'
          '# Edit example/.env, then run:\n'
          'tool/run_example.sh',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    _setStatus('Developer setup required before the camera can start.');
    return false;
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
    if (!_vton.isConnected) {
      setState(() => _status = 'Prompt selected. Connect when you are ready.');
      return;
    }
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
      _selectedGarmentUrl = null;
    });
    if (_vton.isConnected) await _apply();
  }

  Future<void> _selectNetworkGarment(String name, String url) async {
    if (_loadingGarmentUrl != null || _busy) return;

    HttpClient? client;
    setState(() {
      _loadingGarmentUrl = url;
      _status = 'Loading $name…';
    });

    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Image server returned ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }

      final mimeType = response.headers.contentType?.mimeType;
      const supportedTypes = <String>{'image/jpeg', 'image/png', 'image/webp'};
      if (mimeType != null && !supportedTypes.contains(mimeType)) {
        throw const FormatException('The image must be JPEG, PNG, or WebP.');
      }

      final bytes = await _readLimitedResponse(
        response,
        maxBytes: _maxReferenceImageBytes,
        description: 'Reference image',
      );
      if (bytes.isEmpty) throw const FormatException('The image is empty.');

      if (!mounted) return;
      setState(() {
        _garment = bytes;
        _garmentName = name;
        _selectedGarmentUrl = url;
        _status = '$name selected as the reference image.';
      });
      if (_vton.isConnected) await _apply();
    } on SocketException catch (e) {
      _setStatus('Could not download $name: ${e.message}');
    } on TimeoutException {
      _setStatus('Could not download $name: the request timed out.');
    } on HttpException catch (e) {
      _setStatus('Could not download $name: ${e.message}');
    } on FormatException catch (e) {
      _setStatus('Could not use $name: ${e.message}');
    } finally {
      client?.close(force: true);
      if (mounted) setState(() => _loadingGarmentUrl = null);
    }
  }

  Future<void> _clearGarment() async {
    setState(() {
      _garment = null;
      _garmentName = null;
      _selectedGarmentUrl = null;
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
      _reportFailure('Invalid request: ${e.message}');
    } on DecartVtonException catch (e) {
      _reportFailure('${e.code.name}: ${e.message}');
    } on TimeoutException catch (e) {
      _reportFailure('Request timed out: ${e.message ?? 'try again'}');
    } on SocketException catch (e) {
      _reportFailure('Network error: ${e.message}');
    } on HttpException catch (e) {
      _reportFailure('HTTP error: ${e.message}');
    } on FormatException catch (e) {
      _reportFailure('Invalid response: ${e.message}');
    } on Object catch (e) {
      _reportFailure('Could not start the camera: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setStatus(String message) {
    if (mounted) setState(() => _status = message);
  }

  void _reportFailure(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final live = _state.isLive;
    return Scaffold(
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _buildStage(),
            // The video itself is the reveal target. Tapping anywhere away
            // from the floating panel opens or dismisses the customizer.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _showCustomizer = !_showCustomizer);
              },
            ),
            SafeArea(
              minimum: const EdgeInsets.all(12),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 80,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (Widget child, Animation<double> a) =>
                          FadeTransition(
                            opacity: a,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, .08),
                                end: Offset.zero,
                              ).animate(a),
                              child: child,
                            ),
                          ),
                      child: _showCustomizer
                          ? _buildCustomizer(
                              key: const ValueKey<String>('customizer'),
                              maxHeight: constraints.maxHeight * .58,
                            )
                          : const SizedBox(
                              key: ValueKey<String>('hidden-customizer'),
                            ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 20,
                    child: _buildSessionActions(live),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStage() => const Stack(
    fit: StackFit.expand,
    children: <Widget>[
      ColoredBox(color: Color(0xFF090A0E)),
      VtonRemoteView(),
    ],
  );

  Widget _buildCustomizer({Key? key, required double maxHeight}) =>
      ConstrainedBox(
        key: key,
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xF215161C),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF272933)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 2, 8),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Customize your look',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Hide customization controls',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          setState(() => _showCustomizer = false);
                        },
                        icon: const Icon(Icons.close, size: 19),
                      ),
                    ],
                  ),
                ),
                _buildPromptSection(),
                const SizedBox(height: 7),
                _buildGarmentSection(),
                if (_status != null) ...<Widget>[
                  const SizedBox(height: 8),
                  _buildStatus(),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _buildPromptSection() => _buildAccordionSection(
    section: _ControlSection.prompt,
    icon: Icons.edit_outlined,
    title: 'Describe the look',
    summary: _promptController.text.trim().isEmpty
        ? 'Optional styling prompt'
        : _promptController.text.trim(),
    child: Column(
      children: <Widget>[
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _presets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 7),
            itemBuilder: (BuildContext context, int i) {
              final (String label, String prompt) = _presets[i];
              return ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(label, style: const TextStyle(fontSize: 11)),
                onPressed: _busy
                    ? null
                    : () => _applyPromptKeepingGarment(prompt),
              );
            },
          ),
        ),
        const SizedBox(height: 9),
        TextField(
          controller: _promptController,
          minLines: 1,
          maxLines: 2,
          textInputAction: TextInputAction.done,
          style: const TextStyle(fontSize: 13),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Substitute the current top with…',
            contentPadding: EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            isDense: true,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Let Decart refine short prompts',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
            const Text(
              'Enhance',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
            Transform.scale(
              scale: .78,
              child: Switch.adaptive(
                value: _enhance,
                onChanged: _busy
                    ? null
                    : (bool value) => setState(() => _enhance = value),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _buildGarmentSection() => _buildAccordionSection(
    section: _ControlSection.garment,
    icon: Icons.checkroom_outlined,
    title: 'Choose a garment',
    summary: _garmentName ?? 'Select a reference image',
    child: Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Tap a product photo to try it on',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
            if (_garment != null)
              TextButton.icon(
                onPressed: _busy ? null : _clearGarment,
                icon: const Icon(Icons.close, size: 15),
                label: const Text('Clear'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        const SizedBox(height: 5),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _garmentPresets.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int index) {
              if (index == 0) return _buildUploadTile();
              final (String name, String url) = _garmentPresets[index - 1];
              return _buildGarmentTile(name, url);
            },
          ),
        ),
      ],
    ),
  );

  Widget _buildAccordionSection({
    required _ControlSection section,
    required IconData icon,
    required String title,
    required String summary,
    required Widget child,
  }) {
    final expanded = _openSection == section;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: expanded ? const Color(0xFF1B1C24) : const Color(0xFF111218),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: expanded ? const Color(0x66806BFF) : const Color(0xFF242630),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          InkWell(
            onTap: () =>
                setState(() => _openSection = expanded ? null : section),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: expanded
                          ? const Color(0x33806BFF)
                          : const Color(0xFF20212A),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      size: 17,
                      color: expanded
                          ? const Color(0xFFAA9DFF)
                          : Colors.white60,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? .5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(11, 0, 11, 10),
                    child: child,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadTile() {
    final selected = _garment != null && _selectedGarmentUrl == null;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Choose a garment from the photo library',
      child: InkWell(
        onTap: _busy ? null : _pickGarment,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 76,
          decoration: BoxDecoration(
            color: const Color(0xFF101116),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? const Color(0xFF8E7BFF)
                  : const Color(0xFF30323D),
              width: selected ? 2 : 1,
            ),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.add_photo_alternate_outlined, size: 23),
              SizedBox(height: 7),
              Text(
                'Your photo',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGarmentTile(String name, String url) {
    final selected = _selectedGarmentUrl == url;
    final loading = _loadingGarmentUrl == url;
    return Semantics(
      button: true,
      selected: selected,
      label: '$name garment',
      child: InkWell(
        onTap: _busy || _loadingGarmentUrl != null
            ? null
            : () => _selectNetworkGarment(name, url),
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 76,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? const Color(0xFF8E7BFF)
                  : const Color(0xFF30323D),
              width: selected ? 3 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image.network(
                url,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                loadingBuilder: (_, Widget child, ImageChunkEvent? progress) =>
                    progress == null
                    ? child
                    : const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.black38,
                    size: 22,
                  ),
                ),
              ),
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Colors.transparent, Color(0xB3000000)],
                      stops: <double>[.45, 1],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 5,
                right: 5,
                bottom: 6,
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (selected)
                const Positioned(
                  right: 5,
                  top: 5,
                  child: CircleAvatar(
                    radius: 9,
                    backgroundColor: Color(0xFF806BFF),
                    child: Icon(Icons.check, size: 12, color: Colors.white),
                  ),
                ),
              if (loading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0x88000000),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionActions(bool live) => Row(
    children: <Widget>[
      Expanded(
        child: FilledButton.icon(
          onPressed: _busy ? null : (live ? _apply : _connect),
          icon: Icon(
            live ? Icons.auto_awesome : Icons.videocam_outlined,
            size: 18,
          ),
          label: Text(live ? 'Apply look' : 'Start camera'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        tooltip: 'Switch camera (reconnects)',
        onPressed: _busy || !live ? null : _switchCamera,
        icon: const Icon(Icons.cameraswitch_outlined, size: 20),
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        tooltip: 'Disconnect',
        onPressed: _busy || !_state.isInSession ? null : _disconnect,
        icon: const Icon(Icons.stop_rounded, size: 21),
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
      ),
    ],
  );

  Widget _buildStatus() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFF101116),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: Colors.white38,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            _status!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white54),
          ),
        ),
      ],
    ),
  );
}
