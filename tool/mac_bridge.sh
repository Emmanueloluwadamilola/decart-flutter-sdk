#!/usr/bin/env bash
#
# ============================================================================
#  mac_bridge.sh — run this ON YOUR MAC, in a real macOS terminal.
# ============================================================================
#
#  WHAT IT IS
#
#  The Cowork session cannot reach your Mac's shell. It has a cloud container
#  (no Flutter, no network to pub.dev) and a sandboxed Linux VM on your machine
#  (no Flutter, no network) — neither is macOS, so neither can see your
#  toolchain.
#
#  What both sides *can* see is this project folder. This script turns that
#  shared folder into a command channel: the session writes a shell script into
#  .bridge/requests/, this loop executes it here on macOS where Flutter and
#  Xcode actually live, and writes the output back to .bridge/responses/ where
#  the session can read it.
#
#  ---------------------------------------------------------------------------
#  READ THIS BEFORE RUNNING IT
#
#  This gives the session arbitrary command execution on your Mac, with your
#  user's permissions, for as long as the loop is running. That is the whole
#  point of it, but it is worth saying plainly rather than burying.
#
#  What limits the blast radius:
#    * It only runs while this terminal is open. Ctrl-C ends it immediately.
#    * Every command is printed in full BEFORE it runs. Nothing is hidden.
#    * Everything is appended to .bridge/bridge.log for after-the-fact review.
#    * It refuses to start outside this project directory.
#    * `--confirm` makes it pause for your Enter before each command.
#
#  What does NOT limit it: the commands themselves are ordinary shell and can
#  touch anything your user account can touch. If that is more trust than you
#  want to extend, use `--once` instead (below) — it runs a fixed, known
#  sequence and no session-supplied commands at all.
#  ---------------------------------------------------------------------------
#
#  USAGE
#
#    tool/mac_bridge.sh              # bridge; runs session commands as they arrive
#    tool/mac_bridge.sh --confirm    # same, but asks before each command
#    tool/mac_bridge.sh --once       # no bridge: just run bootstrap + verify,
#                                    #   write the log, exit. Nothing arbitrary.
#    tool/mac_bridge.sh --status     # show what's queued/done, then exit
#
#  To stop: Ctrl-C, or `touch .bridge/STOP` from anywhere.
#
set -uo pipefail

# macOS ships bash 3.2, so nothing here uses bash 4+ features.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/.bridge"
REQ="$BRIDGE/requests"
RES="$BRIDGE/responses"
LOG="$BRIDGE/bridge.log"
POLL_SECONDS=3

MODE="bridge"
CONFIRM=0
for arg in "$@"; do
  case "$arg" in
    --once)    MODE="once" ;;
    --status)  MODE="status" ;;
    --confirm) CONFIRM=1 ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

c_cyan=$'\033[1;36m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'
c_red=$'\033[1;31m';  c_dim=$'\033[2m';      c_off=$'\033[0m'

