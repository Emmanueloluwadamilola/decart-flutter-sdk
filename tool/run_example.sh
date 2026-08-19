#!/usr/bin/env bash
# Runs the example with production token-endpoint or debug-only key configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/example"
ENV_FILE="$EXAMPLE/.env"
ENV_TEMPLATE="$EXAMPLE/env.example"

die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH."

if [[ ! -f "$ENV_FILE" ]]; then
  die "example/.env is missing. Run 'cp -n example/env.example example/.env', then configure one of the documented authentication modes."
fi

HAS_ENDPOINT=0
HAS_DEVELOPMENT_KEY=0
if grep -Eq '^[[:space:]]*DECART_TOKEN_ENDPOINT=https://[^[:space:]]+' "$ENV_FILE"; then
  HAS_ENDPOINT=1
fi
if grep -Eq '^[[:space:]]*DECART_API_KEY=dct_[^[:space:]]+' "$ENV_FILE"; then
  HAS_DEVELOPMENT_KEY=1
fi

if [[ $HAS_ENDPOINT -eq 0 && $HAS_DEVELOPMENT_KEY -eq 0 ]]; then
  die "example/.env must define either a complete HTTPS DECART_TOKEN_ENDPOINT or a debug-only dct_ DECART_API_KEY. See $ENV_TEMPLATE."
fi

if [[ $HAS_ENDPOINT -eq 1 && $HAS_DEVELOPMENT_KEY -eq 1 ]]; then
  die "example/.env defines both authentication modes. Remove DECART_API_KEY before using the production token endpoint."
fi

if [[ $HAS_DEVELOPMENT_KEY -eq 1 ]]; then
  for argument in "$@"; do
    if [[ "$argument" == "--profile" || "$argument" == "--release" ]]; then
      die "DECART_API_KEY is allowed only with a Flutter debug build. Configure DECART_TOKEN_ENDPOINT for profile or release."
    fi
  done
fi

cd "$EXAMPLE"
exec flutter run --dart-define-from-file=.env "$@"
