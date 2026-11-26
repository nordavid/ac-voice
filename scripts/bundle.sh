#!/bin/bash
# Builds the ACVoiceApp product and assembles a signed "AC Voice.app" (no .xcodeproj needed).
#
# Usage: scripts/bundle.sh [--debug] [--out DIR] [--check-identity] [-h|--help]
#   --debug           debug build (same as CONFIG=debug)
#   --out DIR         output directory (same as OUT=DIR)
#   --check-identity  only resolve the signing identity, run the revocation check, print it and exit
#
# Environment:
#   CONFIG=release|debug  build configuration (default release)
#   OUT=DIR               output directory (default <package>/dist); the app lands at $OUT/AC Voice.app
#   SIGN_ID=ID            SHA-1 hash or name of a code-signing identity. Default: the first valid, non-revoked
#                         "Apple Development" identity. "-" signs ad hoc and skips the revocation check
#                         (ad-hoc signatures change with every build, so macOS asks for permissions again).
#   SIGN_KEYCHAIN=PATH    keychain file that holds SIGN_ID (optional)
#   HARDENED=1|0          hardened runtime with Resources/ACVoice.entitlements (default 1; 0 only for debugging)
#   VERSION=X.Y.Z         marketing version (default: the VERSION file in the package root, else 0.1.0)
#   BUILD_NUMBER=N        CFBundleVersion (default: UTC timestamp yyyymmddHHMM)
#   SCRATCH_PATH=DIR      passed to `swift build --scratch-path` (default: SwiftPM's .build)
#   SWIFT=PATH            swift executable (default: swift)
#
# Output: $OUT/AC Voice.app with Contents/MacOS/AC Voice, Info.plist rendered from Resources/Info.plist.in,
# Resources/AppIcon.icns and the SwiftPM resource bundles of the app's targets. The script ends with
# `codesign --verify --strict` and prints the designated requirement. It never launches the app.
set -euo pipefail

PRODUCT="ACVoiceApp"
APP_NAME="AC Voice"
EXECUTABLE="AC Voice"
BUNDLE_ID="io.github.nordavid.acvoice"
PACKAGE_NAME="ACVoice"   # SwiftPM names resource bundles <package>_<target>.bundle

PKG="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
OUT="${OUT:-$PKG/dist}"
HARDENED="${HARDENED:-1}"
SWIFT="${SWIFT:-swift}"
CHECK_ONLY=0

die() { echo "bundle.sh: $*" >&2; exit 1; }
note() { echo "bundle.sh: $*" >&2; }
with_timeout() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; OUT="$2"; shift ;;
    --check-identity) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ "$(id -u)" -ne 0 ] || die "do not run as root"
case "$CONFIG" in release|debug) ;; *) die "CONFIG must be release or debug, not '$CONFIG'" ;; esac
case "$HARDENED" in 0|1) ;; *) die "HARDENED must be 0 or 1" ;; esac

