// Uint8List arrives via foundation.dart's re-export of dart:typed_data.
import 'package:flutter/foundation.dart';

/// A complete description of the try-on state to apply to the live stream.
///
/// ## This is whole-state, not a patch
///
/// The Decart realtime protocol's outfit update **replaces the entire state**.
/// Fields you leave out are *cleared* on the server, not preserved. That is a
/// property of the API, not of this plugin, and it is the single most common
/// way people get surprising results.
///
/// This class exists so the correct spelling of "change one thing" is short:
///
/// ```dart
/// // Keep the garment image, change only the prompt:
/// await vton.setOutfit(
///   outfit: vton.currentOutfit!.copyWith(prompt: 'in charcoal grey'),
/// );
///
/// // NOT this — this clears the reference image:
/// await vton.setOutfit(prompt: 'in charcoal grey');
/// ```
@immutable
class VtonOutfit {
  /// Creates an outfit from a [prompt], a [referenceImage], a
  /// [referenceImagePath], or a prompt plus one image source.
  ///
  /// [referenceImage] and [referenceImagePath] are mutually exclusive. Use the
  /// path form for an image already stored on the device so its bytes do not
  /// have to be loaded into Dart and copied through the platform channel.
  const VtonOutfit({
    this.prompt,
    this.referenceImage,
    this.referenceImagePath,
    this.enhance = true,
  }) : assert(
         referenceImage == null || referenceImagePath == null,
         'Pass referenceImage or referenceImagePath, not both.',
       ),
       assert(
         prompt != null || referenceImage != null || referenceImagePath != null,
         'A VtonOutfit needs at least a prompt or a reference image. '
         'An outfit with neither would clear the entire try-on state.',
       );

  /// Text description of the garment change.
  ///
  /// The model responds best to the documented "substitute" and "add" patterns:
  ///
  /// - `Substitute the current top with a navy blue hoodie with a white cross
  ///   logo on the chest`
  /// - `Add a wide-brimmed straw hat to the person's head`
  ///
  /// Vague fragments (`Red hoodie`) and multiple unrelated changes in one
  /// prompt both degrade output quality.
  final String? prompt;

  /// Encoded garment reference image bytes: JPEG, PNG or WebP.
  ///
  /// Guidance from the reference-images doc: use a clean product shot of the
  /// garment alone on a plain background, at least 512x512, ideally under 5 MB.
  /// If your source shows a person wearing the item, extract the garment first.
  ///
  /// Only meaningful for models where [VtonModel.supportsReferenceImage] is
  /// `true`.
  final Uint8List? referenceImage;

  /// Absolute path to an encoded JPEG, PNG or WebP garment image.
  ///
  /// Prefer this when an image picker or camera already produced a local file.
  /// Native code reads the file directly, avoiding a large Dart heap allocation
  /// and platform-channel copy. Keep the file available while this outfit may
  /// be restored by `resumeLastSession()`.
  final String? referenceImagePath;

  /// Whether the server should auto-expand the prompt before applying it.
  ///
  /// Defaults to `true`, matching the documented model default. Set it to
  /// `false` when you have written a detailed prompt yourself and do not want
  /// it rewritten.
  final bool enhance;

  /// Whether this outfit carries a usable text prompt.
  bool get hasPrompt => prompt != null && prompt!.trim().isNotEmpty;

  /// Whether this outfit carries in-memory reference-image bytes.
  bool get hasReferenceImageBytes =>
      referenceImage != null && referenceImage!.isNotEmpty;

  /// Whether this outfit carries a usable native file path.
  bool get hasReferenceImagePath =>
      referenceImagePath != null && referenceImagePath!.trim().isNotEmpty;

  /// Whether this outfit carries either supported reference-image source.
  bool get hasReferenceImage => hasReferenceImageBytes || hasReferenceImagePath;

  /// Returns a copy with the given fields replaced.
  ///
  /// Because `null` is a meaningful value here, use [clearPrompt] and
  /// [clearReferenceImage] to *remove* a field rather than passing `null`.
  VtonOutfit copyWith({
    String? prompt,
    Uint8List? referenceImage,
    String? referenceImagePath,
    bool? enhance,
    bool clearPrompt = false,
    bool clearReferenceImage = false,
  }) {
    assert(
      !(clearPrompt && prompt != null),
      'Pass either prompt: or clearPrompt: true, not both.',
    );
    assert(
      referenceImage == null || referenceImagePath == null,
      'Pass referenceImage or referenceImagePath, not both.',
    );
    assert(
      !(clearReferenceImage &&
          (referenceImage != null || referenceImagePath != null)),
      'Pass an image source or clearReferenceImage: true, not both.',
    );
    final replacingWithBytes = referenceImage != null;
    final replacingWithPath = referenceImagePath != null;
    return VtonOutfit(
      prompt: clearPrompt ? null : (prompt ?? this.prompt),
      referenceImage: clearReferenceImage
          ? null
          : replacingWithPath
          ? null
          : (referenceImage ?? this.referenceImage),
      referenceImagePath: clearReferenceImage
          ? null
          : replacingWithBytes
          ? null
          : (referenceImagePath ?? this.referenceImagePath),
      enhance: enhance ?? this.enhance,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VtonOutfit &&
        other.prompt == prompt &&
        other.enhance == enhance &&
        other.referenceImagePath == referenceImagePath &&
        _bytesEqual(other.referenceImage, referenceImage);
  }

  @override
  int get hashCode =>
      Object.hash(prompt, enhance, referenceImagePath, referenceImage?.length);

  @override
  String toString() =>
      'VtonOutfit(prompt: ${prompt ?? '<none>'}, '
      'referenceImage: ${hasReferenceImageBytes
          ? '${referenceImage!.length} bytes'
          : hasReferenceImagePath
          ? referenceImagePath
          : '<none>'}, '
      'enhance: $enhance)';

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
