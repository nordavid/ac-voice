# Development

How AC Voice is built, tested and packaged. For setup and daily use see the [README](../README.md). Architecture, decisions and milestones: [PLAN.md](PLAN.md).

## Modules

SwiftPM package, no Xcode project:

| Module | Content |
|---|---|
| `ACVoiceCore` | text normalization, parser, resolver, ticket resolver, IPC codec, config (pure logic) |
| `ACVoiceFlow` | voice flow as a pure reducer (`FlowEvent` → `[Effect]`), overlay model, German UI texts |
| `ACVoiceAC` | GET-only ActiveCollab client, index store, Keychain token store, ac-mcp importer |
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

The tests run headless. They never start the microphone, play sound, send Apple Events, show windows or touch the Keychain. System services sit behind protocols and the tests use fakes. Tests in `Tests/Fixtures/private` (git-ignored) run against the real project names when present.

When several checkouts or agents build at once, give each its own scratch path: `swift build --scratch-path /tmp/acvoice-build`.

A bare `swift run ACVoiceApp` has no Info.plist, so macOS attributes permissions to Terminal. Use `scripts/bundle.sh` or `scripts/install.sh` for anything that needs the microphone or Chrome.

The app is a thin shell (`ACVoiceApp`: `main.swift`, `AppDelegate.swift`) around `ACVoiceRuntime`:

- `Controller` owns the `VoiceFlow` state and runs every effect against `Services` (speech, index, token, permissions, overlay, IPC, Chrome, earcons, hotkey, login item, clock, files). All of them are protocols; `LiveServices.swift` holds the real ones, the tests use fakes and a fake clock.
- `AppCoordinator` adds the status item, the setup window, the URL scheme, the overlay demo and the SIGTERM handler.
- Logs use the subsystem `io.github.nordavid.acvoice`. Flow events and effects appear as names only, transcripts as `<private>`. Signposts (category `flow`): `pressToMicReady`, `speechEndToFinal`, `finalToOpened`.

## Opt-in speech tests

These feed German TTS clips through the real speech pipeline (file input, no microphone, no prompt):

```sh
scripts/make-tts-fixtures.sh                 # writes Tests/Fixtures/tts (git-ignored) with `say`
ACVOICE_SPEECH_TESTS=1 swift test --filter ACVoiceSpeechTests
```

The clips use the fantasy codes of `Tests/Fixtures/projects.sample.json`. The summary prints how often each transcriber heard the spoken code exactly (`code heard exactly: DT x/n, ST y/n`).

Private speech check. The same suite also runs on clips with the real project codes against the real project list. Both stay in the git-ignored `Tests/Fixtures/private`:

- `tts-phrases.tsv`: lines `id<TAB>kind<TAB>text`, and `id<TAB>kind<TAB>german<TAB>english` for the mixed clips (`-` for an empty German part). Use the ids of the built-in phrases (c01 lists the projects the answer clips pick from).
- `projects.json`: the real list in the format of `projects.sample.json`, with the signals and the spoken aliases (for example a code that STT hears as a German word).

```sh
scripts/make-tts-fixtures.sh --private       # writes Tests/Fixtures/private/tts
ACVOICE_SPEECH_TESTS=1 ACVOICE_E2E_PRIVATE=1 swift test --filter SpeechEndToEndTests
```

`ACVOICE_TTS_DIR` and `ACVOICE_E2E_PROJECTS` (`.json` or `.tsv`, relative to the repository root) set the two paths directly. For single clips, `acvoice-transcribe <clip> --realtime --projects <list> --alias CODE=word` does the same without the test runner.

Variables: `ACVOICE_CONTEXT_LIMIT=<n>` sets the number of contextual strings, `ACVOICE_CONTEXT_SWEEP=1` compares several sizes (about 4 minutes), `ACVOICE_SPEECH_DEBUG=1` prints the gate and analyzer events.

## Dev CLIs

All of them print ids, counts and timings only, never project names or secrets.

```sh
# Resolver against a project list (tsv "id<TAB>name" or the JSON fixture format)
swift run acvoice-resolve Tests/Fixtures/projects.sample.json "Öffne WWT Relaunch"
swift run acvoice-resolve Tests/Fixtures/private/project_names.tsv --cases Tests/Fixtures/private/regression.tsv

# AC index (GET only, token read from ac-mcp, never from the Keychain)
swift run acvoice-index refresh --stats
swift run acvoice-index resolve "Öffne WWT Ticket 412" --url

# Speech pipeline on audio files (no microphone)
swift run acvoice-transcribe Tests/Fixtures/tts/anna_c02.aiff --realtime
```

Overlay snapshots render every overlay state to PNG without showing a window:

```sh
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay                    # <state>-<light|dark>.png at 2x
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay --only choices,error
swift run acvoice-overlay-snapshots /tmp/acvoice-overlay --variants         # also -contrast, -solid, -still
```

The output folder is the first argument and is created when missing. The states are the 29 scenarios of `OverlayGallery`, starting with the most frequent one (listening-ready, listening-starting, listening-cold, listening-partial, listening-long, processing, processing-search, choices, choices-answer, choices-held, choices-more, choices-page2, choices-narrowed, choices-unclear, choices-nomore, choices-long-titles, choices-confirm, choices-tickets, choices-ticket-chips, retry, retry-nothing, opening, success, success-long, success-hint, error, error-offline, error-mic, error-nothing). `--variants` adds renders with Increase Contrast (`-contrast`), Reduce Transparency (`-solid`) and Reduce Motion (`-still`). Glass cannot render offscreen, so the PNGs show a stand-in backdrop.

The same states run live in the app: Menu > Diagnose > "Overlay vorführen" once, or in a loop with the launch argument `--demo` (no microphone, AC, Chrome, hotkey or socket; quit the running AC Voice first, or start a second copy with `open -n "$HOME/Applications/AC Voice.app" --args --demo`). Both start with a scripted command through the real flow and its real timings, so the fade-in, the spring, the row stagger, the 0.7 s success and the fade-out look as they do in use.

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

- `Contents/MacOS/AC Voice`, `Contents/Info.plist` from `Resources/Info.plist.in` (version from the `VERSION` file, else 0.1.0, build number from the UTC time), `Contents/Resources/AppIcon.icns` and the SwiftPM resource bundles of the app's targets.
- Hardened runtime with `Resources/ACVoice.entitlements` (`com.apple.security.device.audio-input`, `com.apple.security.automation.apple-events`). No sandbox.
- Signs with `SIGN_ID`, else the first valid "Apple Development" identity, after an OCSP revocation check. `SIGN_ID=-` signs ad hoc and skips the check.
- Ends with `codesign --verify --strict` and prints the designated requirement. It never launches the app.

The app icon comes from `scripts/make-icon.swift` (CoreGraphics, macOS app icon grid). After a design change:

```sh
swift scripts/make-icon.swift --preview /tmp/acvoice-icon.png
```

It writes `Resources/AppIcon.icns`. Commit the result. The build does not run the script.
