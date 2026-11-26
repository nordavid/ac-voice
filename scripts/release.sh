#!/bin/bash
# Builds the assets of a GitHub release into one folder: the app as a zip, the Stream Deck plugin and the checksums.
# It never uploads, tags or pushes. docs/DEVELOPMENT.md ("Release") has the manual GitHub steps.
#
# Usage: scripts/release.sh [--out DIR] [--force] [--dry-run] [-h|--help]
#   --out DIR  output directory (same as OUT=DIR). A relative path counts from the current directory.
#   --force    replace the release files of the same version in the output directory
#   --dry-run  check the working tree, the version and the output directory, print every step and its command,
#              build nothing
#
# Environment:
#   OUT=DIR                          output directory (default <package>/dist/release). It holds only the release
#                                    files: the script refuses a directory with other files in it. A Finder
#                                    .DS_Store does not count.
#   VERSION=X.Y.Z                    release version. It overrides the VERSION file in the package root, and without
#                                    both the version is 0.1.0. The plugin's manifest.json must carry it with a fourth
#                                    part (X.Y.Z.0).
#   ALLOW_DIRTY=1                    build a working tree with uncommitted or untracked files. By default the script
#                                    refuses, so the assets match the commit you tag.
#   BUILD_NUMBER, SCRATCH_PATH, SWIFT  passed to scripts/bundle.sh
#   SIGN_ID                          unset or "-". A release is always signed ad hoc: an Apple Development certificate
#                                    carries the developer's email address, and macOS blocks the download anyway.
#
# Output in $OUT, exactly the files to upload:
#   AC-Voice-<version>.zip                                   "AC Voice.app", ad hoc, hardened runtime
#   io.github.nordavid.acvoice.streamdeck.streamDeckPlugin   the Stream Deck plugin (double-click installs it)
#   SHA256SUMS.txt                                           SHA-256 of both files, file names without a path
#
# Steps:
#   1. scripts/bundle.sh with SIGN_ID=- EMBED_SOURCE_ROOT=0 CONFIG=release HARDENED=1 into a temporary directory.
#      Its build output goes to a log file there. When the build fails, the script shows the first errors and the end
#      of the log and keeps a copy of the log in $TMPDIR.
#   2. check the app: strict signature, ad hoc without team, hardened runtime, no ACVoiceSourceRoot in Info.plist,
#      no debug map (OSO and SO stabs) in the executable
#   3. zip it with ditto, unpack the zip again and verify the copy with codesign --verify --strict --deep
#   4. plugin: npm ci (only without node_modules), npm run build, npm run validate, streamdeck pack on a copy of the
#      plugin folder (the CLI rewrites the manifest.json of the folder it packs)
#   5. leak guard: no file of the app or of the plugin package contains the package path, $HOME, the login name, a git
#      email address (of this repository or the global one) or its domain. A hit names the file and the kind of value,
#      never the value itself. A file the guard cannot read counts as a hit.
#   6. SHA256SUMS.txt, then move the three files into a staging folder in $OUT, rename them into place and print a
#      summary
# A failed run leaves $OUT unchanged. The files reach it in the last step, by rename within $OUT.
set -euo pipefail

APP_NAME="AC Voice"
PLUGIN_UUID="io.github.nordavid.acvoice.streamdeck"

PKG="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$PKG/dist/release}"
STREAMDECK="$PKG/streamdeck"
SD_PLUGIN="$PLUGIN_UUID.sdPlugin"
DRY_RUN=0
FORCE=0

