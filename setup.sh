#!/usr/bin/env bash
# Android TV / Google TV deployment helper.
#
# Backs up device state, installs a launcher, hands Home to it, applies a
# debloat list, and records everything needed to undo the change.
#
# Tested on a Chromecast with Google TV 4K (sabrina, Android 14). The ADB
# commands are standard Android commands, so the same workflow works on other
# Android TV and Google TV devices.
set -euo pipefail

VERSION="1.0.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="${ADB:-adb}"
STATE_ROOT="${STATE_ROOT:-$HOME/.android-tv-clean-setup}"

HOST="${TV_HOST:-}"
TARGET="${ADB_SERIAL:-}"
PAIR_PORT="${PAIR_PORT:-}"
PAIR_CODE="${PAIR_CODE:-}"
APK="${LAUNCHER_APK:-$ROOT/launcher/cleanyourtv.apk}"
PKG="${LAUNCHER_PACKAGE:-com.gathin.tvhome}"
COMPONENT="${LAUNCHER_COMPONENT:-com.gathin.tvhome/.MainActivity}"
LIST="${DEBLOAT_LIST:-$ROOT/lists/generic-telemetry.txt}"
STOCK="${STOCK_LAUNCHER:-}"
STATE_DIR="${STATE_DIR:-}"

DRY_RUN=0
ASSUME_YES=0
DEBLOAT_ONLY=0
NO_DISABLE_STOCK=0
ALLOW_SETUPWRAITH="${ALLOW_SETUPWRAITH:-0}"
FORCE=0
COMMAND=""

KNOWN_STOCK_LAUNCHERS="com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher com.mitv.tvhome"
SETUPWRAITH="com.google.android.tungsten.setupwraith"
PROTECTED_PACKAGES="
com.android.systemui
com.android.settings
com.android.shell
com.android.packageinstaller
com.google.android.gms
com.android.vending
com.google.android.tv.remote.service
com.google.android.katniss
com.google.android.tts
com.google.android.apps.mediashell
com.google.android.tv.dfuservice
"

info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Android TV clean setup: launcher + debloat

Usage:
  ./setup.sh --host <tv-ip>
  ./setup.sh --host <tv-ip> --list lists/chromecast-gtv-4k.txt
  ./setup.sh --host <tv-ip> --debloat-only
  ./setup.sh --host <tv-ip> --restore
  ./setup.sh --host <tv-ip> --dry-run

With no command, setup.sh backs up the TV, installs the bundled CleanYourTV
launcher, makes it Home, applies a debloat list, and verifies the result.

Options:
  -H, --host IP[:PORT]       TV address (or set TV_HOST; default port 5555)
      --serial SERIAL        Use an existing ADB serial instead of --host
      --pair PORT            Wireless-debugging pairing port
      --code CODE            Six-digit pairing code
  -a, --apk FILE             Launcher APK (default: bundled CleanYourTV APK)
  -l, --list FILE            Debloat list (default: generic telemetry list)
      --state DIR            Backup directory to write or restore
      --debloat-only         Skip the launcher and keep the current Home app
      --restore              Re-enable packages and restore the previous Home
      --no-disable-stock     Keep the stock launcher enabled
      --allow-setupwraith    Allow disabling Google TV's setupwraith
      --force                Allow protected packages and unknown launchers
      --dry-run              Print changes without applying them
  -y, --yes                  Do not ask for confirmation
  -h, --help                 Show this help

Other commands:
  ./setup.sh probe --host ...       Show device information
  ./setup.sh launchers --host ...   List apps that can be Home
  ./setup.sh verify --host ...      Show the current state
  ./setup.sh version

