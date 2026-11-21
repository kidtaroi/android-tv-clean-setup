#!/usr/bin/env bash
# Reversible Android TV / Google TV debloat over ADB.
#
# Disables packages with pm disable-user --user 0. Nothing is uninstalled.
# A backup is written before the first change, and --restore puts it back.
set -euo pipefail

VERSION="1.0.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="${ADB:-adb}"
STATE_ROOT="${STATE_ROOT:-$HOME/.android-tv-debloat}"

HOST="${TV_HOST:-}"
TARGET="${ADB_SERIAL:-}"
PAIR_PORT="${PAIR_PORT:-}"
PAIR_CODE="${PAIR_CODE:-}"
LIST="${DEBLOAT_LIST:-}"
STATE_DIR="${STATE_DIR:-}"
RESTORE=0
DRY_RUN=0
FORCE=0
ALLOW_SETUPWRAITH="${ALLOW_SETUPWRAITH:-0}"

SETUPWRAITH="com.google.android.tungsten.setupwraith"
PROTECTED=" com.android.systemui com.android.settings com.android.shell com.android.packageinstaller com.google.android.gms com.android.vending com.google.android.tv.remote.service com.google.android.katniss com.google.android.tts com.google.android.apps.mediashell com.google.android.tv.dfuservice "

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Android TV / Google TV debloat

Usage:
  ./debloat.sh --host 192.168.1.50
  ./debloat.sh --host 192.168.1.50 --list lists/chromecast-gtv-4k.txt
  ./debloat.sh --host 192.168.1.50 --restore
  ./debloat.sh --host 192.168.1.50 --dry-run

Options:
  -H, --host IP[:PORT]   TV address (or set TV_HOST; default port 5555)
      --serial SERIAL    Use an existing ADB serial instead of --host
      --pair PORT        Wireless-debugging pairing port
      --code CODE        Six-digit pairing code
  -l, --list FILE        Package list (default: lists/generic-telemetry.txt)
      --state DIR        State directory to write or restore
      --restore          Re-enable packages disabled by the selected state
      --dry-run          Print packages without changing the TV
      --allow-setupwraith Allow disabling Google TV's setupwraith
      --force            Allow protected packages
  -h, --help             Show this help
      --version          Show the version

The default list is safe to start with. Read it before you apply it. Remove
any line for an app you use. The script skips the current Home app and the
protected packages listed in the script.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) info "$VERSION"; exit 0 ;;
    -H|--host) HOST="${2:-}"; shift 2 ;;
    --serial) TARGET="${2:-}"; shift 2 ;;
    --pair) PAIR_PORT="${2:-}"; shift 2 ;;
    --code) PAIR_CODE="${2:-}"; shift 2 ;;
    -l|--list) LIST="${2:-}"; shift 2 ;;
    --state) STATE_DIR="${2:-}"; shift 2 ;;
    --restore) RESTORE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-setupwraith) ALLOW_SETUPWRAITH=1; shift ;;
    --force) FORCE=1; shift ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *) die "Unexpected argument: $1" ;;
  esac
done

[ -n "$LIST" ] || LIST="$ROOT/lists/generic-telemetry.txt"
if [ ! -f "$LIST" ] && [ -f "$ROOT/$LIST" ]; then LIST="$ROOT/$LIST"; fi

resolve_target() {
  if [ -n "$TARGET" ]; then return 0; fi
  [ -n "$HOST" ] || die "Set --host or TV_HOST."
  case "$HOST" in
    *:*) TARGET="$HOST" ;;
    *) TARGET="$HOST:5555" ;;
  esac
}

connect_adb() {
  resolve_target
  if "$ADB" devices | awk 'NR>1 {print $1}' | grep -qx "$TARGET"; then
    :
  else
    if [ -n "$PAIR_PORT" ]; then
      [ -n "$PAIR_CODE" ] || die "--pair needs --code."
      "$ADB" pair "${HOST%:*}:$PAIR_PORT" "$PAIR_CODE" || true
    fi
    "$ADB" connect "$TARGET" || true
  fi
  [ "$("$ADB" -s "$TARGET" get-state 2>/dev/null || true)" = "device" ] \
    || die "ADB cannot reach $TARGET. Enable debugging on the TV and try again."
}

adb_sh() {
  "$ADB" -s "$TARGET" shell "$1" 2>/dev/null | tr -d '\r' || true
}