say()  { printf '%s▸%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ── Refuse to run anywhere but this project ─────────────────────────────────
[ -f "$ROOT/pubspec.yaml" ] || die "no pubspec.yaml at $ROOT — run this from the plugin repo."
grep -q '^name: decart_vton_flutter' "$ROOT/pubspec.yaml" \
  || die "$ROOT does not look like the decart_vton_flutter package."

mkdir -p "$REQ" "$RES"
cd "$ROOT" || die "cannot cd to $ROOT"

# ── --status ────────────────────────────────────────────────────────────────
if [ "$MODE" = "status" ]; then
  say "bridge dir: $BRIDGE"
  pending=0; done_count=0
  for f in "$REQ"/*.sh; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .sh)"
    if [ -f "$RES/$id.exit" ]; then
      done_count=$((done_count + 1))
      printf '  %s%s%s  exit=%s\n' "$c_dim" "$id" "$c_off" "$(cat "$RES/$id.exit")"
    else
      pending=$((pending + 1))
      printf '  %s  PENDING\n' "$id"
    fi
  done
  echo
  ok "$done_count completed, $pending pending"
  exit 0
fi

# ── --once: fixed sequence, no session-supplied commands ────────────────────
if [ "$MODE" = "once" ]; then
  OUT="$BRIDGE/once.log"
  say "Running the fixed verification sequence. Output → .bridge/once.log"
  {
    echo "=== mac_bridge --once  $(stamp) ==="
    echo "--- uname"; uname -a
    echo "--- which flutter dart xcodebuild pod"; which flutter dart xcodebuild pod
    echo "--- flutter --version"; flutter --version
    echo "--- flutter doctor -v"; flutter doctor -v
    echo "--- tool/bootstrap_example.sh"; bash tool/bootstrap_example.sh
    echo "--- tool/verify.sh --ios"; bash tool/verify.sh --ios
    echo "=== done, exit=$? ==="
  } 2>&1 | tee "$OUT"
  echo
  ok "Wrote $OUT — tell the session it's there and it will read it."
  exit 0
fi

# ── bridge loop ─────────────────────────────────────────────────────────────
rm -f "$BRIDGE/STOP"
: > "$BRIDGE/heartbeat"

cat <<BANNER

${c_green}decart_vton_flutter — mac bridge active${c_off}
  project : $ROOT
  polling : every ${POLL_SECONDS}s for .bridge/requests/*.sh
  confirm : $([ "$CONFIRM" = 1 ] && echo "ON (you approve each command)" || echo "OFF (commands run automatically)")
  stop    : Ctrl-C, or touch .bridge/STOP
  log     : .bridge/bridge.log

$([ "$CONFIRM" = 1 ] || echo "${c_yellow}Commands from the session will execute here automatically. Watch this window.${c_off}")

BANNER

echo "=== bridge started $(stamp) ===" >> "$LOG"
trap 'echo; warn "bridge stopped."; echo "=== bridge stopped $(stamp) ===" >> "$LOG"; exit 0' INT TERM

while true; do
  [ -f "$BRIDGE/STOP" ] && { warn "STOP file found."; break; }
  : > "$BRIDGE/heartbeat"

  next=""
  for f in "$REQ"/*.sh; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .sh)"
    [ -f "$RES/$id.exit" ] && continue
    next="$id"
    break
  done

  if [ -z "$next" ]; then
    sleep "$POLL_SECONDS"
    continue
  fi

  script="$REQ/$next.sh"
  printf '\n%s══ request %s ══%s\n' "$c_cyan" "$next" "$c_off"
  printf '%s' "$c_dim"; sed 's/^/  | /' "$script"; printf '%s\n' "$c_off"

  if [ "$CONFIRM" = 1 ]; then
    printf 'Run this? [Enter = yes, s = skip, q = quit] '
    read -r reply </dev/tty
    case "$reply" in
      s|S) echo "126" > "$RES/$next.exit"
           echo "skipped by user" > "$RES/$next.log"
           warn "skipped $next"; continue ;;
      q|Q) warn "quit"; break ;;
    esac
  fi

  {
    echo "--- request $next  $(stamp)"
    cat "$script"
    echo "--- output"
  } >> "$LOG"

  started=$(date +%s)
  # Run in a subshell rooted at the project so a stray `cd` cannot wander.
  ( cd "$ROOT" && bash "$script" ) 2>&1 | tee "$RES/$next.log" | tee -a "$LOG"
  code="${PIPESTATUS[0]}"
  elapsed=$(( $(date +%s) - started ))

  echo "$code" > "$RES/$next.exit"
  echo "--- exit=$code elapsed=${elapsed}s" >> "$LOG"

  if [ "$code" = "0" ]; then
    ok "request $next finished (exit 0, ${elapsed}s)"
  else
    warn "request $next finished (exit $code, ${elapsed}s)"
  fi
done

echo "=== bridge stopped $(stamp) ===" >> "$LOG"
ok "bridge stopped."