Environment:
  TV_HOST, ADB_SERIAL, ADB, STATE_ROOT, LAUNCHER_APK, DEBLOAT_LIST,
  STOCK_LAUNCHER, ALLOW_SETUPWRAITH
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -H|--host) HOST="${2:-}"; shift 2 ;;
    --serial) TARGET="${2:-}"; shift 2 ;;
    --pair) PAIR_PORT="${2:-}"; shift 2 ;;
    --code) PAIR_CODE="${2:-}"; shift 2 ;;
    -a|--apk) APK="${2:-}"; shift 2 ;;
    -p|--package) PKG="${2:-}"; shift 2 ;;
    -c|--component) COMPONENT="${2:-}"; shift 2 ;;
    -l|--list) LIST="${2:-}"; shift 2 ;;
    -s|--stock) STOCK="${2:-}"; shift 2 ;;
    --state) STATE_DIR="${2:-}"; shift 2 ;;
    --debloat-only) DEBLOAT_ONLY=1; shift ;;
    --restore) COMMAND="restore"; shift ;;
    --no-disable-stock) NO_DISABLE_STOCK=1; shift ;;
    --allow-setupwraith) ALLOW_SETUPWRAITH=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [ -n "$COMMAND" ]; then die "Unexpected argument: $1"; fi
      COMMAND="$1"
      shift
      ;;
  esac
done

[ -n "$COMMAND" ] || COMMAND="all"
if [ "$COMMAND" = "help" ]; then usage; exit 0; fi

resolve_target() {
  if [ -n "$TARGET" ]; then return 0; fi
  [ -n "$HOST" ] || die "Set --host, TV_HOST, or --serial."
  case "$HOST" in
    *:*) TARGET="$HOST" ;;
    *) TARGET="$HOST:5555" ;;
  esac
}

adb_connect() {
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

get_home() {
  adb_sh "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
    | tail -n 1
}

component_pkg() {
  printf '%s' "${1%%/*}"
}

known_stock() {
  case " $KNOWN_STOCK_LAUNCHERS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

claims_home() {
  adb_sh "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
    | grep -q "^$1/"
}

is_home_for() {
  [ -n "$2" ] || return 1
  case "$1" in
    "$2"/*) return 0 ;;
  esac
  return 1
}

latest_state() {
  [ -d "$STATE_ROOT" ] || return 1
  ls -1dt "$STATE_ROOT"/*/ 2>/dev/null | head -n 1 | sed 's:/$::'
}

require_state() {
  if [ -n "$STATE_DIR" ]; then
    [ -d "$STATE_DIR" ] || die "State directory not found: $STATE_DIR"
    return 0
  fi
  STATE_DIR="$(latest_state || true)"
  [ -n "$STATE_DIR" ] || die "No state directory found under $STATE_ROOT. Run backup first."
}

ensure_state() {
  if [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ]; then return 0; fi
  if [ -z "$STATE_DIR" ]; then STATE_DIR="$(latest_state || true)"; fi
  if [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ]; then return 0; fi
  backup
}

backup() {
  local stamp target_name
  stamp="$(date +%Y%m%d-%H%M%S)"
  target_name="$(printf '%s' "$TARGET" | tr -c 'A-Za-z0-9._-' '_')"
  STATE_DIR="$STATE_ROOT/${stamp}-${target_name}"
  mkdir -p "$STATE_DIR"
  info "Backing up $TARGET to $STATE_DIR"
  printf '%s\n' "$TARGET" > "$STATE_DIR/target.txt"
  adb_sh "getprop" > "$STATE_DIR/props.txt"
  adb_sh "pm list packages" > "$STATE_DIR/packages.txt"
  adb_sh "pm list packages -e" > "$STATE_DIR/enabled.txt"
  adb_sh "pm list packages -d" > "$STATE_DIR/disabled.txt"
  get_home > "$STATE_DIR/home.txt"
  adb_sh "settings get secure screensaver_components" > "$STATE_DIR/screensaver_components.txt"
  adb_sh "settings get secure enabled_accessibility_services" > "$STATE_DIR/accessibility_services.txt"
  : > "$STATE_DIR/disabled-by-us.txt"
  info "Saved $(grep -c '^package:' "$STATE_DIR/packages.txt" || true) installed packages."
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
    *"new state: disabled"*|*"new state: disabled-user"*)
      return 0 ;;
    *"Error"*|*"Exception"*|*"Failure"*|*"cannot"*|*"not allowed"*)
      return 1 ;;
  esac
  adb_sh "pm list packages -d" | grep -qx "package:$pkg"
}

enable_pkg() {
  local pkg="$1" out
  if [ "$DRY_RUN" = 1 ]; then
    info "Would enable $pkg"
    return 0
  fi
  out="$(adb_sh "pm enable --user 0 $pkg")"
  [ -n "$out" ] && printf '    %s\n' "$out"
  adb_sh "pm list packages -e" | grep -qx "package:$pkg"
}

