#!/usr/bin/env python3
"""Cross-language consistency check for the platform-channel wire contract.

The Dart, Kotlin and Swift layers each hold half a conversation. Nothing in the
type system connects them: a renamed argument key or a new native error code
compiles perfectly on both sides and fails silently at runtime, usually as a
null where a value was expected. This script is the check that catches that.

It is deliberately dumb — regex over source, no parsing — because the alternative
is three toolchains. It checks four things:

  1. Every method Dart invokes is handled by both native sides, and vice versa.
  2. Every argument key Dart sends is read by both native sides.
  3. Every event `type` either side emits is decoded by Dart, and vice versa.
  4. Every error code either native side can emit is mapped by
     VtonErrorCode.fromNative (an unmapped code silently degrades to `unknown`).
  5. Channel names and the platform-view type string are byte-identical.
  6. Platform-view creation params agree.
  7. Every symbol the barrel exports actually exists in the file it names.
  8. The YAML and XML that ship with the package parse.

Run:  python3 tool/check_contract.py
Exit: 0 clean, 1 on any mismatch.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

DART_PLATFORM = ROOT / "lib/src/decart_vton_platform.dart"
DART_CONTROLLER = ROOT / "lib/src/decart_vton.dart"
DART_ERRORS = ROOT / "lib/src/models/vton_error.dart"

KOTLIN_PLUGIN = ROOT / "android/src/main/kotlin/ai/decart/vton/flutter/DecartVtonPlugin.kt"
KOTLIN_CODEC = ROOT / "android/src/main/kotlin/ai/decart/vton/flutter/ChannelCodec.kt"
KOTLIN_SESSION = ROOT / "android/src/main/kotlin/ai/decart/vton/flutter/VtonSessionController.kt"
KOTLIN_ERRORS = ROOT / "android/src/main/kotlin/ai/decart/vton/flutter/Errors.kt"

SWIFT_PLUGIN = ROOT / "ios/decart_vton_flutter/Sources/decart_vton_flutter/DecartVtonPlugin.swift"
SWIFT_CODEC = ROOT / "ios/decart_vton_flutter/Sources/decart_vton_flutter/ChannelCodec.swift"
SWIFT_SESSION = ROOT / "ios/decart_vton_flutter/Sources/decart_vton_flutter/VtonSessionController.swift"
SWIFT_ERRORS = ROOT / "ios/decart_vton_flutter/Sources/decart_vton_flutter/Errors.swift"

failures: list[str] = []
notes: list[str] = []


def read(path: Path) -> str:
    if not path.exists():
        failures.append(f"missing source file: {path.relative_to(ROOT)}")
        return ""
    return path.read_text()


def compare(label: str, dart: set[str], kotlin: set[str], swift: set[str]) -> None:
    """Reports any name known to one layer but not another."""
    for name in sorted(dart - kotlin):
        failures.append(f"{label}: Dart uses '{name}' but Kotlin does not handle it")
    for name in sorted(dart - swift):
        failures.append(f"{label}: Dart uses '{name}' but Swift does not handle it")
    for name in sorted(kotlin - dart):
        failures.append(f"{label}: Kotlin handles '{name}' but Dart never sends/reads it")
    for name in sorted(swift - dart):
        failures.append(f"{label}: Swift handles '{name}' but Dart never sends/reads it")
    for name in sorted(kotlin - swift):
        failures.append(f"{label}: '{name}' is handled on Android but not on iOS")
    for name in sorted(swift - kotlin):
        failures.append(f"{label}: '{name}' is handled on iOS but not on Android")


# ── 1. method names ──────────────────────────────────────────────────────────

dart_platform_src = read(DART_PLATFORM)
# The generic argument can itself contain '>' (`_invoke<Map<Object?, Object?>>`),
# so match on the quoted method name that follows the opening paren instead of
# trying to balance the angle brackets.
dart_methods = set(re.findall(r"_invoke(?:Void)?\b[^(\n]*\(\s*'([a-zA-Z]+)'", dart_platform_src))

kotlin_methods = set(
    re.findall(r'^\s*"([a-zA-Z]+)"\s*->', read(KOTLIN_PLUGIN), flags=re.M)
)
swift_methods = set(
    re.findall(r'^\s*case "([a-zA-Z]+)":', read(SWIFT_PLUGIN), flags=re.M)
)

compare("method", dart_methods, kotlin_methods, swift_methods)

# ── 2. argument keys ─────────────────────────────────────────────────────────
#
# Only the keys Dart actually sends are authoritative. A key a native side reads
# but Dart never sends is dead code; a key Dart sends that nobody reads is a
# silently ignored setting. Both are worth knowing about.

dart_all = dart_platform_src + read(DART_CONTROLLER) + read(ROOT / "lib/src/models/vton_model.dart")
# Keys inside the argument maps Dart builds for the channel.
dart_keys = set(re.findall(r"^\s*'([a-zA-Z]+)':\s", dart_all, flags=re.M))
# Exclude keys that belong to *reply* maps rather than request maps.
REPLY_KEYS = {"sessionId", "quality", "transport", "roundTripMs"}
dart_keys -= REPLY_KEYS

kotlin_src = read(KOTLIN_SESSION) + read(KOTLIN_CODEC)
kotlin_keys = set(
    re.findall(r'\.(?:string|stringOrNull|int|long|bool|bytes|map)\(\s*"([a-zA-Z]+)"', kotlin_src)
)
kotlin_keys |= set(re.findall(r'args\[\s*"([a-zA-Z]+)"\s*\]', kotlin_src))

swift_src = read(SWIFT_SESSION) + read(SWIFT_CODEC)
# Covers all three call shapes used in the Swift sources:
#   ChannelCodec.string(args, "key")      — from VtonSessionController
#   string(args, "key")                   — inside ChannelCodec itself
#   int($0, "key", default)               — inside `video.map { … }` closures
swift_keys = set(
    re.findall(
        r'(?:ChannelCodec\.)?(?:string|int|bool|bytes|map)\(\s*(?:args|\$0)\s*,\s*"([a-zA-Z]+)"',
        swift_src,
    )
)

# Keys a platform deliberately ignores, with the reason. Encoding them here
# rather than in prose means a divergence cannot be introduced silently: adding
# one requires editing this list, and removing the cause requires removing the
# entry or the check starts complaining about a dead exemption.
IGNORED_BY_SWIFT = {
    "logLevel": "the iOS SDK has no runtime log level (env var only)",
    "signalingBaseUrl": "DecartConfiguration derives wss:// from the single base URL",
}
IGNORED_BY_KOTLIN: dict[str, str] = {}

for key in sorted(dart_keys - kotlin_keys):
    if key in IGNORED_BY_KOTLIN:
        notes.append(f"argument key: Kotlin ignores '{key}' — {IGNORED_BY_KOTLIN[key]}")
        continue
    failures.append(f"argument key: Dart sends '{key}' but Kotlin never reads it")
for key in sorted(dart_keys - swift_keys):
    if key in IGNORED_BY_SWIFT:
        notes.append(f"argument key: Swift ignores '{key}' — {IGNORED_BY_SWIFT[key]}")
        continue
    failures.append(f"argument key: Dart sends '{key}' but Swift never reads it")
for key in sorted(k for k in IGNORED_BY_SWIFT if k in swift_keys):
    failures.append(f"argument key: '{key}' is listed as ignored by Swift but Swift does read it — stale exemption")
for key in sorted(k for k in IGNORED_BY_KOTLIN if k in kotlin_keys):
    failures.append(f"argument key: '{key}' is listed as ignored by Kotlin but Kotlin does read it — stale exemption")
for key in sorted((kotlin_keys | swift_keys) - dart_keys):
    notes.append(f"argument key: native reads '{key}' which Dart never sends (dead read?)")

# ── 3. event types ───────────────────────────────────────────────────────────

dart_events = set(re.findall(r"^\s*case '([a-zA-Z]+)':", dart_platform_src, flags=re.M))
kotlin_events = set(re.findall(r'"type"\s+to\s+"([a-zA-Z]+)"', read(KOTLIN_CODEC)))
swift_events = set(re.findall(r'"type":\s*"([a-zA-Z]+)"', read(SWIFT_CODEC)))

compare("event type", dart_events, kotlin_events, swift_events)

# ── 4. error codes ───────────────────────────────────────────────────────────

dart_mapped = set(re.findall(r"case '([A-Z_]+)':", read(DART_ERRORS)))

kotlin_error_src = read(KOTLIN_ERRORS)
kotlin_codes = set(re.findall(r'const val [A-Z_]+ = "([A-Z_]+)"', kotlin_error_src))

swift_error_src = read(SWIFT_ERRORS)
swift_codes = set(re.findall(r'static let [a-zA-Z]+ = "([A-Z_]+)"', swift_error_src))

# The native SDKs' own codes also reach Dart untouched (Android passes
# DecartError.code straight through; iOS passes DecartError.errorCode). Those
# must be mapped too or they degrade to VtonErrorCode.unknown.
SDK_CODES_ANDROID = {
    "INVALID_API_KEY", "INVALID_INPUT", "WEBRTC_WEBSOCKET_ERROR", "WEBRTC_ICE_ERROR",
    "WEBRTC_TIMEOUT_ERROR", "WEBRTC_SERVER_ERROR", "WEBRTC_SIGNALING_ERROR",
}
SDK_CODES_IOS = {
    "INVALID_API_KEY", "INVALID_BASE_URL", "PROCESSING_ERROR", "INVALID_INPUT",
    "INVALID_OPTIONS", "MODEL_NOT_FOUND", "CONNECTION_TIMEOUT", "WEBSOCKET_ERROR",
    "NETWORK_ERROR", "SERVER_ERROR", "QUEUE_ERROR",
}
# WEB_RTC_ERROR is normalised to WEBRTC_ERROR by Errors.swift before it leaves
# the plugin, so it is intentionally absent from the set above.

reachable = kotlin_codes | swift_codes | SDK_CODES_ANDROID | SDK_CODES_IOS
for code in sorted(reachable - dart_mapped):
    failures.append(
        f"error code: '{code}' can reach Dart but VtonErrorCode.fromNative "
        f"does not map it (would silently become 'unknown')"
    )
for code in sorted(dart_mapped - reachable):
    notes.append(f"error code: Dart maps '{code}' which nothing appears to emit")

# The two native vocabularies should be identical, so Dart needs one table.
for code in sorted(kotlin_codes - swift_codes):
    failures.append(f"error code: '{code}' exists in Kotlin ErrorCodes but not Swift's")
for code in sorted(swift_codes - kotlin_codes):
    failures.append(f"error code: '{code}' exists in Swift ErrorCodes but not Kotlin's")

# ── 5. channel and view-type names ───────────────────────────────────────────

def one(pattern: str, text: str, label: str) -> str | None:
    found = set(re.findall(pattern, text))
    if len(found) != 1:
        failures.append(f"{label}: expected exactly one value, found {sorted(found)}")
        return None
    return found.pop()

names = {
    "method channel": (
        one(r"methodChannelDefaultName = '([^']+)'", dart_platform_src, "Dart method channel"),
        one(r'METHOD_CHANNEL = "([^"]+)"', read(KOTLIN_PLUGIN), "Kotlin method channel"),
        one(r'methodChannelName = "([^"]+)"', read(SWIFT_PLUGIN), "Swift method channel"),
    ),
    "event channel": (
        one(r"eventChannelDefaultName = '([^']+)'", dart_platform_src, "Dart event channel"),
        one(r'EVENT_CHANNEL = "([^"]+)"', read(KOTLIN_PLUGIN), "Kotlin event channel"),
        one(r'eventChannelName = "([^"]+)"', read(SWIFT_PLUGIN), "Swift event channel"),
    ),
    "view type": (
        one(r"videoViewType = '([^']+)'", dart_platform_src, "Dart view type"),
        one(r'VIEW_TYPE = "([^"]+)"', read(KOTLIN_PLUGIN), "Kotlin view type"),
        one(r'viewTypeName = "([^"]+)"', read(SWIFT_PLUGIN), "Swift view type"),
    ),
}
for label, (d, k, s) in names.items():
    if None in (d, k, s):
        continue
    if not (d == k == s):
        failures.append(f"{label}: Dart='{d}' Kotlin='{k}' Swift='{s}' — must be identical")

# ── 6. platform-view creation params ─────────────────────────────────────────

dart_view_params = set(
    re.findall(r"^\s*'(source|fit|mirror)':", read(ROOT / "lib/src/widgets/vton_video_view.dart"), flags=re.M)
)
kotlin_view_params = set(
    re.findall(r'params\[\s*"([a-z]+)"\s*\]', read(ROOT / "android/src/main/kotlin/ai/decart/vton/flutter/VtonVideoPlatformView.kt"))
)
swift_view_params = set(
    re.findall(r'params\[\s*"([a-z]+)"\s*\]', read(ROOT / "ios/decart_vton_flutter/Sources/decart_vton_flutter/VtonVideoPlatformView.swift"))
)
compare("view creation param", dart_view_params, kotlin_view_params, swift_view_params)

# ── 7. barrel exports resolve ────────────────────────────────────────────────
#
# `export 'src/x.dart' show A, B;` with a typo in a name is a compile error, but
# only once something imports the package. Catching it here is cheaper.

barrel = read(ROOT / "lib/decart_vton_flutter.dart")
for path_part, names_part in re.findall(
    r"export\s+'([^']+)'\s*\n?\s*show\s+([^;]+);", barrel, flags=re.S
):
    target = ROOT / "lib" / path_part
    if not target.exists():
        failures.append(f"barrel export: '{path_part}' does not exist")
        continue
    source = target.read_text()
    for name in (n.strip() for n in names_part.replace("\n", " ").split(",")):
        if not name:
            continue
        declared = re.search(
            rf"\b(?:class|enum|mixin|extension|typedef|sealed class|final class|abstract class)\s+{re.escape(name)}\b",
            source,
        )
        if not declared:
            failures.append(
                f"barrel export: '{name}' is exported from '{path_part}' "
                f"but no declaration of that name is in the file"
            )

# ── 8. shipped YAML / XML parses ─────────────────────────────────────────────

try:
    import yaml  # type: ignore

    for rel in ("pubspec.yaml", "analysis_options.yaml",
                "example/pubspec.yaml", "example/analysis_options.yaml"):
        path = ROOT / rel
        if not path.exists():
            failures.append(f"missing: {rel}")
            continue
        try:
            yaml.safe_load(path.read_text())
        except Exception as exc:  # noqa: BLE001
            failures.append(f"YAML parse error in {rel}: {exc}")
except ImportError:
    notes.append("pyyaml not installed — YAML files not parse-checked")

import xml.etree.ElementTree as ET

for rel in ("android/src/main/AndroidManifest.xml",):
    path = ROOT / rel
    if not path.exists():
        failures.append(f"missing: {rel}")
        continue
    try:
        ET.parse(path)
    except ET.ParseError as exc:
        failures.append(f"XML parse error in {rel}: {exc}")

# ── report ───────────────────────────────────────────────────────────────────

print(f"methods         : {sorted(dart_methods)}")
print(f"argument keys   : {sorted(dart_keys)}")
print(f"event types     : {sorted(dart_events)}")
print(f"view params     : {sorted(dart_view_params)}")
print(f"native codes    : {len(kotlin_codes)} Kotlin / {len(swift_codes)} Swift, "
      f"{len(dart_mapped)} mapped in Dart")
print()

for note in notes:
    print(f"  note: {note}")
if notes:
    print()

if failures:
    print(f"FAILED — {len(failures)} contract mismatch(es):")
    for failure in failures:
        print(f"  ✗ {failure}")
    sys.exit(1)

print("OK — Dart, Kotlin and Swift agree on the full wire contract.")
