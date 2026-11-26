#!/bin/bash
# Generates TTS clips for the opt-in ACVoiceSpeech end-to-end tests.
# Output: Tests/Fixtures/tts (German) or Tests/Fixtures/tts-en (English), both git-ignored, with one AIFF per clip
# and manifest.tsv. Uses only `say` with file output: no microphone, no sound output, no permission prompt.
#
#   scripts/make-tts-fixtures.sh                 # Anna (de_DE) plus Daniel (en_GB) for the mixed clips
#   scripts/make-tts-fixtures.sh --all-voices    # every installed de_ voice (low-fidelity voices transcribe poorly)
#   scripts/make-tts-fixtures.sh --voices "Anna Flo"
#   scripts/make-tts-fixtures.sh --lang en       # English commands by Samantha (en_US) into Tests/Fixtures/tts-en
#   scripts/make-tts-fixtures.sh --private       # phrases from Tests/Fixtures/private/tts-phrases.tsv
#                                                # into Tests/Fixtures/private/tts (both git-ignored); with
#                                                # --lang en from tts-phrases-en.tsv into private/tts-en
#
# manifest.tsv columns: id, voice, kind (command|answer), files ("+" joins parts played back to back), text.
# The text is the ground truth: the tests compare the interpretation of the clip with the interpretation of it.
# The built-in phrases use the fantasy codes of Tests/Fixtures/projects.sample.json. --private reads lines
# "id<TAB>kind<TAB>text" with real project names, and "id<TAB>kind<TAB>german<TAB>english" for mixed clips ("-" for no
# German part), for the
# private speech check (docs/DEVELOPMENT.md):
#   ACVOICE_SPEECH_TESTS=1 ACVOICE_E2E_PRIVATE=1 swift test --filter SpeechEndToEndTests
# The English clips run in EnglishSpeechEndToEndTests (same filter). Fantasy codes and German title words stay as
# they are: they are AC names, an English speaker says them too.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VOICES=""
ALL=0
PRIVATE=0
OUT=""
LANG_CODE="de"
while [ $# -gt 0 ]; do
  case "$1" in
    --all-voices) ALL=1 ;;
    --voices) shift; VOICES="$1" ;;
    --out) shift; OUT="$1" ;;
    --private) PRIVATE=1 ;;
    --lang) shift; LANG_CODE="$1" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$LANG_CODE" in
  de) LOCALE_RE='de_[A-Z]{2}'; DEFAULT_VOICE="Anna"; SUFFIX="" ;;
  en) LOCALE_RE='en_US'; DEFAULT_VOICE="Samantha"; SUFFIX="-en" ;;
  *) echo "unknown language: $LANG_CODE (de or en)" >&2; exit 2 ;;
esac
if [ -z "$OUT" ]; then
  if [ $PRIVATE -eq 1 ]; then OUT="$ROOT/Tests/Fixtures/private/tts$SUFFIX"; else OUT="$ROOT/Tests/Fixtures/tts$SUFFIX"; fi
fi

with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# Installed voices of the language, one name per line ("Anna", "Eddy (Deutsch (Deutschland))", "Samantha", ...).
INSTALLED=$(with_timeout 30 say -v '?' | grep -E "[[:space:]]${LOCALE_RE}[[:space:]]" | sed -E "s/[[:space:]]+${LOCALE_RE}[[:space:]].*\$//")
if [ -z "$INSTALLED" ]; then echo "no $LANG_CODE voice installed (say -v '?' | grep -E '$LOCALE_RE')" >&2; exit 1; fi
if [ $ALL -eq 1 ]; then
  LIST="$INSTALLED"
elif [ -n "$VOICES" ]; then
  LIST=$(printf '%s\n' $VOICES)
elif printf '%s\n' "$INSTALLED" | grep -qx "$DEFAULT_VOICE"; then
  LIST="$DEFAULT_VOICE"
else
  LIST=$(printf '%s\n' "$INSTALLED" | head -1)
fi
ENGLISH=""
if [ "$LANG_CODE" = de ] && with_timeout 30 say -v '?' | grep -qE '^Daniel[[:space:]]+en_GB'; then ENGLISH="Daniel"; fi

# id|kind|text ([[slnc N]] inserts N ms of silence and is not part of the ground truth).
PHRASES=(
  "c01|command|Öffne das WWT-Projekt"
  "c02|command|Öffne WWT Relaunch"
  "c03|command|Öffne das S+K Leasing Cockpit"
  "c04|command|Öffne TKZ Touren Planer"
  "c05|command|Öffne WWT Ticket 412"
  "c06|command|Öffne Ticket 47285"
  "c07|command|Zeig meine Aufgaben"
  "c13|command|Grand Navigation"
  "c14|command|IBN Betreuung"
  "c15|command|BDG Pilzdatenbank"
  "a08|answer|eins"
  "a09|answer|zwei"
  "a10|answer|drei"
  "a11|answer|die zweite"
  "a12|answer|Relaunch"
  "a16|answer|nein, die zweite"
  "s01|command|[[slnc 1000]] Öffne WWT Relaunch"
  "s02|command|Öffne das WWT-Projekt [[slnc 1500]]"
  "s03|command|Öffne [[slnc 700]] WWT Relaunch"
  "s04|command|Öffne WWT Ticket [[slnc 700]] 412"
  "s05|command|Zeig mir das [[slnc 700]] WWT-Projekt"
  "s06|answer|[[slnc 800]] zwei"
)
# Mixed clips: German part by the German voice, English loanwords by Daniel (id|kind|german|english).
MIXED=(
  "m01|command|Öffne WWT|Relaunch"
  "m02|command|Öffne das S und K|Leasing Cockpit"
  "m03|answer||Relaunch"
)