resolve_list() {
  [ -n "$LIST" ] || die "Set --list or DEBLOAT_LIST."
  if [ -f "$LIST" ]; then return 0; fi
  if [ -f "$ROOT/$LIST" ]; then LIST="$ROOT/$LIST"; return 0; fi
  die "Debloat list not found: $LIST"
}

apply_debloat() {
  local pkg line current_home current_pkg
  ensure_state
  resolve_list
  adb_sh "pm list packages -e" > "$STATE_DIR/current-enabled.txt"
  current_home="$(get_home)"
  current_pkg="$(component_pkg "$current_home")"
  info "Applying $LIST"
  info "Home before debloat: ${current_home:-unknown}"

  while IFS= read -r line; do
    pkg="$(printf '%s' "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^package://')"
    [ -n "$pkg" ] || continue

    case " $PROTECTED_PACKAGES " in
      *" $pkg "*)
        if [ "$FORCE" != 1 ]; then
          warn "Skipping protected package $pkg (use --force to override)."
          continue
        fi
        ;;
    esac

    if [ "$pkg" = "$current_pkg" ]; then
      warn "Skipping $pkg because it currently owns Home. Install the new launcher first."
      continue
    fi

    if [ "$pkg" = "$SETUPWRAITH" ] && [ "$ALLOW_SETUPWRAITH" != 1 ]; then
      warn "Skipping $SETUPWRAITH. Pass --allow-setupwraith if you accept the casting and network caveats."
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
      if [ "$DRY_RUN" != 1 ]; then
        printf '%s\n' "$pkg" >> "$STATE_DIR/disabled-by-us.txt"
        drop_enabled "$pkg"
      fi
      info "  disabled $pkg"
    else
      warn "Could not disable $pkg."
    fi
  done < <(grep -v '^[[:space:]]*$' "$LIST")

  if [ -s "$STATE_DIR/disabled-by-us.txt" ]; then
    sort -u "$STATE_DIR/disabled-by-us.txt" -o "$STATE_DIR/disabled-by-us.txt"
    info "Disabled $(wc -l < "$STATE_DIR/disabled-by-us.txt" | tr -d ' ') packages. Undo with:"
    info "  ./setup.sh --host $TARGET --state $STATE_DIR --restore"
  else
    info "No packages changed."
  fi
}

resolve_launcher() {
  [ -n "$PKG" ] || [ -n "$APK" ] || die "Set --package or --apk."
  if [ -n "$APK" ] && [ ! -f "$APK" ]; then die "APK not found: $APK"; fi
  if [ -z "$PKG" ]; then
    die "Set --package so the script knows which app to start. Example: --package juniojsv.minimum"
  fi
  if [ -z "$COMPONENT" ]; then
    COMPONENT="$(adb_sh "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $PKG" | tail -n 1)"
    if [ -z "$COMPONENT" ]; then
      COMPONENT="$(adb_sh "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME $PKG" | tail -n 1)"
    fi
  fi
  [ -n "$COMPONENT" ] || die "Set --component. Example: --component juniojsv.minimum/.MainActivity"
}

