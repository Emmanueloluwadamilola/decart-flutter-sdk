#!/usr/bin/env bash
#
# Generates the example app's native platform folders and applies the
# project-specific settings this plugin needs.
#
# WHY THIS EXISTS
# ---------------
# `example/android/` and `example/ios/` are Flutter-generated scaffolding —
# Gradle wrappers, an Xcode `.pbxproj`, launch storyboards. Those are machine
# artefacts, not source, and hand-writing an Xcode project file is not a
# reasonable thing to do. So the repository ships the parts that *are* source
# (Dart, the plugin's own native code, pubspec, env.example) and this script
# generates the rest, then patches it.
#
# Safe to re-run: it regenerates into a temp directory and only copies folders
# that are missing, unless you pass --force.
#
# Usage:
#   tool/bootstrap_example.sh [--force]
#
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/example"

ORG="ai.decart"
PROJECT_NAME="decart_vton_example"

MIN_SDK=24
IOS_TARGET="17.0"

# Note: compileSdk is deliberately NOT patched. Flutter's own template uses
# `flutter.compileSdkVersion`, which tracks the SDK you have installed (36 on
# current stable). Pinning it lower here would silently downgrade the whole app
# and break other plugins that need a newer one.

log()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH."

log "Flutter: $(flutter --version | head -1)"

# ── 1. Swift Package Manager ────────────────────────────────────────────────
# Required: the Decart iOS SDK is SPM-only and cannot be resolved by CocoaPods.
log "Enabling Flutter's Swift Package Manager support (required for iOS)…"
flutter config --enable-swift-package-manager </dev/null

# ── 2. Generate the platform scaffolding ────────────────────────────────────
NEED_ANDROID=1
NEED_IOS=1
[[ -d "$EXAMPLE/android" && $FORCE -eq 0 ]] && NEED_ANDROID=0
[[ -d "$EXAMPLE/ios" && $FORCE -eq 0 ]] && NEED_IOS=0