# English commands by an English voice. The ids match the German clips where the request is the same; c14 and c15
# keep their German title words (AC names).
if [ "$LANG_CODE" = en ]; then
  PHRASES=(
    "c01|command|Open the WWT project"
    "c02|command|Open WWT Relaunch"
    "c03|command|Open the S and K Leasing Cockpit"
    "c04|command|Open TKZ Touren Planer"
    "c05|command|Open WWT ticket 412"
    "c06|command|Open ticket 47285"
    "c07|command|Show my tasks"
    "c08|command|What's on my plate"
    "c09|command|Ticket 412 in WWT Relaunch"
    "c10|command|Never mind"
    "c11|command|Open ticket four twelve"
    "c12|command|Ticket four twelve in WWT Relaunch"
    "c13|command|Grand Navigation"
    "c14|command|IBN Betreuung"
    "c15|command|BDG Pilzdatenbank"
    "a08|answer|one"
    "a09|answer|two"
    "a10|answer|three"
    "a11|answer|the second one"
    "a12|answer|Relaunch"
    "a13|answer|number two"
    "a16|answer|no, the second"
    "s01|command|[[slnc 1000]] Open WWT Relaunch"
    "s02|command|Open the WWT project [[slnc 1500]]"
    "s03|command|Open [[slnc 700]] WWT Relaunch"
    "s04|command|Open WWT ticket [[slnc 700]] 412"
    "s05|command|Show me the [[slnc 700]] WWT project"
    "s06|answer|[[slnc 800]] two"
  )
  MIXED=()
fi

if [ $PRIVATE -eq 1 ]; then
  if [ "$LANG_CODE" = en ]; then LIST_FILE="$ROOT/Tests/Fixtures/private/tts-phrases-en.tsv"; else LIST_FILE="$ROOT/Tests/Fixtures/private/tts-phrases.tsv"; fi
  [ -f "$LIST_FILE" ] || { echo "missing $LIST_FILE (lines: id<TAB>kind<TAB>text)" >&2; exit 1; }
  PHRASES=()
  MIXED=()
  while IFS=$'\t' read -r id kind text english; do
    case "$id" in ''|'#'*) continue ;; esac
    # Mixed clip: "-" stands for an empty German part (tabs in a row collapse when bash splits the line).
    if [ -n "${english:-}" ]; then MIXED+=("$id|$kind|${text#-}|$english"); else PHRASES+=("$id|$kind|$text"); fi
  done < "$LIST_FILE"
  [ ${#PHRASES[@]} -gt 0 ] || { echo "no phrases in $LIST_FILE" >&2; exit 1; }
fi

slug() { printf '%s' "$1" | sed -E 's/ .*//' | tr '[:upper:]' '[:lower:]'; }
truth() { printf '%s' "$1" | sed -E 's/\[\[[^]]*\]\]//g; s/  +/ /g; s/^ //; s/ $//'; }

mkdir -p "$OUT"
MANIFEST="$OUT/manifest.tsv"
printf '# id\tvoice\tkind\tfiles\ttext\n' > "$MANIFEST"
count=0
while IFS= read -r voice; do
  [ -z "$voice" ] && continue
  s=$(slug "$voice")
  for entry in "${PHRASES[@]}"; do
    IFS='|' read -r id kind text <<< "$entry"
    file="${s}_${id}.aiff"
    with_timeout 60 say -v "$voice" -o "$OUT/$file" -- "$text"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$voice" "$kind" "$file" "$(truth "$text")" >> "$MANIFEST"
    count=$((count + 1))
  done
  if [ -n "$ENGLISH" ] && [ ${#MIXED[@]} -gt 0 ]; then
    for entry in "${MIXED[@]}"; do
      IFS='|' read -r id kind german english <<< "$entry"
      files=""
      if [ -n "$german" ]; then
        with_timeout 60 say -v "$voice" -o "$OUT/${s}_${id}_1.aiff" -- "$german"
        files="${s}_${id}_1.aiff+"
      fi
      with_timeout 60 say -v "$ENGLISH" -o "$OUT/${s}_${id}_2.aiff" -- "$english"
      files="${files}${s}_${id}_2.aiff"
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$voice+$ENGLISH" "$kind" "$files" "$(truth "$german $english")" >> "$MANIFEST"
      count=$((count + 1))
    done
  fi
done <<< "$LIST"
echo "wrote $count clips to $OUT (voices: $(printf '%s' "$LIST" | tr '\n' ',' | sed 's/,$//')${ENGLISH:+, mixed with $ENGLISH})"
