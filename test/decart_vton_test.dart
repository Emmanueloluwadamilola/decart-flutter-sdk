import 'dart:async';

import 'package:decart_vton_flutter/decart_vton_flutter.dart';
import 'package:decart_vton_flutter/src/decart_vton_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _jpegBytes([List<int> payload = const <int>[]]) =>
    Uint8List.fromList(<int>[0xff, 0xd8, 0xff, ...payload]);

/// Records every method-channel call and replies with whatever the test set up.
class _FakeHost {
  _FakeHost(this.methodChannel);

  final MethodChannel methodChannel;
  final List<MethodCall> calls = <MethodCall>[];

  /// Per-method canned replies. A `PlatformException` value is thrown instead.
  final Map<String, Object?> replies = <String, Object?>{};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          calls.add(call);
          final reply = replies[call.method];
          if (reply is PlatformException) throw reply;
          if (reply is Future<Object?>) return reply;
          return reply;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  }

  MethodCall callTo(String method) =>
      calls.firstWhere((MethodCall c) => c.method == method);

  Map<Object?, Object?> argsOf(String method) =>
      callTo(method).arguments as Map<Object?, Object?>;

  bool wasCalled(String method) =>
      calls.any((MethodCall c) => c.method == method);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannelName = 'test/decart/methods';
  const eventChannelName = 'test/decart/events';

  late DecartVtonPlatform platform;
  late _FakeHost host;
  late DecartVton vton;
  late MockStreamHandler streamHandler;
  MockStreamHandlerEventSink? eventSink;

  /// Pushes a native event onto the mocked event channel and lets it settle.
  ///
  /// The first pump matters: `initialize()` subscribes to the event channel,
  /// but the subscription handshake goes through the binary messenger and is
  /// therefore asynchronous. Without draining the queue first, the very first
  /// emitted event can land before `onListen` has run.
  Future<void> emit(Map<String, Object?> event) async {
    await pumpEventQueue();
    eventSink?.success(event);
    await pumpEventQueue();
  }

  /// Drives the plugin to a live, connected session.
  Future<void> connectAndGoLive({
    VtonModel model = VtonModel.lucyVtonLatest,
    VtonOutfit? initialOutfit,
  }) async {
    await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
    await vton.connect(model: model, initialOutfit: initialOutfit);
    await emit(<String, Object?>{
      'type': 'connectionState',
      'state': 'generating',
    });
  }

  setUp(() {
    platform = DecartVtonPlatform(
      methodChannelName: methodChannelName,
      eventChannelName: eventChannelName,
    );
    host = _FakeHost(platform.methodChannel)..install();
    host.replies['connect'] = <Object?, Object?>{'sessionId': 'sess-123'};
    host.replies['isConnected'] = true;

    streamHandler = MockStreamHandler.inline(
      onListen: (Object? arguments, MockStreamHandlerEventSink sink) {
        eventSink = sink;
      },
      onCancel: (Object? arguments) {
        eventSink = null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel(eventChannelName),
          streamHandler,
        );

    vton = DecartVton.forTesting(platform);
  });

  tearDown(() async {
    host.uninstall();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel(eventChannelName), null);
    eventSink = null;
    DecartVton.resetInstanceForTesting();
  });

  // ───────────────────────────────────────────────────────────── initialize ──

  group('initialize', () {
    test(
      'rejects a blank client token without touching the platform',
      () async {
        await expectLater(
          vton.initialize(clientTokenProvider: () async => '   '),
          throwsA(
            isA<DecartVtonException>().having(
              (DecartVtonException e) => e.code,
              'code',
              VtonErrorCode.invalidApiKey,
            ),
          ),
        );
        expect(host.wasCalled('initialize'), isFalse);
      },
    );

    test('forwards trimmed configuration to the platform', () async {
      await vton.initialize(
        clientTokenProvider: () async => '  ek_short-lived-token  ',
        signalingBaseUrl: 'wss://example.test',
        httpBaseUrl: 'https://example.test',
        logLevel: VtonLogLevel.debug,
      );

      final args = host.argsOf('initialize');
      expect(args['clientToken'], 'ek_short-lived-token');
      expect(args['signalingBaseUrl'], 'wss://example.test');
      expect(args['httpBaseUrl'], 'https://example.test');
      expect(args['logLevel'], 'debug');
      expect(vton.isInitialized, isTrue);
    });

    test('is idempotent unless forced', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_token-a');
      await vton.initialize(clientTokenProvider: () async => 'ek_token-a');
      expect(
        host.calls.where((MethodCall c) => c.method == 'initialize').length,
        1,
      );

      await vton.initialize(
        clientTokenProvider: () async => 'ek_token-b',
        force: true,
      );
      expect(host.wasCalled('release'), isTrue);
      expect(
        host.calls.where((MethodCall c) => c.method == 'initialize').length,
        2,
      );
    });

    test('maps a native INVALID_API_KEY into a typed exception', () async {
      host.replies['initialize'] = PlatformException(
        code: 'INVALID_API_KEY',
        message: 'rejected by server',
      );
      await expectLater(
        vton.initialize(clientTokenProvider: () async => 'ek_bad-token'),
        throwsA(
          isA<DecartVtonException>()
              .having(
                (DecartVtonException e) => e.code,
                'code',
                VtonErrorCode.invalidApiKey,
              )
              .having(
                (DecartVtonException e) => e.nativeCode,
                'nativeCode',
                'INVALID_API_KEY',
              ),
        ),
      );
      expect(vton.isInitialized, isFalse);
    });

    test('rejects permanent credentials', () async {
      await expectLater(
        vton.initialize(clientTokenProvider: () async => 'dct_not_allowed'),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.invalidApiKey,
          ),
        ),
      );
      expect(host.wasCalled('initialize'), isFalse);
    });

    test('rejects values that are not Decart client tokens', () async {
      await expectLater(
        vton.initialize(clientTokenProvider: () async => 'arbitrary-token'),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.invalidApiKey,
          ),
        ),
      );
      expect(host.wasCalled('initialize'), isFalse);
    });

    test(
      'development initializer accepts a trimmed dct key in debug',
      () async {
        await vton.initializeForDevelopment(apiKey: '  dct_test_prototype  ');

        expect(host.argsOf('initialize')['clientToken'], 'dct_test_prototype');
        expect(vton.isInitialized, isTrue);
      },
    );

    test('development initializer rejects client tokens', () async {
      await expectLater(
        vton.initializeForDevelopment(apiKey: 'ek_wrong_mode'),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.invalidApiKey,
          ),
        ),
      );
      expect(host.wasCalled('initialize'), isFalse);
    });
  });

  // ──────────────────────────────────────────────────────────────── connect ──

  group('connect', () {
    test('requires initialize first', () async {
      await expectLater(
        vton.connect(model: VtonModel.lucyVtonLatest),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.notInitialized,
          ),
        ),
      );
    });

    test('sends the model geometry and defaults the video config', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await vton.connect(model: VtonModel.lucyVton3);

      final args = host.argsOf('connect');
      expect(args['model'], 'lucy-vton-3');
      expect(args['width'], 1088);
      expect(args['height'], 624);
      expect(args['fps'], 30);
      expect(args['supportsReferenceImage'], isTrue);
      expect(args['facing'], 'front');
      expect(args['mirror'], 'auto');
      expect(args['enhance'], isTrue);

      final video = args['video']! as Map<Object?, Object?>;
      // Pinned identically on both platforms — see VtonVideoConfig.
      expect(video['preferredCodec'], 'vp8');
      expect(video['maxBitrate'], 2500000);
    });

    test('latest VTON uses the native 1280x720 geometry', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await vton.connect(model: VtonModel.lucyVtonLatest);

      final args = host.argsOf('connect');
      expect(args['width'], 1280);
      expect(args['height'], 720);
      expect(VtonModel.lucyVton35.width, 1280);
      expect(VtonModel.lucyVton35.height, 720);
    });

    test('rejects 1080p for VTON 3.5 before touching the session', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await expectLater(
        vton.connect(
          model: VtonModel.lucyVtonLatest,
          resolution: VtonResolution.p1080,
        ),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.invalidInput,
          ),
        ),
      );
      expect(host.wasCalled('connect'), isFalse);
    });

    test('bundles the initial outfit into the handshake', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final garment = _jpegBytes(<int>[1, 2, 3, 4]);
      await vton.connect(
        model: VtonModel.lucyVtonLatest,
        initialOutfit: VtonOutfit(
          prompt: 'a red parka',
          referenceImage: garment,
          enhance: false,
        ),
      );

      final args = host.argsOf('connect');
      expect(args['prompt'], 'a red parka');
      expect(args['referenceImage'], garment);
      expect(args['enhance'], isFalse);
      expect(vton.currentOutfit?.prompt, 'a red parka');
    });

    test('rejects a reference image on a model that cannot use one', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await expectLater(
        vton.connect(
          model: VtonModel.lucyRestyle2,
          initialOutfit: VtonOutfit(
            prompt: 'watercolour',
            referenceImage: Uint8List.fromList(<int>[9]),
          ),
        ),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.invalidInput,
          ),
        ),
      );
      expect(host.wasCalled('connect'), isFalse);
    });

    test('maps a native camera-permission failure', () async {
      host.replies['connect'] = PlatformException(
        code: 'PERMISSION_DENIED',
        message: 'CAMERA not granted',
      );
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await expectLater(
        vton.connect(model: VtonModel.lucyVtonLatest),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.permissionDenied,
          ),
        ),
      );
    });
  });

  // ───────────────────────────────────────────────────────────── setOutfit ───

  group('setOutfit validation', () {
    test('rejects an update with neither prompt nor image', () async {
      await connectAndGoLive();
      await expectLater(vton.setOutfit(), throwsArgumentError);
      expect(host.wasCalled('setOutfit'), isFalse);
    });

    test('rejects a whitespace-only prompt with no image', () async {
      await connectAndGoLive();
      await expectLater(vton.setOutfit(prompt: '   '), throwsArgumentError);
    });

    test('rejects mixing outfit: with the individual arguments', () async {
      await connectAndGoLive();
      await expectLater(
        vton.setOutfit(
          outfit: const VtonOutfit(prompt: 'a'),
          prompt: 'b',
        ),
        throwsArgumentError,
      );
    });

    test(
      'rejects an image on a model without reference-image support',
      () async {
        await connectAndGoLive(model: VtonModel.lucyRestyleLatest);
        await expectLater(
          vton.setOutfit(referenceImage: Uint8List.fromList(<int>[1])),
          throwsA(
            isA<DecartVtonException>().having(
              (DecartVtonException e) => e.code,
              'code',
              VtonErrorCode.invalidInput,
            ),
          ),
        );
      },
    );

    test('rejects an update when no session is live', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await vton.connect(model: VtonModel.lucyVtonLatest);
      // No connectionState event emitted, so the state is still idle.
      await expectLater(
        vton.setOutfit(prompt: 'a red parka'),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.notConnected,
          ),
        ),
      );
    });

    test(
      'rejects unsupported image bytes before the platform channel',
      () async {
        await connectAndGoLive();
        await expectLater(
          vton.setOutfit(referenceImage: Uint8List.fromList(<int>[1, 2, 3])),
          throwsA(isA<DecartVtonException>()),
        );
        expect(host.wasCalled('setOutfit'), isFalse);
      },
    );

    test('rejects reference images larger than 5 MB', () async {
      await connectAndGoLive();
      final oversized = Uint8List(5 * 1024 * 1024 + 1)
        ..setRange(0, 3, const <int>[0xff, 0xd8, 0xff]);

      await expectLater(
        vton.setOutfit(referenceImage: oversized),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException error) => error.code,
            'code',
            VtonErrorCode.invalidInput,
          ),
        ),
      );
      expect(host.wasCalled('setOutfit'), isFalse);
    });
  });

  group('setOutfit success paths', () {
    test(
      'prompt only sends a null image (clearing any previous one)',
      () async {
        await connectAndGoLive();
        await vton.setOutfit(prompt: '  Substitute the top with a parka  ');

        final args = host.argsOf('setOutfit');
        expect(args['prompt'], 'Substitute the top with a parka');
        expect(args['referenceImage'], isNull);
        expect(args['enhance'], isTrue);
      },
    );

    test('image only sends a null prompt', () async {
      await connectAndGoLive();
      final garment = _jpegBytes(<int>[7, 7, 7]);
      await vton.setOutfit(referenceImage: garment);

      final args = host.argsOf('setOutfit');
      expect(args['prompt'], isNull);
      expect(args['referenceImage'], garment);
    });

    test('prompt and image together send both', () async {
      await connectAndGoLive();
      final garment = _jpegBytes(<int>[5]);
      await vton.setOutfit(
        prompt: 'in charcoal',
        referenceImage: garment,
        enhance: false,
      );

      final args = host.argsOf('setOutfit');
      expect(args['prompt'], 'in charcoal');
      expect(args['referenceImage'], garment);
      expect(args['enhance'], isFalse);
    });

    test('copyWith preserves the image while changing the prompt', () async {
      final garment = _jpegBytes(<int>[1, 2]);
      await connectAndGoLive(
        initialOutfit: VtonOutfit(prompt: 'a parka', referenceImage: garment),
      );

      await vton.setOutfit(
        outfit: vton.currentOutfit!.copyWith(prompt: 'in charcoal'),
      );

      final args = host.argsOf('setOutfit');
      expect(args['prompt'], 'in charcoal');
      expect(args['referenceImage'], garment);
    });

    test('a rejected update does not overwrite currentOutfit', () async {
      // Seed a known-good outfit so the assertion is about the *rollback*, not
      // about currentOutfit merely still being null.
      await connectAndGoLive(
        initialOutfit: const VtonOutfit(prompt: 'the original parka'),
      );
      expect(vton.currentOutfit?.prompt, 'the original parka');

      host.replies['setOutfit'] = PlatformException(
        code: 'PROMPT_REJECTED',
        message: 'nacked',
      );

      await expectLater(
        vton.setOutfit(prompt: 'something the server hates'),
        throwsA(
          isA<DecartVtonException>().having(
            (DecartVtonException e) => e.code,
            'code',
            VtonErrorCode.promptRejected,
          ),
        ),
      );
      expect(vton.currentOutfit?.prompt, 'the original parka');
    });
  });

  // ────────────────────────────────────────────────────────────────── events ──

  group('event decoding', () {
    test('connection states reach both the stream and the getter', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final seen = <VtonConnectionState>[];
      final sub = vton.connectionStates.listen(seen.add);

      await emit(<String, Object?>{
        'type': 'connectionState',
        'state': 'connecting',
      });
      await emit(<String, Object?>{
        'type': 'connectionState',
        'state': 'generating',
      });

      expect(seen, <VtonConnectionState>[
        VtonConnectionState.connecting,
        VtonConnectionState.generating,
      ]);
      expect(vton.connectionState, VtonConnectionState.generating);
      expect(vton.isConnected, isTrue);
      await sub.cancel();
    });

    test('sessionStarted updates sessionId', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await emit(<String, Object?>{
        'type': 'sessionStarted',
        'sessionId': 'sess-abc',
        'subscribeToken': 'tok',
      });
      expect(vton.sessionId, 'sess-abc');
    });

    test('generation ticks decode to a Duration', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final events = <VtonEvent>[];
      final sub = vton.events.listen(events.add);

      await emit(<String, Object?>{'type': 'generationTick', 'seconds': 2.5});

      expect(events.single, isA<VtonGenerationTick>());
      expect(
        (events.single as VtonGenerationTick).elapsed,
        const Duration(milliseconds: 2500),
      );
      await sub.cancel();
    });

    test('native errors land on the errors stream, typed', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final errors = <DecartVtonException>[];
      final sub = vton.errors.listen(errors.add);

      await emit(<String, Object?>{
        'type': 'error',
        'code': 'WEBRTC_ICE_ERROR',
        'message': 'ice failed',
      });

      expect(errors.single.code, VtonErrorCode.webrtc);
      expect(errors.single.nativeCode, 'WEBRTC_ICE_ERROR');
      await sub.cancel();
    });

    test('connection-quality samples decode', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final events = <VtonEvent>[];
      final sub = vton.events.listen(events.add);

      await emit(<String, Object?>{
        'type': 'connectionQuality',
        'quality': 'poor',
        'roundTripMs': 220,
        'packetLoss': 0.04,
        'jitterMs': 18,
      });

      final event = events.single as VtonConnectionQualityChanged;
      expect(event.quality, VtonConnectionQuality.poor);
      expect(event.roundTripMs, 220);
      expect(event.packetLoss, closeTo(0.04, 1e-9));
      await sub.cancel();
    });

    test('unknown event types are ignored rather than thrown on', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final events = <VtonEvent>[];
      final sub = vton.events.listen(events.add);

      await emit(<String, Object?>{'type': 'somethingNewInV2', 'x': 1});

      expect(events, isEmpty);
      await sub.cancel();
    });
  });

  // ─────────────────────────────────────────────────────── error-code table ──

  group('VtonErrorCode.fromNative', () {
    test('covers both platforms\' vocabularies', () {
      // Android spellings.
      expect(
        VtonErrorCode.fromNative('WEBRTC_ICE_ERROR'),
        VtonErrorCode.webrtc,
      );
      expect(
        VtonErrorCode.fromNative('WEBRTC_WEBSOCKET_ERROR'),
        VtonErrorCode.websocket,
      );
      expect(
        VtonErrorCode.fromNative('WEBRTC_TIMEOUT_ERROR'),
        VtonErrorCode.connectionTimeout,
      );
      // iOS spellings.
      expect(VtonErrorCode.fromNative('WEB_RTC_ERROR'), VtonErrorCode.webrtc);
      expect(
        VtonErrorCode.fromNative('WEBSOCKET_ERROR'),
        VtonErrorCode.websocket,
      );
      expect(
        VtonErrorCode.fromNative('CONNECTION_TIMEOUT'),
        VtonErrorCode.connectionTimeout,
      );
      expect(
        VtonErrorCode.fromNative('MODEL_NOT_FOUND'),
        VtonErrorCode.modelNotFound,
      );
      // Unknown.
      expect(VtonErrorCode.fromNative('SOMETHING_ELSE'), VtonErrorCode.unknown);
      expect(VtonErrorCode.fromNative(null), VtonErrorCode.unknown);
    });
  });

  // ──────────────────────────────────────────────────────────────── teardown ─

  group('lifecycle', () {
    test('disconnect is a no-op before initialize', () async {
      await vton.disconnect();
      expect(host.wasCalled('disconnect'), isFalse);
    });

    test('dispose releases the platform and closes the streams', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      await vton.dispose();

      expect(host.wasCalled('release'), isTrue);
      expect(
        () => vton.connect(model: VtonModel.lucyVtonLatest),
        throwsA(isA<StateError>()),
      );
    });

    test('checkConnectivity decodes the report', () async {
      host.replies['checkConnectivity'] = <Object?, Object?>{
        'quality': 'good',
        'transport': 'udp',
        'roundTripMs': 42,
      };
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final report = await vton.checkConnectivity();

      expect(report.quality, VtonConnectionQuality.good);
      expect(report.transport, 'udp');
      expect(report.roundTripMs, 42);
      expect(report.isUsable, isTrue);
    });

    test('serializes connect and disconnect operations', () async {
      await vton.initialize(clientTokenProvider: () async => 'ek_test-token');
      final pendingConnect = Completer<Object?>();
      host.replies['connect'] = pendingConnect.future;

      final connect = vton.connect(model: VtonModel.lucyVtonLatest);
      final disconnect = vton.disconnect();
      await pumpEventQueue();
      expect(host.wasCalled('connect'), isTrue);
      expect(host.wasCalled('disconnect'), isFalse);

      pendingConnect.complete(<Object?, Object?>{'sessionId': 'serialized'});
      await connect;
      await disconnect;
      expect(host.wasCalled('disconnect'), isTrue);
    });

    test(
      'resume does not trust a stale connected event after disconnect',
      () async {
        await connectAndGoLive();
        await vton.disconnect();

        // The mocked native side deliberately emits no disconnected event, so
        // the synchronous state is still generating here.
        expect(vton.connectionState, VtonConnectionState.generating);
        await vton.resumeLastSession();

        expect(
          host.calls
              .where((MethodCall call) => call.method == 'connect')
              .length,
          2,
        );
      },
    );
  });

  // ──────────────────────────────────────────────────────────── value class ──

  group('VtonOutfit', () {
    test('copyWith can clear fields explicitly', () {
      final outfit = VtonOutfit(
        prompt: 'a parka',
        referenceImage: Uint8List.fromList(<int>[1]),
      );
      final cleared = outfit.copyWith(clearReferenceImage: true);
      expect(cleared.hasReferenceImage, isFalse);
      expect(cleared.prompt, 'a parka');
    });

    test('equality compares image bytes, not identity', () {
      final a = VtonOutfit(referenceImage: Uint8List.fromList(<int>[1, 2, 3]));
      final b = VtonOutfit(referenceImage: Uint8List.fromList(<int>[1, 2, 3]));
      final c = VtonOutfit(referenceImage: Uint8List.fromList(<int>[1, 2, 4]));
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('blank prompt does not count as a prompt', () {
      const outfit = VtonOutfit(prompt: '  ');
      expect(outfit.hasPrompt, isFalse);
    });
  });

  group('VtonModel', () {
    test('every model round-trips through its wire id', () {
      for (final model in VtonModel.values) {
        expect(VtonModel.fromId(model.id), model);
      }
      expect(VtonModel.fromId('not-a-model'), isNull);
    });

    test('only the restyle models refuse reference images', () {
      expect(VtonModel.lucyRestyle2.supportsReferenceImage, isFalse);
      expect(VtonModel.lucyRestyleLatest.supportsReferenceImage, isFalse);
      expect(VtonModel.lucyVtonLatest.supportsReferenceImage, isTrue);
    });
  });
}