latest_state() {
  [ -d "$STATE_ROOT" ] || return 1
  ls -1dt "$STATE_ROOT"/*/ 2>/dev/null | head -n 1 | sed 's:/$::'
}

backup() {
  local stamp name
  if [ -z "$STATE_DIR" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    name="$(printf '%s' "$TARGET" | tr -c 'A-Za-z0-9._-' '_')"
    STATE_DIR="$STATE_ROOT/${stamp}-${name}"
  fi
  mkdir -p "$STATE_DIR"
  info "Backup: $STATE_DIR"
  if [ ! -f "$STATE_DIR/packages.txt" ]; then
    adb_sh "pm list packages" > "$STATE_DIR/packages.txt"
    adb_sh "pm list packages -e" > "$STATE_DIR/enabled.txt"
    adb_sh "pm list packages -d" > "$STATE_DIR/disabled.txt"
    adb_sh "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
      | tail -n 1 > "$STATE_DIR/home.txt"
  fi
  [ -f "$STATE_DIR/disabled-by-us.txt" ] || : > "$STATE_DIR/disabled-by-us.txt"
  info "Saved $(grep -c '^package:' "$STATE_DIR/packages.txt" || true) packages."
}

is_installed() { grep -qx "package:$1" "$STATE_DIR/packages.txt"; }
is_enabled() { grep -qx "package:$1" "$STATE_DIR/current-enabled.txt"; }

drop_enabled() {
  grep -v "package:$1" "$STATE_DIR/current-enabled.txt" > "$STATE_DIR/current-enabled.tmp" || true
  mv "$STATE_DIR/current-enabled.tmp" "$STATE_DIR/current-enabled.txt"
}

disable_pkg() {
  local pkg="$1" out
  if [ "$DRY_RUN" = 1 ]; then
    info "Would disable $pkg"
    return 0
  fi
  out="$(adb_sh "pm disable-user --user 0 $pkg")"
  [ -n "$out" ] && printf '    %s\n' "$out"
  case "$out" in
    *"new state: disabled"*|*"new state: disabled-user"*) return 0 ;;
    *"Error"*|*"Exception"*|*"Failure"*|*"cannot"*|*"not allowed"*) return 1 ;;
  esac
  adb_sh "pm list packages -d" | grep -qx "package:$pkg"
}

apply_list() {
  local pkg line home current
  [ -f "$LIST" ] || die "List not found: $LIST"
  backup
  adb_sh "pm list packages -e" > "$STATE_DIR/current-enabled.txt"
  home="$(get_home)"
  current="${home%%/*}"
  info "Home: ${home:-unknown}"
  info "List: $LIST"

  while IFS= read -r line; do
    pkg="$(printf '%s' "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^package://')"
    [ -n "$pkg" ] || continue

    case " $PROTECTED " in
      *" $pkg "*)
        if [ "$FORCE" != 1 ]; then
          warn "Skipping protected package $pkg."
          continue
        fi
        ;;
    esac

    if [ "$pkg" = "$current" ]; then
      warn "Skipping $pkg because it owns Home."
      continue
    fi
    if [ "$pkg" = "$SETUPWRAITH" ] && [ "$ALLOW_SETUPWRAITH" != 1 ]; then
      warn "Skipping $SETUPWRAITH. Use --allow-setupwraith only if you accept the casting and Wi-Fi caveats."
      continue
    fi
    if ! is_installed "$pkg"; then
      info "  skip $pkg (not installed)"
      continue
    fi
    if ! is_enabled "$pkg"; then
      info "  skip $pkg (already disabled)"
      continue
    fi

    if disable_pkg "$pkg"; then
      if [ "$DRY_RUN" = 1 ]; then
        info "  would disable $pkg"
      else
        printf '%s\n' "$pkg" >> "$STATE_DIR/disabled-by-us.txt"
        drop_enabled "$pkg"
        info "  disabled $pkg"
      fi
    else
      warn "Could not disable $pkg."
    fi
  done < <(grep -v '^[[:space:]]*$' "$LIST")

  if [ "$DRY_RUN" = 1 ]; then
    info "Dry run complete. Nothing changed."
  elif [ -s "$STATE_DIR/disabled-by-us.txt" ]; then
    sort -u "$STATE_DIR/disabled-by-us.txt" -o "$STATE_DIR/disabled-by-us.txt"
    info "Disabled $(wc -l < "$STATE_DIR/disabled-by-us.txt" | tr -d ' ') packages."
    info "Restore: ./debloat.sh --host $TARGET --state $STATE_DIR --restore"
  else
    info "No packages changed."
  fi
}

get_home() {
  adb_sh "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
    | tail -n 1
}

restore_list() {
  local pkg
  if [ -n "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] || die "State directory not found: $STATE_DIR"
  else
    STATE_DIR="$(latest_state || true)"
    [ -n "$STATE_DIR" ] || die "No state directory found under $STATE_ROOT."
  fi
  [ -f "$STATE_DIR/disabled-by-us.txt" ] || die "No disabled-by-us.txt in $STATE_DIR."
  info "Restoring: $STATE_DIR"
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
      info "Would enable $pkg"
    else
      adb_sh "pm enable --user 0 $pkg" >/dev/null
      if adb_sh "pm list packages -e" | grep -qx "package:$pkg"; then
        info "  enabled $pkg"
      else
        warn "Could not enable $pkg."
      fi
    fi
  done < "$STATE_DIR/disabled-by-us.txt"
  info "Done."
}

connect_adb
if [ "$RESTORE" = 1 ]; then
  restore_list
else
  apply_list
fi