die() { echo "release.sh: $*" >&2; exit 1; }
say() { echo "release.sh: $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a directory"; OUT="$2"; shift ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ -n "$OUT" ] || die "--out needs a directory"
# Absolute, so the checks and the final move see the same folder: step 4 changes the working directory.
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
# $OUT in messages: relative to the package when it lies inside, so the default output names no home folder.
case "$OUT" in "$PKG"/*) OUT_SHOWN="${OUT#"$PKG"/}" ;; *) OUT_SHOWN="$OUT" ;; esac
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
case "$ALLOW_DIRTY" in 0|1) ;; *) die "ALLOW_DIRTY must be 0 or 1" ;; esac

[ "$(id -u)" -ne 0 ] || die "do not run as root"
if [ -n "${SIGN_ID:-}" ] && [ "$SIGN_ID" != "-" ]; then
  die "a release is always signed ad hoc; unset SIGN_ID (see docs/DEVELOPMENT.md, Release)"
fi
for tool in ditto codesign nm plutil shasum unzip npm npx; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

# Runs a command, or prints it in --dry-run mode.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '    $'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

human_size() {
  awk -v b="$1" 'BEGIN { split("B KB MB GB", u, " "); i = 1
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'
}

# --- Working tree --------------------------------------------------------------------------------------------
# The assets come from the working tree. A clean tree ties them to the commit you tag. No optional locks: the check
# leaves the git index alone.
if ! TREE_STATUS="$(git --no-optional-locks -C "$PKG" status --porcelain 2>/dev/null)"; then
  [ "$ALLOW_DIRTY" = "1" ] || die "cannot read the git status of the package (ALLOW_DIRTY=1 builds anyway)"
  COMMIT="unknown commit"
elif [ -n "$TREE_STATUS" ]; then
  [ "$ALLOW_DIRTY" = "1" ] ||
    die "the working tree has uncommitted or untracked files. Commit them first, so the assets match a commit (ALLOW_DIRTY=1 builds anyway)."
  COMMIT="$(git -C "$PKG" rev-parse --short HEAD 2>/dev/null || echo unknown) with uncommitted changes"
else
  COMMIT="$(git -C "$PKG" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

# --- Version -------------------------------------------------------------------------------------------------
# The same source as bundle.sh: $VERSION, else the VERSION file, else 0.1.0. A release needs all three parts.
if [ -z "${VERSION:-}" ]; then
  VERSION="0.1.0"
  if [ -f "$PKG/VERSION" ]; then VERSION="$(tr -d '[:space:]' < "$PKG/VERSION")"; fi
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must look like 1.2.3, not '$VERSION'"
MANIFEST="$STREAMDECK/$SD_PLUGIN/manifest.json"
[ -f "$MANIFEST" ] || die "missing $MANIFEST"
MANIFEST_VERSION="$(plutil -extract Version raw -o - "$MANIFEST" 2>/dev/null)" || die "manifest.json has no Version"
[ "$MANIFEST_VERSION" = "$VERSION.0" ] ||
  die "manifest.json Version is $MANIFEST_VERSION, but the release is $VERSION (expected $VERSION.0)"

ZIP_NAME="AC-Voice-$VERSION.zip"
PLUGIN_NAME="$PLUGIN_UUID.streamDeckPlugin"
SUMS_NAME="SHA256SUMS.txt"

# --- Output directory ----------------------------------------------------------------------------------------
# It holds exactly the files to upload. Other files stop the run; the release files of this version need --force.
# Finder writes a .DS_Store when you open the folder. It does not count, because the upload names each file.
# Nothing in it changes before the last step.
[ ! -e "$OUT" ] || [ -d "$OUT" ] || die "$OUT_SHOWN exists and is not a directory"
if [ -d "$OUT" ]; then
  others=""; existing=""
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    case "$name" in
      "$ZIP_NAME"|"$PLUGIN_NAME"|"$SUMS_NAME") existing="$existing $name" ;;
      .DS_Store) ;;
      *) others="$others $name" ;;
    esac
  done < <(find "$OUT" -mindepth 1 -maxdepth 1 -print0)
  [ -z "$others" ] || die "$OUT_SHOWN holds other files:$others. Remove them or choose another --out."
  if [ -n "$existing" ] && [ "$FORCE" = "0" ]; then
    die "$OUT_SHOWN already holds$existing. Pass --force to replace them."
  fi
fi

# --- Leak guard ----------------------------------------------------------------------------------------------
[ -n "${HOME:-}" ] && [ "$HOME" != "/" ] || die "HOME is not set"
# One line per value: grep flags, the kind of value, the value. Messages name the kind, never the value.
NEEDLES=""
add_needle() { [ -z "$3" ] || NEEDLES="$NEEDLES$1"$'\t'"$2"$'\t'"$3"$'\n'; }
add_needle F "the package path" "$PKG"
add_needle F "the home path" "$HOME"
add_needle iF "the login name" "$(id -un)"
add_needle iF "the login name" "$(basename "$HOME")"
# The GitHub noreply address may appear in public files; its domain is GitHub's.
while IFS= read -r email; do
  add_needle iF "a git email address" "$email"
  case "$email" in
    *@users.noreply.github.com) ;;
    *@?*) add_needle iF "the domain of a git email address" "${email##*@}" ;;
  esac
done <<< "$( { git -C "$PKG" config user.email || true; git config --global user.email || true; } 2>/dev/null)"
NEEDLES="$(printf '%s' "$NEEDLES" | sort -u)"

# Every regular file below $1 that contains one of the values. Prints the file (relative to $1) and the kind of value,
# never the value. A read error (grep exit 2) counts as a hit. Returns 1 on a hit.
leak_check() {
  local root="$1" file rel hit=0 flags kind value rc
  while IFS= read -r -d '' file; do
    rel="${file#"$root"/}"
    while IFS=$'\t' read -r flags kind value; do
      [ -n "$value" ] || continue
      rc=0; grep -aq"$flags" -- "$value" "$file" 2>/dev/null || rc=$?
      if [ "$rc" = "0" ]; then
        echo "release.sh: leak: $rel contains $kind" >&2; hit=1
      elif [ "$rc" != "1" ]; then
        echo "release.sh: leak guard cannot read $rel" >&2; hit=1; break
      fi
    done <<< "$NEEDLES"
  done < <(find "$root" -type f -print0)
  return "$hit"
}

# --- Run -----------------------------------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  say "dry run, nothing changes"
  WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/acvoice-release.XXXXXXXX"
else
  WORK="$(mktemp -d -t acvoice-release)"
  trap 'rm -rf "$WORK"' EXIT
fi
APP_DIR="$WORK/app"
APP="$APP_DIR/$APP_NAME.app"
STAGE="$WORK/out"
run mkdir -p "$STAGE"

# 1. App ---------------------------------------------------------------------------------------------------------
say "1/6 build and sign the app ad hoc, version $VERSION, commit $COMMIT"
BUNDLE_ENV=(SIGN_ID=- EMBED_SOURCE_ROOT=0 CONFIG=release HARDENED=1 VERSION="$VERSION" OUT="$APP_DIR")
if [ "$DRY_RUN" = "1" ]; then
  printf '    $ env -u SIGN_KEYCHAIN'; printf ' %q' "${BUNDLE_ENV[@]}" "$PKG/scripts/bundle.sh"
  printf ' > %q 2>&1\n' "$WORK/bundle.log"
elif ! env -u SIGN_KEYCHAIN "${BUNDLE_ENV[@]}" "$PKG/scripts/bundle.sh" > "$WORK/bundle.log" 2>&1; then
  # The EXIT trap removes $WORK, so a copy of the log stays for the full output.
  KEPT_LOG="${TMPDIR:-/tmp}"; KEPT_LOG="${KEPT_LOG%/}/acvoice-release-bundle.log"
  cp "$WORK/bundle.log" "$KEPT_LOG"
  {
    echo "--- first errors"
    grep -m 5 'error:' "$WORK/bundle.log" || echo "(none)"
    echo "--- end of the log"
    tail -n 40 "$WORK/bundle.log"
  } >&2
  die "bundle.sh failed (see above). The full log is in $KEPT_LOG."
fi

# 2. Check the app -----------------------------------------------------------------------------------------------
say "2/6 check the app: strict signature, ad hoc, no team, hardened runtime, no ACVoiceSourceRoot, no debug map"
if [ "$DRY_RUN" = "0" ]; then
  [ -d "$APP" ] || die "bundle.sh produced no app"
  codesign --verify --strict "$APP" || die "the app's signature does not verify"
  SIG_INFO="$(codesign -dv "$APP" 2>&1)"
  grep -qx 'Signature=adhoc' <<< "$SIG_INFO" || die "the app is not signed ad hoc"
  TEAM="$(grep '^TeamIdentifier=' <<< "$SIG_INFO" || true)"
  [ -z "$TEAM" ] || [ "$TEAM" = "TeamIdentifier=not set" ] || die "the app's signature names a team"
  grep -q '^CodeDirectory .*flags=.*runtime' <<< "$SIG_INFO" || die "the app lacks the hardened runtime"
  if plutil -extract ACVoiceSourceRoot raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    die "Info.plist contains ACVoiceSourceRoot"
  fi
  STABS="$(nm -ap "$APP/Contents/MacOS/$APP_NAME" | awk '$2 == "-" && ($5 == "OSO" || $5 == "SO")' | wc -l | tr -d ' ')"
  [ "$STABS" = "0" ] || die "the executable still has $STABS OSO/SO debug entries (strip -S did not run)"
fi

# 3. Zip -------------------------------------------------------------------------------------------------------
say "3/6 zip the app and verify an unpacked copy"
run /usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$STAGE/$ZIP_NAME"
run mkdir -p "$WORK/unzipped-app"
run /usr/bin/ditto -x -k "$STAGE/$ZIP_NAME" "$WORK/unzipped-app"
run codesign --verify --strict --deep "$WORK/unzipped-app/$APP_NAME.app"
# Listings go through a variable. With pipefail, a grep -q that ends a pipe early hides a hit when the writer
# gets SIGPIPE.
if [ "$DRY_RUN" = "0" ]; then
  ZIP_LIST="$(unzip -Z1 "$STAGE/$ZIP_NAME")"
  if grep -qv "^$APP_NAME\.app/" <<< "$ZIP_LIST"; then
    die "$ZIP_NAME holds files outside \"$APP_NAME.app/\""
  fi
fi

# 4. Plugin ----------------------------------------------------------------------------------------------------
say "4/6 build, validate and pack the Stream Deck plugin"
run cd "$STREAMDECK"
if [ -d "$STREAMDECK/node_modules" ]; then
  say "    node_modules present, skipping npm ci"
else
  run npm ci
fi
run npm run build
run npm run validate
# streamdeck pack (CLI 1.10.4) writes the manifest.json of the folder it packs back, re-serialized, and keeps that
# file. So it packs a copy, and the tracked manifest stays as it is. The copy keeps the folder name the CLI checks.
run mkdir -p "$WORK/pack-src" "$WORK/plugin"
run cp -R "$STREAMDECK/$SD_PLUGIN" "$WORK/pack-src/"
run npx --no-install streamdeck pack --no-update-check --output "$WORK/plugin" "$WORK/pack-src/$SD_PLUGIN"
run cd "$PKG"
if [ "$DRY_RUN" = "0" ]; then
  [ -f "$WORK/plugin/$PLUGIN_NAME" ] || die "streamdeck pack produced no $PLUGIN_NAME"
  # .sdignore keeps logs and Finder files out; this checks the result.
  PLUGIN_LIST="$(unzip -Z1 "$WORK/plugin/$PLUGIN_NAME")"
  if grep -Eq '(^|/)logs/|\.log$|\.DS_Store$|\.js\.map$' <<< "$PLUGIN_LIST"; then
    die "$PLUGIN_NAME contains logs, .DS_Store or source maps (check $SD_PLUGIN/.sdignore)"
  fi
  cp "$WORK/plugin/$PLUGIN_NAME" "$STAGE/$PLUGIN_NAME"
fi
run mkdir -p "$WORK/unzipped-plugin"
run unzip -q "$STAGE/$PLUGIN_NAME" -d "$WORK/unzipped-plugin"

# 5. Leak guard ------------------------------------------------------------------------------------------------
say "5/6 leak guard: package path, home path, login name and git email in the app and the plugin package"
if [ "$DRY_RUN" = "0" ]; then
  LEAKS=0
  leak_check "$WORK/unzipped-app" || LEAKS=1
  leak_check "$WORK/unzipped-plugin" || LEAKS=1
  [ "$LEAKS" = "0" ] || die "personal data in the release files (listed above); nothing was written to $OUT_SHOWN"
fi

# 6. Checksums and output --------------------------------------------------------------------------------------
say "6/6 write $SUMS_NAME and move the files to $OUT_SHOWN"
if [ "$DRY_RUN" = "1" ]; then
  printf '    $ cd %q && shasum -a 256 %q %q > %q\n' "$STAGE" "$ZIP_NAME" "$PLUGIN_NAME" "$SUMS_NAME"
else
  (cd "$STAGE" && shasum -a 256 "$ZIP_NAME" "$PLUGIN_NAME" > "$SUMS_NAME")
fi
run mkdir -p "$OUT"
# The files first go to a staging folder in $OUT, on the same volume, which may take a while. Then each one gets its
# final name by rename, which replaces an older file of the same name in one step.
if [ "$DRY_RUN" = "1" ]; then
  INCOMING="$OUT/.incoming.XXXXXX"
  printf '    $ mktemp -d %q\n' "$INCOMING"
else
  INCOMING="$(mktemp -d "$OUT/.incoming.XXXXXX")"
  trap 'rm -rf "$WORK" "$INCOMING"' EXIT
fi
for name in "$ZIP_NAME" "$PLUGIN_NAME" "$SUMS_NAME"; do run mv "$STAGE/$name" "$INCOMING/$name"; done
for name in "$ZIP_NAME" "$PLUGIN_NAME" "$SUMS_NAME"; do run mv -f "$INCOMING/$name" "$OUT/$name"; done
run rmdir "$INCOMING"
[ "$DRY_RUN" = "0" ] || exit 0

echo
echo "release:  $VERSION (ad hoc, not notarized)"
echo "commit:   $COMMIT"
echo "folder:   $OUT_SHOWN"
for name in "$ZIP_NAME" "$PLUGIN_NAME" "$SUMS_NAME"; do
  printf '  %-56s %s\n' "$name" "$(human_size "$(stat -f %z "$OUT/$name")")"
done
echo "plugin:   $(unzip -Z1 "$OUT/$PLUGIN_NAME" | grep -vc '/$') files"
echo "sha256:"
sed 's/^/  /' "$OUT/$SUMS_NAME"
echo
echo "Nothing is uploaded. To publish, tag this commit as v$VERSION, push the tag and run gh release create with"
echo "these three files (docs/DEVELOPMENT.md, Release)."