if [[ $NEED_ANDROID -eq 1 || $NEED_IOS -eq 1 ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  log "Generating platform scaffolding via flutter create…"
  # Output is NOT suppressed: `flutter create` can spend minutes fetching
  # engine artifacts on a cold cache, and hiding that makes a slow run
  # indistinguishable from a hang. `-i swift` is gone — deprecated and inert
  # since Flutter 3.4x, Swift is always used for iOS.
  flutter create \
    --org "$ORG" \
    --project-name "$PROJECT_NAME" \
    --template=app \
    --platforms=android,ios \
    -a kotlin \
    "$TMP/scaffold" </dev/null

  if [[ $NEED_ANDROID -eq 1 ]]; then
    rm -rf "$EXAMPLE/android"
    cp -R "$TMP/scaffold/android" "$EXAMPLE/android"
    log "Created example/android"
  fi
  if [[ $NEED_IOS -eq 1 ]]; then
    rm -rf "$EXAMPLE/ios"
    cp -R "$TMP/scaffold/ios" "$EXAMPLE/ios"
    log "Created example/ios"
  fi
  [[ -f "$EXAMPLE/.metadata" ]] || cp "$TMP/scaffold/.metadata" "$EXAMPLE/.metadata" 2>/dev/null || true
else
  log "example/android and example/ios already exist (pass --force to regenerate)."
fi

# ── 3. Patch the generated projects ─────────────────────────────────────────
log "Applying plugin requirements to the generated projects…"

MIN_SDK="$MIN_SDK" IOS_TARGET="$IOS_TARGET" \
EXAMPLE="$EXAMPLE" python3 - <<'PYTHON'
import os
import re
import sys
from pathlib import Path

example = Path(os.environ["EXAMPLE"])
min_sdk = os.environ["MIN_SDK"]
ios_target = os.environ["IOS_TARGET"]

changed, manual = [], []


def edit(path: Path, fn):
    if not path.exists():
        manual.append(f"{path} not found — skipped.")
        return
    before = path.read_text()
    after = fn(before)
    if after != before:
        path.write_text(after)
        changed.append(str(path.relative_to(example.parent)))


# ── Android: raise minSdk to 24 without ever lowering anything ──────────────
#
# `maxOf` / `Math.max` rather than a hard 24: Flutter's template already
# defaults minSdk to `flutter.minSdkVersion` (24 on current stable), and a
# future template may raise it. Clamping upward is safe in both directions.
#
# compileSdk and the Java version are deliberately left alone — patching those
# can only downgrade the app relative to what its Flutter version chose.
def patch_app_gradle(text: str) -> str:
    if f"maxOf({min_sdk}" in text or f"Math.max({min_sdk}" in text:
        return text  # already patched
    # Kotlin DSL (current template).
    text = re.sub(
        r"minSdk\s*=\s*flutter\.minSdkVersion",
        f"minSdk = maxOf({min_sdk}, flutter.minSdkVersion)",
        text,
    )
    # Groovy DSL (older templates).
    text = re.sub(
        r"minSdkVersion\s+flutter\.minSdkVersion",
        f"minSdkVersion Math.max({min_sdk}, flutter.minSdkVersion)",
        text,
    )
    # A literal that is genuinely below our floor.
    def raise_literal(match: "re.Match[str]") -> str:
        value = int(match.group(2))
        return match.group(0) if value >= int(min_sdk) else f"{match.group(1)}{min_sdk}"

    text = re.sub(r"(minSdk\s*=\s*)(\d+)", raise_literal, text)
    text = re.sub(r"(minSdkVersion\s+)(\d+)", raise_literal, text)
    return text


for candidate in ("android/app/build.gradle.kts", "android/app/build.gradle"):
    p = example / candidate
    if p.exists():
        edit(p, patch_app_gradle)
        break
else:
    manual.append("Could not find example/android/app/build.gradle[.kts].")


# ── Android: JitPack in the APP's repositories ──────────────────────────────
#
# This is the one that actually matters. Gradle resolves a configuration with
# the repositories of the project that owns it, so `:app:debugRuntimeClasspath`
# uses the app's repositories — not the plugin's — when pulling the plugin's
# transitive dependencies. Without JitPack here the build fails with
# "Could not find com.github.DecartAI:decart-android".
#
# The Flutter template's root build file already has an `allprojects` block, so
# JitPack goes in alongside google() and mavenCentral().
def patch_root_gradle(text: str) -> str:
    if "jitpack.io" in text:
        return text
    patched, count = re.subn(
        r"(allprojects\s*\{\s*repositories\s*\{)",
        r"\1\n        // Required by decart_vton_flutter: the Decart Android SDK\n"
        r"        // is published on JitPack, not Maven Central.\n"
        r'        maven { url = uri("https://jitpack.io") }',
        text,
        count=1,
    )
    if count == 0:
        manual.append(
            "Could not find an `allprojects { repositories {` block in the root "
            "Android build file. Add `maven { url = uri(\"https://jitpack.io\") }` "
            "to the app's repositories by hand, or the Android build will fail to "
            "resolve com.github.DecartAI:decart-android."
        )
    return patched


for candidate in ("android/build.gradle.kts", "android/build.gradle"):
    p = example / candidate
    if p.exists():
        edit(p, patch_root_gradle)
        break
else:
    manual.append("Could not find example/android/build.gradle[.kts].")


# ── Android: JitPack again, for projects that pin repositories centrally ────
def patch_settings(text: str) -> str:
    if "jitpack.io" in text:
        return text
    if "dependencyResolutionManagement" not in text:
        # Stock Flutter template: the plugin's own build.gradle declares
        # JitPack and that is sufficient. Nothing to do.
        return text
    return re.sub(
        r"(dependencyResolutionManagement\s*\{[^}]*repositories\s*\{)",
        r"\1\n        maven { url = uri(\"https://jitpack.io\") }",
        text,
        count=1,
    )


for candidate in ("android/settings.gradle.kts", "android/settings.gradle"):
    p = example / candidate
    if p.exists():
        edit(p, patch_settings)
        break


# ── iOS: deployment target ──────────────────────────────────────────────────
def patch_pbxproj(text: str) -> str:
    return re.sub(
        r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;",
        f"IPHONEOS_DEPLOYMENT_TARGET = {ios_target};",
        text,
    )


edit(example / "ios/Runner.xcodeproj/project.pbxproj", patch_pbxproj)


def patch_podfile(text: str) -> str:
    if re.search(r"^\s*platform :ios", text, re.M):
        return re.sub(r"^\s*#?\s*platform :ios.*$", f"platform :ios, '{ios_target}'",
                      text, count=1, flags=re.M)
    return f"platform :ios, '{ios_target}'\n" + text


edit(example / "ios/Podfile", patch_podfile)


# ── iOS: Info.plist usage descriptions ──────────────────────────────────────
USAGE_KEYS = {
    "NSCameraUsageDescription":
        "This app uses the camera to show you wearing different outfits in real time.",
    "NSPhotoLibraryUsageDescription":
        "Choose a photo of a garment to try on.",
}


def patch_plist(text: str) -> str:
    for key, description in USAGE_KEYS.items():
        if f"<key>{key}</key>" in text:
            continue
        text = text.replace(
            "</dict>\n</plist>",
            f"\t<key>{key}</key>\n\t<string>{description}</string>\n</dict>\n</plist>",
            1,
        )
    return text


edit(example / "ios/Runner/Info.plist", patch_plist)

# ── Report ──────────────────────────────────────────────────────────────────
for path in changed:
    print(f"    patched {path}")
for note in manual:
    print(f"    NOTE: {note}", file=sys.stderr)
PYTHON

# ── 4. Dependencies ─────────────────────────────────────────────────────────
log "Resolving packages…"
( cd "$ROOT" && flutter pub get </dev/null )
( cd "$EXAMPLE" && flutter pub get </dev/null )

log "Done. Next:"
echo "    tool/verify.sh                 # analyze + test + build both platforms"
echo "    cp -n example/env.example example/.env"
echo "    tool/run_example.sh            # loads example/.env automatically"
