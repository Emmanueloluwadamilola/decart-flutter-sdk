#!/usr/bin/env bash
#
# The Phase 4 verification loop, as one command.
#
#   tool/verify.sh              # contract + analyze + format + tests + Android build
#   tool/verify.sh --ios        # also build iOS (macOS + Xcode 16 required)
#   tool/verify.sh --fast       # contract + analyze + tests only, no native builds
#   tool/verify.sh --contract   # only the wire-contract check; needs no Flutter
#
# Every step prints its own heading and the script stops at the first failure,
# so the output tells you exactly which gate you are on.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/example"

WITH_IOS=0
FAST=0
for arg in "$@"; do
  case "$arg" in
    --ios) WITH_IOS=1 ;;
    --fast) FAST=1 ;;
    --contract) ;;   # handled above
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --contract runs only the toolchain-free check, which is useful in CI and on a
# machine without Flutter installed.
if [[ "${1:-}" == "--contract" ]]; then
  python3 "$ROOT/tool/check_contract.py"
  exit $?
fi

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH."

if [[ ! -d "$EXAMPLE/android" || ! -d "$EXAMPLE/ios" ]]; then
  die "example/android or example/ios is missing. Run tool/bootstrap_example.sh first."
fi

step "wire-contract check (no toolchain required)"
python3 "$ROOT/tool/check_contract.py" || die "the Dart/Kotlin/Swift wire contract has drifted"
ok "wire contract consistent"

step "flutter pub get"
( cd "$ROOT" && flutter pub get )
( cd "$EXAMPLE" && flutter pub get )
ok "packages resolved"

step "dart format (check only)"
( cd "$ROOT" && dart format --output=none --set-exit-if-changed \
    lib test example/lib example/integration_test example/test_driver ) \
  || die "formatting drift — run: dart format lib test example/lib example/integration_test example/test_driver"
ok "formatting clean"

step "flutter analyze (package)"
( cd "$ROOT" && flutter analyze --no-pub ) || die "analyzer issues in the package"
ok "package analyzes clean"

step "flutter analyze (example)"
( cd "$EXAMPLE" && flutter analyze --no-pub ) || die "analyzer issues in the example"
ok "example analyzes clean"

step "flutter test"
( cd "$ROOT" && flutter test --no-pub ) || die "unit tests failed"
ok "unit tests pass"

if [[ $FAST -eq 1 ]]; then
  printf '\n\033[1;32mFast checks passed. Native builds skipped (--fast).\033[0m\n'
  exit 0
fi

step "flutter build apk --debug (Android)"
( cd "$EXAMPLE" && flutter build apk --debug ) || die "Android build failed"
ok "Android builds"

if [[ $WITH_IOS -eq 1 ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || die "--ios requires macOS."
  step "flutter build ios --no-codesign"
  ( cd "$EXAMPLE" && flutter build ios --no-codesign --debug ) || die "iOS build failed"
  ok "iOS builds"
else
  printf '\n\033[1;33m! iOS build skipped. Re-run with --ios on macOS.\033[0m\n'
fi

printf '\n\033[1;32mAll requested checks passed.\033[0m\n'
