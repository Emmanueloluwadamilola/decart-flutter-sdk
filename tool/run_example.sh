#!/usr/bin/env bash
# Runs the example. Production may load a token endpoint from example/.env;
# local debug builds may instead use the temporary key in example/lib/main.dart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/example"
ENV_FILE="$EXAMPLE/.env"
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH."

HAS_ENDPOINT=0
if [[ -f "$ENV_FILE" ]] && grep -Eq '^[[:space:]]*DECART_TOKEN_ENDPOINT=https://[^[:space:]]+' "$ENV_FILE"; then
  HAS_ENDPOINT=1
fi
if [[ -f "$ENV_FILE" ]] && grep -Eq '^[[:space:]]*DECART_API_KEY=' "$ENV_FILE"; then
  die "DECART_API_KEY is no longer read from example/.env. Put a temporary debug-only dct_ key in _developmentApiKey in example/lib/main.dart."
fi

cd "$EXAMPLE"
if [[ $HAS_ENDPOINT -eq 1 ]]; then
  exec flutter run --dart-define-from-file=.env "$@"
fi
exec flutter run "$@"
