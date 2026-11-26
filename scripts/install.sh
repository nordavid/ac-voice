#!/bin/bash
# Builds and signs "AC Voice.app", installs it into ~/Applications and starts it in the background.
#
# Usage: scripts/install.sh [--dry-run] [--no-open] [-h|--help]
#   --dry-run  print every step and its command, change nothing (no build, no quit, no copy, no launch)
#   --no-open  install only, do not start the app
#
# Environment:
#   SIGN_ID, SIGN_KEYCHAIN, CONFIG, VERSION, BUILD_NUMBER, SCRATCH_PATH, HARDENED  passed to scripts/bundle.sh
#   DEST=DIR  install directory (default ~/Applications)
#
# Steps:
#   1. scripts/bundle.sh into a temporary directory, so no second copy of the app stays around
#   2. quit a running "AC Voice" politely with SIGTERM and wait up to 10 s. An Apple Event "quit" would make
#      macOS ask for automation permission (Terminal controls AC Voice), so the script avoids it.
#   3. replace $DEST/AC Voice.app: copy next to it with ditto, verify, then swap with two renames
#   4. register the new copy with LaunchServices (lsregister -f); unregister a stale dist/ copy if there is one
#   5. open -g -b io.github.nordavid.acvoice: LaunchServices starts the app in the background, so macOS attributes
#      the microphone and automation permissions to AC Voice itself
set -euo pipefail

APP_NAME="AC Voice"
BUNDLE_ID="io.github.nordavid.acvoice"
PROCESS_NAME="AC Voice"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

PKG="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-$HOME/Applications}"
DRY_RUN=0
OPEN_APP=1

die() { echo "install.sh: $*" >&2; exit 1; }
say() { echo "install.sh: $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-open) OPEN_APP=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ "$(id -u)" -ne 0 ] || die "do not run as root; the app belongs to your user"
TARGET="$DEST/$APP_NAME.app"

# Runs a command, or prints it in --dry-run mode.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    $'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

running_pids() { pgrep -u "$(id -u)" -x "$PROCESS_NAME" || true; }

[ "$DRY_RUN" = "1" ] && say "dry run, nothing changes"

# 1. Bundle ----------------------------------------------------------------------------------------------------
say "1/5 build and sign (identity: ${SIGN_ID:-first valid Apple Development identity})"
if [ "$DRY_RUN" = "1" ]; then
  STAGING="${TMPDIR:-/tmp}"; STAGING="${STAGING%/}/acvoice-install.XXXXXXXX"
  printf '    $ OUT=%q' "$STAGING"
  for v in SIGN_ID SIGN_KEYCHAIN CONFIG VERSION BUILD_NUMBER SCRATCH_PATH HARDENED; do
    if [ -n "${!v:-}" ]; then printf ' %s=%q' "$v" "${!v}"; fi
  done
  printf ' %q\n' "$PKG/scripts/bundle.sh"
else
  if [ "${SIGN_ID:-}" = "-" ]; then
    say "warning: ad-hoc signature. macOS asks for microphone and Chrome permissions again after every install."
  fi
  STAGING="$(mktemp -d -t acvoice-install)"
  trap 'rm -rf "$STAGING"' EXIT
  OUT="$STAGING" "$PKG/scripts/bundle.sh"
  [ -d "$STAGING/$APP_NAME.app" ] || die "bundle.sh produced no app"
fi
BUILT="$STAGING/$APP_NAME.app"

# 2. Quit a running instance -----------------------------------------------------------------------------------
PIDS="$(running_pids)"
if [ -z "$PIDS" ]; then
  say "2/5 no running instance"
else
  say "2/5 quit running instance (pid $(echo $PIDS))"
  run kill -TERM $PIDS
  if [ "$DRY_RUN" = "0" ]; then
    for _ in $(seq 1 100); do
      [ -z "$(running_pids)" ] && break
      sleep 0.1
    done
    PIDS="$(running_pids)"
    if [ -n "$PIDS" ]; then
      say "warning: AC Voice did not quit within 10 s, forcing it (pid $(echo $PIDS))"
      kill -KILL $PIDS || true
      sleep 0.5
    fi
  fi
fi

# 3. Replace the installed copy --------------------------------------------------------------------------------
NEW="$DEST/.$APP_NAME.app.new.$$"
OLD="$DEST/.$APP_NAME.app.old.$$"
say "3/5 install to $TARGET"
run mkdir -p "$DEST"
run ditto "$BUILT" "$NEW"
run codesign --verify --strict "$NEW"
if [ "$DRY_RUN" = "1" ]; then
  if [ -e "$TARGET" ]; then run mv "$TARGET" "$OLD"; fi
  run mv "$NEW" "$TARGET"
  if [ -e "$TARGET" ]; then run rm -rf "$OLD"; fi
else
  trap 'rm -rf "$STAGING" "$NEW"' EXIT
  if [ -e "$TARGET" ]; then
    mv "$TARGET" "$OLD"
    if ! mv "$NEW" "$TARGET"; then
      mv "$OLD" "$TARGET"
      die "could not move the new app into place; the old version stays installed"
    fi
    rm -rf "$OLD"
  else
    mv "$NEW" "$TARGET"
  fi
fi

# 4. LaunchServices --------------------------------------------------------------------------------------------
say "4/5 register with LaunchServices"
run "$LSREGISTER" -f "$TARGET"
# A second copy can make `open -b` start a stale build (REVIEW m6).
if [ -d "$PKG/dist/$APP_NAME.app" ]; then
  say "note: unregistering the extra copy in dist/ (delete it if you do not need it)"
  run "$LSREGISTER" -u "$PKG/dist/$APP_NAME.app"
fi

# 5. Start -----------------------------------------------------------------------------------------------------
if [ "$OPEN_APP" = "1" ]; then
  say "5/5 start in the background"
  run open -g -b "$BUNDLE_ID"
else
  say "5/5 skipped (--no-open)"
fi

if [ "$DRY_RUN" = "0" ]; then
  VERSION_INFO="$(plutil -extract CFBundleShortVersionString raw -o - "$TARGET/Contents/Info.plist") ($(plutil -extract CFBundleVersion raw -o - "$TARGET/Contents/Info.plist"))"
  say "installed $TARGET $VERSION_INFO"
fi
