# Development

How AC Voice is built, tested and packaged. For setup and daily use see the [README](../README.md). Architecture, decisions and milestones: [PLAN.md](PLAN.md).

## Modules

SwiftPM package, no Xcode project:

| Module | Content |
|---|---|
| `ACVoiceCore` | text normalization, parser with an English and a German lexicon, resolver, ticket resolver, IPC codec, config (pure logic) |
| `ACVoiceFlow` | voice flow as a pure reducer (`FlowEvent` → `[Effect]`), overlay model, UI texts in English and German |
| `ACVoiceAC` | GET-only ActiveCollab client, index store, Keychain token store, sign-in (`ACTokenIssuer`, the only write) |
| `ACVoiceSpeech` | microphone and file sources, SpeechAnalyzer session, end-of-utterance gate, contextual strings |
| `ACVoiceUI` | overlay panel and SwiftUI views |
| `ACVoiceSystem` | Chrome opener, IPC server, hotkey, earcons, login item |
| `ACVoiceRuntime` | controller that runs the flow's effects against the real services |
| `ACVoiceApp` | the "AC Voice" executable |

## Build and test

```sh
swift build
swift test
```

The tests run headless. They never start the microphone, play sound, send Apple Events, show windows or touch the Keychain. System services sit behind protocols and the tests use fakes. The ActiveCollab client and the sign-in run against an in-process stub server (`StubURLProtocol`), so no request leaves the process. Tests in `Tests/Fixtures/private` (git-ignored) run against the real project names when present.

When several checkouts or agents build at once, give each its own scratch path: `swift build --scratch-path /tmp/acvoice-build`.

A bare `swift run ACVoiceApp` has no Info.plist, so macOS attributes permissions to Terminal. Use `scripts/bundle.sh` or `scripts/install.sh` for anything that needs the microphone or Chrome.

The app is a thin shell (`ACVoiceApp`: `main.swift`, `AppDelegate.swift`) around `ACVoiceRuntime`:

- `Controller` owns the `VoiceFlow` state and runs every effect against `Services` (speech, index, token, permissions, overlay, IPC, Chrome, earcons, hotkey, login item, clock, files). All of them are protocols; `LiveServices.swift` holds the real ones, the tests use fakes and a fake clock.
- `AppCoordinator` adds the status item, the setup window, the URL scheme, the overlay demo and the SIGTERM handler.
- Logs use the subsystem `io.github.nordavid.acvoice`. Flow events and effects appear as names only, transcripts as `<private>`. Signposts (category `flow`): `pressToMicReady`, `speechEndToFinal`, `finalToOpened`.

## Languages

AC Voice runs in English or German (`AppLanguage`). `Config.language` (`"auto"`, `"de"`, `"en"`) picks it, and `"auto"` gives German when the first macOS language is German, else English. `Controller` resolves it once at launch from the config and `Services.preferredLanguages`. A change needs a restart.

There is no global language state. The language travels explicitly: `Controller.language`, `FlowEnv.language` (texts and the live rules of the flow), `Interpreter.language` (parser and resolver), the `language:` parameters of `ContextBuilder`, `HangoverPolicy`, `Parser.looksIncomplete` and `SpeechSelfCheck`, and the speech locale of `VoiceSession`. So tests in both languages run in parallel. German stays the default everywhere, and the test `Rig` passes `preferredLanguages: ["de-DE"]`; an English rig passes `["en-US"]`.

- Voice commands: `Lexicon.de` and `Lexicon.en` hold the fillers, task words, cancel and closing phrases, ordinals and lookalike digits. Project codes and titles stay the AC names in both languages.
- UI texts: `FlowText`, `OverlayText` and `AppText` keep both languages side by side. Texts of other modules arrive in German and `AppText.localized` maps them.
- The Stream Deck plugin gets the language as `lang` in every IPC v1 state, from the launch snapshot on.
- The macOS permission prompts come from `Resources/de.lproj` and `Resources/en.lproj` (`InfoPlist.strings`) and follow the macOS language, not `Config.language`. The development region is English.