# --- Version -------------------------------------------------------------------------------------------------
if [ -z "${VERSION:-}" ]; then
  VERSION="0.1.0"
  if [ -f "$PKG/VERSION" ]; then VERSION="$(tr -d '[:space:]' < "$PKG/VERSION")"; fi
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
# Both end up in Info.plist via sed, so allow digits and dots only (also what macOS expects).
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "VERSION must look like 1.2.3, not '$VERSION'"
[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "BUILD_NUMBER must be digits and dots, not '$BUILD_NUMBER'"

# --- Signing identity ----------------------------------------------------------------------------------------
KEYCHAIN_ARGS=()
if [ -n "${SIGN_KEYCHAIN:-}" ]; then KEYCHAIN_ARGS=("$SIGN_KEYCHAIN"); fi

# Valid code-signing identities as "<SHA-1> <quoted name>" lines. `find-identity -v` still lists a revoked
# certificate once trustd cached the OCSP answer, tagged with (CSSMERR_TP_CERT_REVOKED); such lines are dropped.
list_identities() {
  { security find-identity -v -p codesigning ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null || true; } |
    awk '$1 ~ /^[0-9]+\)$/ && length($2) == 40 && $2 ~ /^[0-9A-Fa-f]+$/ && !/CSSMERR_/ { $1 = ""; sub(/^ /, ""); print }'
}

# `find-identity -v` and `codesign --verify` do not check revocation, but AMFI does at launch: a revoked Apple
# certificate gives "Launchd job spawn failed" (POSIX 163). Ask OCSP up front.
# Returns 0 when the certificate is revoked, 1 otherwise (also when the check itself cannot run).
is_revoked() {
  local hash pem tmp out
  hash="$(echo "$1" | tr 'a-f' 'A-F')"
  pem="$({ security find-certificate -a -Z -p ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} 2>/dev/null || true; } | awk -v h="$hash" '
    /^SHA-1 hash:/ { on = (toupper($3) == h) } on { print } /END CERTIFICATE/ { if (on) exit }' | sed -n '/BEGIN CERT/,/END CERT/p')"
  if [ -z "$pem" ]; then
    note "warning: certificate $hash not found, skipping the revocation check"
    return 1
  fi
  tmp="$(mktemp -t acvoice-cert)"
  printf '%s\n' "$pem" > "$tmp"
  # '|| true': verify-cert exits non-zero for untrusted or unreachable as well; only REVOKED blocks.
  out="$(with_timeout 20 security verify-cert -c "$tmp" -p codeSign -R ocsp -R require 2>&1 || true)"
  rm -f "$tmp"
  if [[ "$out" == *REVOKED* ]]; then return 0; fi
  if [[ "$out" != *"certificate verification successful"* ]]; then
    note "note: OCSP check for $hash inconclusive (self-signed or offline); continuing"
  fi
  return 1
}

resolve_identity() {
  local line hash name matches
  if [ "${SIGN_ID:-}" = "-" ]; then
    SIGN_HASH="-"; SIGN_NAME="ad hoc"; return
  fi
  if [ -z "${SIGN_ID:-}" ]; then
    # Default: first valid "Apple Development" identity that OCSP does not report as revoked.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      hash="${line%% *}"; name="${line#* }"
      [[ "$name" == '"Apple Development: '* ]] || continue
      if is_revoked "$hash"; then
        note "skipping revoked identity $hash $name"
        continue
      fi
      SIGN_HASH="$hash"; SIGN_NAME="$name"; return
    done < <(list_identities)
    die "no valid, non-revoked \"Apple Development\" identity found.
  Create one in Xcode > Settings > Accounts > Manage Certificates (+ Apple Development),
  or pass SIGN_ID=<sha1|name> (e.g. a self-signed code-signing certificate), or SIGN_ID=- for ad hoc."
  fi
  if [[ "$SIGN_ID" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    SIGN_HASH="$(echo "$SIGN_ID" | tr 'a-f' 'A-F')"
    SIGN_NAME="$(list_identities | awk -v h="$SIGN_HASH" 'toupper($1) == h { $1 = ""; sub(/^ /, ""); print; exit }')"
    if [ -z "$SIGN_NAME" ]; then
      note "warning: $SIGN_HASH is not among the valid identities (find-identity -v); codesign decides"
      SIGN_NAME="(unlisted)"
    fi
  else
    # A name (or part of one): resolve it to one hash so the revocation check can run.
    matches="$(list_identities | awk -v n="$SIGN_ID" 'index($0, n) > 0')"
    if [ "$(printf '%s' "$matches" | grep -c .)" = "1" ]; then
      SIGN_HASH="${matches%% *}"; SIGN_NAME="${matches#* }"
    else
      note "warning: '$SIGN_ID' does not match exactly one valid identity; skipping the revocation check"
      SIGN_HASH="$SIGN_ID"; SIGN_NAME="$SIGN_ID"
      return
    fi
  fi
  if is_revoked "$SIGN_HASH"; then
    echo "bundle.sh: ERROR: signing certificate $SIGN_HASH $SIGN_NAME is revoked; AMFI will refuse to launch the app." >&2
    exit 2
  fi
}

SIGN_HASH=""; SIGN_NAME=""
resolve_identity
if [ "$CHECK_ONLY" = "1" ]; then
  echo "$SIGN_HASH $SIGN_NAME"
  exit 0
fi
if [ "$SIGN_HASH" = "-" ]; then
  note "warning: ad-hoc signature. Its designated requirement is the cdhash, so microphone, Chrome automation"
  note "         and Keychain grants do not survive the next build. Use an Apple Development identity for daily use."
fi

# --- Inputs --------------------------------------------------------------------------------------------------
PLIST_IN="$PKG/Resources/Info.plist.in"
ENTITLEMENTS="$PKG/Resources/ACVoice.entitlements"
ICON="$PKG/Resources/AppIcon.icns"
[ -f "$PLIST_IN" ] || die "missing $PLIST_IN"
[ -f "$ICON" ] || die "missing $ICON (run: swift scripts/make-icon.swift)"
if [ "$HARDENED" = "1" ]; then
  [ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"
  plutil -lint -s "$ENTITLEMENTS" || die "invalid $ENTITLEMENTS"
fi

# --- Build ---------------------------------------------------------------------------------------------------
BUILD_ARGS=(--package-path "$PKG" -c "$CONFIG")
if [ -n "${SCRATCH_PATH:-}" ]; then BUILD_ARGS+=(--scratch-path "$SCRATCH_PATH"); fi
note "building $PRODUCT ($CONFIG)"
"$SWIFT" build "${BUILD_ARGS[@]}" --product "$PRODUCT"
BIN_DIR="$("$SWIFT" build "${BUILD_ARGS[@]}" --show-bin-path)"
[ -x "$BIN_DIR/$PRODUCT" ] || die "build produced no executable at $BIN_DIR/$PRODUCT"

# --- Assemble ------------------------------------------------------------------------------------------------
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
APP="$OUT/$APP_NAME.app"
# Assemble and sign in a hidden staging directory next to the result, so a failed run never leaves a half-built
# app at $APP and the final move stays on one file system.
STAGE_DIR="$(mktemp -d "$OUT/.bundle-staging.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGE="$STAGE_DIR/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN_DIR/$PRODUCT" "$STAGE/Contents/MacOS/$EXECUTABLE"
chmod 755 "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "$ICON" "$STAGE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Info.plist: substitute the placeholders, then normalize to plain XML (drops the template comment).
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD_NUMBER@/$BUILD_NUMBER/g" "$PLIST_IN" > "$STAGE/Contents/Info.plist"
if grep -q '@[A-Z_]*@' "$STAGE/Contents/Info.plist"; then die "unrendered placeholder in Info.plist.in"; fi
plutil -convert xml1 "$STAGE/Contents/Info.plist"
# The source folder, so the setup window can hand out the Stream Deck commands with an absolute path.
plutil -replace ACVoiceSourceRoot -string "$PKG" "$STAGE/Contents/Info.plist"
plutil -lint -s "$STAGE/Contents/Info.plist" || die "invalid Info.plist"
[ "$(plutil -extract CFBundleExecutable raw -o - "$STAGE/Contents/Info.plist")" = "$EXECUTABLE" ] ||
  die "CFBundleExecutable in Info.plist.in does not match '$EXECUTABLE'"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$STAGE/Contents/Info.plist")" = "$BUNDLE_ID" ] ||
  die "CFBundleIdentifier in Info.plist.in does not match '$BUNDLE_ID'"

# SwiftPM resource bundles. The generated Bundle.module accessor looks in Bundle.main.resourceURL first, so they
# belong in Contents/Resources. The bin dir is shared by every product built with this scratch path, so take
# only bundles of the package's ACVoice* library and app targets and skip test targets.
BUNDLES=()
for b in "$BIN_DIR/${PACKAGE_NAME}_ACVoice"*.bundle; do
  [ -d "$b" ] || continue
  case "$(basename "$b")" in *Tests.bundle) continue ;; esac
  cp -R "$b" "$STAGE/Contents/Resources/"
  BUNDLES+=("$(basename "$b")")
done

# --- Sign ----------------------------------------------------------------------------------------------------
SIGN_ARGS=(--force --sign "$SIGN_HASH" --timestamp=none)
if [ -n "${SIGN_KEYCHAIN:-}" ]; then SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN"); fi
# Nested resource bundles get their own signature first (inside out), so the outer seal stays valid.
for b in ${BUNDLES[@]+"${BUNDLES[@]}"}; do
  codesign "${SIGN_ARGS[@]}" "$STAGE/Contents/Resources/$b"
done
APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [ "$HARDENED" = "1" ]; then APP_SIGN_ARGS+=(--options runtime --entitlements "$ENTITLEMENTS"); fi
codesign "${APP_SIGN_ARGS[@]}" "$STAGE"
codesign --verify --strict "$STAGE" || die "signature check failed; $APP stays unchanged"

# Swap the finished bundle into place, then verify it again at its final path.
rm -rf "$APP"
mv "$STAGE" "$APP"
rm -rf "$STAGE_DIR"
trap - EXIT
codesign --verify --strict --verbose=1 "$APP"

# An identity-based signature has an explicit DR; ad hoc has an implicit one ("# designated => cdhash H...").
DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "built:      $APP"
echo "version:    $VERSION ($BUILD_NUMBER), $CONFIG"
echo "identity:   $SIGN_HASH $SIGN_NAME"
echo "hardened:   $([ "$HARDENED" = "1" ] && echo "yes, entitlements $(basename "$ENTITLEMENTS")" || echo no)"
echo "resources:  AppIcon.icns${BUNDLES[*]+ ${BUNDLES[*]}}"
echo "designated: ${DR:-unknown}"