install_launcher() {
  local old_home old_pkg set_out start_out home
  ensure_state
  resolve_launcher
  old_home="$(get_home)"
  old_pkg="$(component_pkg "$old_home")"
  if [ -z "$STOCK" ] && known_stock "$old_pkg"; then STOCK="$old_pkg"; fi

  info "Launcher: $PKG"
  info "Component: $COMPONENT"
  info "Home before: ${old_home:-unknown}"
  info "Stock launcher: ${STOCK:-not detected}"

  if [ -n "$APK" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      info "Would install $APK"
    else
      info "Installing $APK"
      start_out="$("$ADB" -s "$TARGET" install -r "$APK" 2>&1 || true)"
      printf '%s\n' "$start_out"
      case "$start_out" in
        *Success*) ;;
        *) die "APK install failed. The stock launcher was not changed." ;;
      esac
    fi
  else
    is_installed "$PKG" || die "$PKG is not installed. Pass --apk or install it first."
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "Would start $COMPONENT"
    info "Would run: cmd package set-home-activity --user 0 $COMPONENT"
    [ "$NO_DISABLE_STOCK" = 1 ] || [ -z "$STOCK" ] || info "Would disable stock launcher $STOCK"
    return 0
  fi

  start_out="$(adb_sh "am start -W -n $COMPONENT")"
  printf '%s\n' "$start_out"
  case "$start_out" in
    *"Status: ok"*) ;;
    *) die "The launcher did not start. The stock launcher was left untouched." ;;
  esac

  set_out="$(adb_sh "cmd package set-home-activity --user 0 $COMPONENT")"
  case "$set_out" in
    *Success*) ;;
    *)
      set_out="$(adb_sh "pm set-home-activity --user 0 $COMPONENT")"
      case "$set_out" in
        *Success*) ;;
        *) warn "set-home-activity did not report Success. Checking the result anyway." ;;
      esac
      ;;
  esac

  home="$(get_home)"
  if ! is_home_for "$home" "$PKG" && ! { [ "$home" = "android" ] && claims_home "$PKG"; }; then
    warn "Home is still $home."
    if is_home_for "$home" "$SETUPWRAITH" && [ "$ALLOW_SETUPWRAITH" = 1 ]; then
      disable_pkg "$SETUPWRAITH" || true
      adb_sh "cmd package set-home-activity --user 0 $COMPONENT" >/dev/null || true
      home="$(get_home)"
    fi
  fi

  if ! is_home_for "$home" "$PKG" && ! { [ "$home" = "android" ] && claims_home "$PKG"; }; then
    warn "Home did not move to $PKG. Restoring the previous Home."
    if [ -n "$STOCK" ]; then enable_pkg "$STOCK" || true; fi
    if [ -n "$old_home" ] && [ "$old_home" != "android" ]; then
      adb_sh "cmd package set-home-activity --user 0 $old_home" >/dev/null || true
    fi
    die "Launcher handover failed; the stock launcher was left in place."
  fi

  if [ "$NO_DISABLE_STOCK" = 1 ]; then
    info "Stock launcher left enabled (--no-disable-stock)."
  elif [ -z "$STOCK" ]; then
    warn "No stock launcher detected. The old launcher was left enabled."
  elif [ "$STOCK" = "$PKG" ]; then
    info "The new launcher is already the stock launcher."
  elif ! known_stock "$STOCK" && [ "$FORCE" != 1 ]; then
    warn "Not disabling unknown launcher $STOCK. Pass --stock or --force to override."
  else
    if disable_pkg "$STOCK"; then
      printf '%s\n' "$STOCK" >> "$STATE_DIR/disabled-by-us.txt"
      info "Disabled stock launcher $STOCK."
    else
      warn "Could not disable $STOCK."
    fi
  fi

  home="$(get_home)"
  if ! is_home_for "$home" "$PKG" && ! { [ "$home" = "android" ] && claims_home "$PKG"; }; then
    warn "Home moved away after disabling the stock launcher: $home"
    if [ -n "$STOCK" ]; then enable_pkg "$STOCK" || true; fi
    if [ -n "$old_home" ] && [ "$old_home" != "android" ]; then
      adb_sh "cmd package set-home-activity --user 0 $old_home" >/dev/null || true
    fi
    die "Handover rolled back."
  fi

  info "Home now resolves to $home."
  info "Press Home on the remote to open $PKG."
}

restore_state() {
  local pkg old_home old_pkg screensaver
  require_state
  [ -f "$STATE_DIR/disabled-by-us.txt" ] || die "No disabled-by-us.txt in $STATE_DIR."
  info "Restoring from $STATE_DIR"
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if enable_pkg "$pkg"; then info "  enabled $pkg"; else warn "Could not enable $pkg."; fi
  done < "$STATE_DIR/disabled-by-us.txt"

  old_home="$(cat "$STATE_DIR/home.txt" 2>/dev/null || true)"
  old_pkg="$(component_pkg "$old_home")"
  if [ -n "$old_pkg" ] && [ "$old_pkg" != "android" ]; then
    enable_pkg "$old_pkg" || true
    adb_sh "cmd package set-home-activity --user 0 $old_home" >/dev/null || true
    info "Restored Home to $old_home."
  elif [ -n "$STOCK" ]; then
    enable_pkg "$STOCK" || true
    old_home="$(adb_sh "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME $STOCK" | tail -n 1)"
    if [ -n "$old_home" ]; then
      adb_sh "cmd package set-home-activity --user 0 $old_home" >/dev/null || true
      info "Restored Home to $old_home."
    fi
  fi

  screensaver="$(cat "$STATE_DIR/screensaver_components.txt" 2>/dev/null || true)"
  case "$screensaver" in
    ""|null|"null") ;;
    *) adb_sh "settings put secure screensaver_components '$screensaver'" >/dev/null || true ;;
  esac
  info "Home is now $(get_home)."
}