Tests in both languages. The test modules of Core, Flow, Speech, UI and Runtime have English suites (`English…Tests`) next to the German ones. `EnglishAppTextTests` also checks the English texts of ACVoiceSystem. A plain `swift test` runs both. `swift test --filter English` runs the English suites. They cover the lexicon, numbers, spelled codes, selection and hangover rules, the flow texts, the overlay views, the app texts and full scenarios on an English rig. `EnglishInterpreterTests` checks that each English command gives the same result as its German counterpart, so the German suites stay the reference.

## Opt-in speech tests

These feed TTS clips through the real speech pipeline (file input, no microphone, no prompt):

```sh
scripts/make-tts-fixtures.sh                 # German clips into Tests/Fixtures/tts (git-ignored) with `say`
scripts/make-tts-fixtures.sh --lang en       # English clips (Samantha, en_US) into Tests/Fixtures/tts-en (git-ignored)
ACVOICE_SPEECH_TESTS=1 swift test --filter SpeechEndToEndTests                         # both languages, one after another
ACVOICE_SPEECH_TESTS=1 swift test --filter "SpeechEndToEnd/SpeechEndToEndTests"        # German only
ACVOICE_SPEECH_TESTS=1 swift test --filter EnglishSpeechEndToEndTests                  # English only
```

The clips use the fantasy codes of `Tests/Fixtures/projects.sample.json`. The summary prints how often each transcriber heard the spoken code exactly (`code heard exactly: DT x/n, ST y/n`).

- German clips. Anna (de_DE) speaks the commands and answers. When Daniel (en_GB) is installed, the script adds mixed clips: the German part by Anna, English loanwords such as "Relaunch" by Daniel.
- English clips. Samantha (en_US) speaks the English commands and answers ("Open the WWT project", "What's on my plate", "Never mind", "the second one", "no, the second"). The ids match the German clips where the request is the same. Project codes and German title words stay as written in AC, because an English speaker says them too. The suite reports the clips with German title words (c04, c14, c15) and does not assert them.
- The English suite (`EnglishSpeechEndToEndTests`) runs the en_US model with English contextual strings, the English interpreter and the English hangover rules, with the same structure and budgets as the German suite. macOS downloads the en_US speech model on first use.
- Without clips a suite fails and names the script call that creates them.

Private speech check. The same suite also runs on clips with the real project codes against the real project list. Both stay in the git-ignored `Tests/Fixtures/private`:

- `tts-phrases.tsv`: lines `id<TAB>kind<TAB>text`, and `id<TAB>kind<TAB>german<TAB>english` for the mixed clips (`-` for an empty German part). Use the ids of the built-in phrases (c01 lists the projects the answer clips pick from).
- `tts-phrases-en.tsv`: the English phrases for `--lang en`, lines `id<TAB>kind<TAB>text` with the same ids.
- `projects.json`: the real list in the format of `projects.sample.json`, with the signals and the spoken aliases (for example a code that STT hears as a German word).

```sh
scripts/make-tts-fixtures.sh --private             # writes Tests/Fixtures/private/tts
scripts/make-tts-fixtures.sh --private --lang en   # English: tts-phrases-en.tsv into Tests/Fixtures/private/tts-en
ACVOICE_SPEECH_TESTS=1 ACVOICE_E2E_PRIVATE=1 swift test --filter SpeechEndToEndTests
```

`ACVOICE_TTS_DIR` (English: `ACVOICE_TTS_EN_DIR`) and `ACVOICE_E2E_PROJECTS` (`.json` or `.tsv`, relative to the repository root) set the paths directly. For single clips, `acvoice-transcribe <clip> --realtime --projects <list> --alias CODE=word [--lang en]` does the same without the test runner.

Variables: `ACVOICE_CONTEXT_LIMIT=<n>` sets the number of contextual strings, `ACVOICE_CONTEXT_SWEEP=1` compares several sizes (about 4 minutes), `ACVOICE_SPEECH_DEBUG=1` prints the gate and analyzer events.

## Dev CLIs

`acvoice-resolve` and `acvoice-index` print ids, counts and timings only, never project names or secrets. `acvoice-transcribe` also prints what the transcribers heard, so its output holds project names. Do not share it from private clips.