verify_state() {
  if [ -z "$STATE_DIR" ]; then STATE_DIR="$(latest_state || true)"; fi
  info "Device: $(adb_sh 'getprop ro.product.manufacturer') $(adb_sh 'getprop ro.product.model')"
  info "Android: $(adb_sh 'getprop ro.build.version.release') (SDK $(adb_sh 'getprop ro.build.version.sdk'))"
  info "Home: $(get_home)"
  [ -n "$PKG" ] && info "Launcher package: $PKG"
  if [ -n "$PKG" ]; then
    adb_sh "dumpsys package $PKG" | grep -E 'versionName=|versionCode=' | head -n 2 || true
  fi
  if [ -s "$STATE_DIR/disabled-by-us.txt" ]; then
    info "Packages disabled by this state:"
    sed 's/^/  /' "$STATE_DIR/disabled-by-us.txt"
  else
    info "No packages recorded as disabled by this state."
  fi
}

probe_device() {
  adb_connect
  local manufacturer model home
  manufacturer="$(adb_sh 'getprop ro.product.manufacturer')"
  model="$(adb_sh 'getprop ro.product.model')"
  info "Device: ${manufacturer} ${model}"
  info "Device name: $(adb_sh 'getprop ro.product.device')"
  info "Android: $(adb_sh 'getprop ro.build.version.release') (SDK $(adb_sh 'getprop ro.build.version.sdk'))"
  info "Build: $(adb_sh 'getprop ro.build.fingerprint')"
  info "Characteristics: $(adb_sh 'getprop ro.build.characteristics')"
  home="$(get_home)"
  info "Home: ${home:-unknown}"
  info "Home candidates:"
  adb_sh "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
    | sed 's/^/  /' || true
  case "$manufacturer $model $(adb_sh 'getprop ro.build.characteristics')" in
    *Amazon*|*Fire*|*firetv*)
      warn "This looks like a Fire TV. Fire OS does not hand Home to a third-party launcher; use debloat only."
      ;;
  esac
}

list_launchers() {
  adb_connect
  adb_sh "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME" \
    | sort -u
}

connect_only() {
  adb_connect
  "$ADB" devices -l
}

run_all() {
  [ -n "$LIST" ] || die "Set --list or DEBLOAT_LIST for the debloat step."
  if [ "$DEBLOAT_ONLY" = 1 ]; then
    info "Plan: backup, debloat with $LIST, verify. The launcher is left alone."
  else
    [ -n "$PKG" ] || die "Set --package."
    info "Plan: backup, install $PKG from $APK, make it Home, debloat with $LIST, verify."
  fi
  info "State root: $STATE_ROOT"
  if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
    printf 'Continue? [y/N] '
    read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) info "Cancelled."; exit 0 ;;
    esac
  fi
  adb_connect
  backup
  if [ "$DEBLOAT_ONLY" != 1 ]; then install_launcher; fi
  apply_debloat
  verify_state
}

case "$COMMAND" in
  probe) probe_device ;;
  launchers) list_launchers ;;
  connect) connect_only ;;
  backup) adb_connect; backup ;;
  launcher) adb_connect; install_launcher ;;
  debloat) adb_connect; apply_debloat ;;
  verify) adb_connect; verify_state ;;
  restore) adb_connect; restore_state ;;
  all) run_all ;;
  version) info "$VERSION" ;;
  *) die "Unknown command: $COMMAND. Run ./setup.sh --help." ;;
esac