```sh
# Resolver against a project list (tsv "id<TAB>name" or the JSON fixture format)
swift run acvoice-resolve Tests/Fixtures/projects.sample.json "Öffne WWT Relaunch"
swift run acvoice-resolve Tests/Fixtures/projects.sample.json --lang en "Open WWT Relaunch"
swift run acvoice-resolve Tests/Fixtures/private/project_names.tsv --cases Tests/Fixtures/private/regression.tsv

# AC index (GET only; token from the environment variable AC_TOKEN, never from the Keychain)
read -rs AC_TOKEN && export AC_TOKEN   # paste an API token of your own account; it stays out of the shell history
swift run acvoice-index refresh --stats                                     # address from the app's config.json
swift run acvoice-index --base-url https://ac.example.test refresh --stats  # or given explicitly
swift run acvoice-index resolve "Öffne WWT Ticket 412" --url

# Speech pipeline on audio files (no microphone)
swift run acvoice-transcribe Tests/Fixtures/tts/anna_c02.aiff --realtime
swift run acvoice-transcribe Tests/Fixtures/tts-en/samantha_c02.aiff --realtime --lang en
```

`--lang en` (default `de`) picks the language of the utterances in `acvoice-resolve` and `acvoice-transcribe`. A regression case file switches with a line `@language en` (and back with `@language de`); with `--lang en` it starts in English. `acvoice-index resolve` has no `--lang` and reads German commands only.

Overlay snapshots render every overlay state to PNG without showing a window:

```sh
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay                    # <state>-<light|dark>.png at 2x
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay --only choices,error
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay --variants         # also -contrast, -solid, -still
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay-en --lang en       # the English gallery (own folder)
```

The output folder is the first argument and is created when missing. The states are the 29 scenarios of `OverlayGallery`, starting with the most frequent one (listening-ready, listening-starting, listening-cold, listening-partial, listening-long, processing, processing-search, choices, choices-answer, choices-held, choices-more, choices-page2, choices-narrowed, choices-unclear, choices-nomore, choices-long-titles, choices-confirm, choices-tickets, choices-ticket-chips, retry, retry-nothing, opening, success, success-long, success-hint, error, error-offline, error-mic, error-nothing). `--variants` adds renders with Increase Contrast (`-contrast`), Reduce Transparency (`-solid`) and Reduce Motion (`-still`). Glass cannot render offscreen, so the PNGs show a stand-in backdrop.

The same states run live in the app: Menu > Diagnostics > "Show Overlay Demo" ("Overlay vorführen") once, or in a loop with the launch argument `--demo` (no microphone, AC, Chrome, hotkey or socket; quit the running AC Voice first, or start a second copy with `open -n "$HOME/Applications/AC Voice.app" --args --demo`). Both start with a scripted command through the real flow and its real timings, so the fade-in, the spring, the row stagger, the 0.7 s success and the fade-out look as they do in use.

## Stream Deck plugin

```sh
cd streamdeck
npm run check   # typecheck, unit tests, build, manifest validation, end-to-end test against a fake Stream Deck host
npm run watch   # rebuild on change and restart the plugin in the Stream Deck app
```

## Packaging

```sh
scripts/bundle.sh                              # release build, signed, dist/AC Voice.app
SIGN_ID=- OUT=/tmp/acvoice-dist scripts/bundle.sh   # ad hoc, for CI-like checks only
scripts/bundle.sh --help                       # all options
```

`bundle.sh` builds the `ACVoiceApp` product and assembles `AC Voice.app`:

- `Contents/MacOS/AC Voice`, `Contents/Info.plist` from `Resources/Info.plist.in` (version from the `VERSION` file, else 0.1.0, build number from the UTC time), `Contents/Resources/AppIcon.icns`, `Contents/Resources/de.lproj` and `en.lproj` (the permission prompts per macOS language, from `Resources/*.lproj/InfoPlist.strings`) and the SwiftPM resource bundles of the app's targets.
- Hardened runtime with `Resources/ACVoice.entitlements` (`com.apple.security.device.audio-input`, `com.apple.security.automation.apple-events`). No sandbox.
- Signs with `SIGN_ID`, else the first valid "Apple Development" identity, after an OCSP revocation check. `SIGN_ID=-` signs ad hoc and skips the check.
- Ends with `codesign --verify --strict` and prints the designated requirement. It never launches the app.

The app icon comes from `scripts/make-icon.swift` (CoreGraphics, macOS app icon grid). After a design change:

```sh
swift scripts/make-icon.swift --preview /tmp/acvoice-icon.png
```

It writes `Resources/AppIcon.icns`. Commit the result. The build does not run the script.
