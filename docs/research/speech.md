# ac-voice: Apple on-device speech evaluation (Speech.framework, de_DE)

This document uses fantasy names for project codes, company names and distinctive project titles, the same ones as `Tests/Fixtures/projects.sample.json`. Its examples and transcripts follow these names. The real names stay in the git-ignored `Tests/Fixtures/private`. Project, task and user ids are invented as well.

`spikes/` holds unpublished research code and is not part of this repository.

## 0. Recommendation (summary)
- **Engine:** use one `SpeechAnalyzer` session that runs **both `SpeechTranscriber` and `DictationTranscriber`** (de_DE). Fuzzy-match the union of both best texts and their alternatives against the project list.
  - DT honors contextual strings. It does better on project vocabulary ("WWT-Projekt", "WWT Relaunch", "Pilzdatenbank", "Grand Navigation").
  - ST ignores contextual strings. It does better on English loanwords ("Leasing Cockpit").
  - Both modules in one analyzer: VERIFIED working. Finalize costs about 40-100 ms.
  - Not recommended: SFSpeechRecognizer (needs authorization and uses the same models as DT), a custom LM (no gain measured), SpeechDetector (useless for end-of-utterance).
- **End-of-utterance:** an app-side energy gate (RMS dBFS) with a hangover of **600 ms for commands and 450 ms for answers**. Then call `analyzer.finalize(through: lastSpeech + 400 ms)` while the mic keeps feeding audio. Results arrive about 40 ms later.
  - Measured end to end on file-driven simulation: **620-675 ms** from speech end to final command text and **470-490 ms** for "eins"/"zwei". VERIFIED.
- **Follow-up answers:** keep the same analyzer session and keep the mic open. Re-arm the end-of-utterance logic and swap the context with `setContext(["eins","zwei",...]+option keywords)`. Parse digits, number words, ordinals and title keywords. VERIFIED.
- **Process model:** a resident, signed menu-bar .app with a pre-warmed analyzer. Key press to listening takes 1-2 ms when the analyzer is pre-built (VERIFIED). A cold `prepareToAnalyze` takes 180-430 ms.
  - The app needs only **microphone** permission.
  - SpeechAnalyzer needs **no speech-recognition authorization**. VERIFIED for buffer and file input.

## 1. Environment facts
- Runtime macOS **26.6.2**, but **Xcode/SDK 27.2** (the swiftinterface targets macos27.2). VERIFIED.
  - APIs marked `anyAppleOS 27` cannot run on this Mac: `AnalyzerInputConverter`, `CaptureInputSequenceProvider`, `AssetInputSequenceProvider`, `AnalyzerInput(CMReadySampleBuffer)`, `Options.ignoresResourceLimits`.
  - Build with `-target arm64-apple-macos26.0` and guard 27-only APIs with `#available`.
- All code below compiles with `swiftc -swift-version 6`, Swift 6.4.2, with no warnings. VERIFIED.
- Inference runs out of process in `Speech.framework/.../XPCServices/localspeechrecognition.xpc`. One sample during live ST+DT streaming showed about 18% of one core and about 115 MB RSS. The client process stays at about 20 MB RSS and 0.2 s user CPU per 12 s of audio. VERIFIED.

## 2. API (read from SDK swiftinterface + swiftdoc), VERIFIED
- **SpeechAnalyzer** (actor)
  - Initializers: `init(modules:options:)`; `init(inputSequence:modules:options:analysisContext:volatileRangeChangedHandler:)`; `init(inputAudioFile:modules:options:analysisContext:finishAfterFile:volatileRangeChangedHandler:) async throws`.
  - Preparation: `prepareToAnalyze(in: AVAudioFormat?)`, with an optional `withProgressReadyHandler:` variant.
  - Input: `start(inputSequence:)`, `start(inputAudioFile:finishAfterFile:)`, `analyzeSequence(_:) -> CMTime?`.
  - **Finalize/finish:** `finalize(through: CMTime?)`, `finalizeAndFinishThroughEndOfInput()`, `finalizeAndFinish(through:)`, `finish(after:)`, `cancelAnalysis(before:)`, `cancelAndFinishNow()`.
  - Other: `volatileRange`, `setVolatileRangeChangedHandler`, `context`/`setContext(_:)`, `setModules(_:)`.
  - `static bestAvailableAudioFormat(compatibleWith:)` and `(compatibleWith:considering:)`.
  - `Options(priority:modelRetention: .whileInUse | .lingering | .processLifetime)`.
  - The doc says the analyzer does **not** convert audio. You must convert buffers yourself (AVAudioConverter). The file initializer converts files.
  - The doc says ending the input stream does not end the session. Only `finalizeAndFinishThroughEndOfInput` does.
- **AnalyzerInput:** `init(buffer:)` and `init(buffer:bufferStartTime:)`. Without a start time, the timeline equals cumulative frames.
- **SpeechTranscriber**
  - `init(locale:preset:)` with presets `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription` (= volatileResults + fastResults) and `.timeIndexedProgressiveTranscription`.
  - `init(locale:transcriptionOptions:[.etiquetteReplacements] reportingOptions:[.volatileResults,.alternativeTranscriptions,.fastResults] attributeOptions:[.audioTimeRange,.transcriptionConfidence])`.
  - Doc for `fastResults`: "reduces result latency by using a smaller context window".
  - Statics: `isAvailable`, `supportedLocales`, `installedLocales`, `supportedLocale(equivalentTo:)`.
  - `results`: AsyncSequence of `Result{range, resultsFinalizationTime, text: AttributedString, alternatives, isFinal}`. `isFinal` means `resultsFinalizationTime >= range.end`.
- **DictationTranscriber**
  - Presets: `.phrase` (shortForm), `.shortDictation` (+punctuation), `.progressiveShortDictation` (+volatileResults +frequentFinalization), `.longDictation`, `.progressiveLongDictation`, `.timeIndexedLongDictation`.
  - ContentHint: `.shortForm`, `.farField`, `.atypicalSpeech`, `.customizedLanguage(modelConfiguration:)`.
  - TranscriptionOption: `.punctuation`, `.emoji`, `.etiquetteReplacements`.
  - ReportingOption: `.volatileResults`, `.alternativeTranscriptions`, `.frequentFinalization`.
  - Doc: "uses the same speech-to-text models as system dictation ... or as SFSpeechRecognizer when configured for on-device".
- **SpeechDetector:** `init()`, `init(detectionOptions: .init(sensitivityLevel: .low|.medium|.high), reportResults:)`. `Result.speechDetected`.
  - Doc: it is a VAD **power optimization** and only works together with a transcriber.
  - Doc: results "currently only support error handling from the VAD model". **Not usable for end-of-utterance detection.**
  - Run confirms it: `reportResults:true` produced 0 results in 4 runs.
- **AnalysisContext:** `contextualStrings: [ContextualStringsTag: [String]]` (`.general`), plus `userData`.
  - The doc ties contextual strings explicitly to **DictationTranscriber**.
  - The doc asks for 1-2 words per phrase and **at most 100 phrases in total**.
- **AssetInventory:** `status(forModules:)` returns `.unsupported/.downloading/.supported/.installed`. Also `assetInstallationRequest(supporting:) -> AssetInstallationRequest?` (`progress`, `downloadAndInstall()`), `reserve(locale:)`, `release(reservedLocale:)`, `reservedLocales`, `maximumReservedLocales` (=5 here). `SpeechModels.endRetention()`.
- **New SFSpeechError codes:** noModel, assetLocaleNotAllocated, tooManyAssetLocalesAllocated, incompatibleAudioFormats, unexpectedAudioFormat, audioDisordered, insufficientResources and others.
- **Audio formats:** ST and DT each accept mono 16 kHz Int16 and mono 8 kHz Int16. `bestAvailableAudioFormat` returns **mono 16 kHz Int16**, also when considering a 48 kHz Float32 mic format.
- **Custom LM:** `SFCustomLanguageModelData` (PhraseCount, templates with classes, CustomPronunciation in X-SAMPA) → `export(to:)` → `SFSpeechLanguageModel.prepareCustomLanguageModel(for:configuration:)`. `Configuration(languageModel:vocabulary:weight:)`; `weight` is new in macOS 26.
- **SFSpeechRecognizer fallback:** `requiresOnDeviceRecognition`, `contextualStrings`, `addsPunctuation`, `customizedLanguageModel`, `taskHint`.

## 3. Assets and authorization
- de_DE installed for ST (de_DE/AT/CH) and for DT (de_DE, en_US). Transcription works without any download. VERIFIED.
- The first `AssetInventory.status` call in a fresh process returned `.supported` in 3 of 4 processes. Later calls returned `.installed`. VERIFIED.
- `assetInstallationRequest` is non-nil even when installed (progress 0/0). `downloadAndInstall()` finished in **660 ms** (progress 1/2) with no large download, and the status was `.installed` afterwards. VERIFIED. Recommendation: always run it at app launch.
- `reservedLocales` = [de_DE]. VERIFIED.
- Authorization: an unbundled CLI with no Info.plist and `SFSpeechRecognizer.authorizationStatus() == .notDetermined` ran all of these without any prompt or block. VERIFIED.
  - SpeechAnalyzer with ST, DT and SpeechDetector
  - AssetInventory including downloadAndInstall
  - `SFSpeechLanguageModel.prepareCustomLanguageModel`
- **The final app therefore needs only the microphone permission.**
  - Mic-sourced buffers are the same API, so no speech authorization should apply there either. ASSUMED, not tested.
  - The microphone was not tested, because it would prompt.
- SFSpeechRecognizer: de_DE `isAvailable=true`, `supportsOnDeviceRecognition=true`. **Not run**: it is not authorized, and `requestAuthorization` would prompt. It would also need `NSSpeechRecognitionUsageDescription`. ASSUMED: same accuracy as DT, because the models are the same per the doc.
- Final app checklist (ASSUMED, standard macOS behavior):
  - `NSMicrophoneUsageDescription`.
  - Hardened runtime entitlement `com.apple.security.device.audio-input` (also required with App Sandbox).
  - Trigger the prompt in onboarding with `AVCaptureDevice.requestAccess(for: .audio)`.
  - Stop the engine after each session so the orange mic indicator disappears.
  - If the Stream Deck Node plugin spawns a CLI, TCC attributes the mic to the Stream Deck app (responsible process). Use a separate signed .app with its own bundle ID instead, triggered by URL scheme, socket or localhost.

## 4. Test setup (VERIFIED)
- Harness `stt` simulates a live mic. It feeds 100 ms chunks of 16 kHz Int16 at real-time pace, after 300 ms of noise floor (about -60 dBFS) and before configurable trailing noise.
  - Latency = wall time from the last speech chunk to the last final result.
  - Command clips have at most 0.5 s of TTS-internal silence, so "trail 0" really means about 0-0.5 s of trailing audio.
- TTS voices:
  - `Anna` (de_DE) is the only natural-sounding German voice installed.
  - `Eddy` and `Flo` (de_DE) are low-fidelity novelty voices.
  - The mixed clips add the English loanwords spoken by `Daniel` (en_GB).
- Caveat: German TTS pronounces "Relaunch" as "Relonch" and garbles "S+K" and "IBN". Real human recordings are needed for final tuning.
- Contextual strings, 19 entries: WWT, WWT-Projekt, Website Relaunch, Relaunch, Grand Navigation, Maintenance, TYPO3, S+K, Leasing Cockpit, TKZ, Touren Planer, IBN, Betreuung, BDG, Pilzdatenbank, QZ, CRM, Ticket, Meine Aufgaben.

## 5. Transcripts (Anna; VERIFIED)
The measurement used the real project names. In the two tables below, cells with a code, a company name or a title word are adapted: they show the fantasy name with the kind of error the real name had, not a new measurement. Cells marked † hold an invented garbling of the fantasy name. The table "Fantasy-code check" further down holds real transcripts of the fantasy names.

Column headers:
- **ST:** SpeechTranscriber with volatileResults, fastResults, alternatives. Trailing audio 0 ms.
- **ST 700:** the same with 700 ms of trailing audio.
- **ST+ctx:** identical to ST in 15 of 15 clips, apart from whitespace and punctuation. ST ignores contextual strings.
- **DT:** DictationTranscriber with shortForm, no punctuation, volatileResults, alternatives, frequentFinalization.
- **DT185:** the full vocabulary of 185 strings built from all active projects (about 60).

| clip | ST | ST 700 | DT no ctx | DT+ctx | DT185 |
|---|---|---|---|---|---|
| Öffne das WWT-Projekt | Öffne das WWT Projekt. | = | Öffne das WWD Projekt | **Öffne das WWT-Projekt** | Öffne das WWD Projekt |
| Öffne WWT Relaunch | Öffne WWTilonch. | Öffne WWT Rionch | Öffne WTI Lunch | **Öffne WWT Relaunch** | Öffne WWT Relaunch |
| Öffne das S+K Leasing Cockpit | Öffne das S plus K-Leasing Kokpit † | ~ | Öffne das Eska † | Öffne das Eska (Cockpit) † | Öffne das Eska Cockpit † |
| Öffne TKZ Touren Planer | Öffne CKZ Touren Plan. † | ~ | Öffne TKZ Tauben † | Öffne TKZ Tauben † | = |
| Öffne WWT Ticket 412 | Öffne WWT Ticket 412. | = | = | = | = |
| Öffne Ticket 47285 | Öffne Ticket **47.285**. | = | = | = | = |
| Zeig meine Aufgaben | Zeig meine Aufgaben | = | Zeige meine Aufgaben | = | = |
| eins / zwei / drei | **"" / "" / ""** | Eins. / Zwei. / Drei. | Eins / Zwei / Drei | = | = |
| die zweite | Die zweite. | = | Die zweite | = | = |
| Relaunch | Relonch. | = | **Relaunch** | Relaunch | = |
| Grand Navigation | Grand Navigation | Grantnavigation. | Braun Navigation | **Grand Navigation** | Braune Navigation |
| IBN Betreuung | Ebenbetreuung | = | Eben Betreuung | = | = |
| BDG Pilzdatenbank | Im Pilzdatenbank | = | Im Pilzdaten † | **Pilzdatenbank** | Pilzdatenbank |

Mixed clips (German part by Anna, English part by Daniel; trailing audio 700 ms):

| clip | ST | DT | DT+ctx |
|---|---|---|---|
| WWT + "Relaunch" | Öffne WWT Relaunch. | Öffne WWT Relaunch | Öffne WWT Relaunch |
| "S und K" + "Leasing Cockpit" | **Öffne das S und K. Leasing Cockpit** | Öffne das S & K | Öffne das S & K |
| "Es Ka" + "Leasing Cockpit" | Öffnete Leasing Cockpit. | Öffne hörst | Öffne hörst |
| TKZ + "Touren Planer" | Öffne CKZ Touren. † | Öffne TKZ Touren Pla † | Öffne TKZ Touren Pla † |
| "Relaunch" | Relaunch. | Relaunch | Relaunch |
| "Grand Navigation" | Navigatsion. † | Navigation | Navigation |

Fantasy-code check (2026-11-24, Anna and Daniel, `acvoice-transcribe --realtime` with the fixture's contextual strings; 2 runs each, both runs gave the same text unless noted):

| clip | DT | ST |
|---|---|---|
| Öffne WWT Relaunch | Öffne WWT Relaunch | Öffne WWConch. |
| Öffne das WWT-Projekt | öffne das WWT-Projekt | Öffne das WWT Projekt. |
| Öffne WWT Ticket 412 | öffne WWT Ticket 412 | Öffne WWT Ticket 412. |
| "Öffne das S und K" + "Leasing Cockpit" | öffne das S & K Leasing / öffne das das S & K S & K Leasing Cockpit | Öffne das S und K. Leasing Cockpit |
| Öffne TKZ Touren Planer | Öffne TK Z Tourenplaner | Öffne TKZ Tourenplaner. |
| TKZ Datenimport | C KZ Datenimport | TKZ Datenimport |
| IBN Betreuung | eben Betreuung | Eben Betreuung. (alternatives: Ebenbetreuung., Imben Betreuung.) |
| Grand Navigation | braun Navigation | Gran Navigation (alternative: Grand Navigation) |
| BDG Pilzdatenbank | WDG Pilzdatenbank (3 of 6) / BDG Pilzdatenbank | BDG Pilzdatenbank. |

Findings (VERIFIED unless marked):
- **Short words:**
  - ST returned **empty text for Anna's "eins/zwei/drei"** (0.33-0.43 s clips) when finalized right after speech.
  - With ≥400 ms of trailing audio, both engines recognize them.
  - At 200 ms of trailing audio, both engines lost "zwei" and DT also lost "drei".
  - → Never finalize less than about 400 ms after speech end.
- **Contextual strings:**
  - DT+ctx fixed 4 of 15 Anna clips and broke none.
  - ST+ctx changed nothing.
  - A large vocabulary dilutes the effect. With 185 entries or 100 entries, 2 of 21 clips were worse than with the 19 targeted entries (WWT-Projekt → WWD, Grand → Braun).
  - Keep about 30-50 entries: the codes plus key title words. Swap the context per phase.
- **Custom LM:** ran through `prepareCustomLanguageModel` (export 19 ms, 11 KB; prepare 1.7 s; .lm file 6.2 MB). DT+ctx+CLM (weight default or 1.0) matched DT+ctx in 20 of 21 clips (1 slightly better). Not worth it for v1. Pronunciations were not tested.
- **Numbers:**
  - Both engines output digits ("412", "47.285" with a German thousands dot; Flo variants "47. 285" and "47.2 85").
  - Normalize by joining digit groups. ST alternatives for "Zwei" include "2" and "2.".
- **Low-fidelity voices (Eddy/Flo):** both engines are poor.
  - DT hallucinates app names for "Öffne …" ("Öffne Disney+", "Öffne YouTube", "App TV").
  - Both engines turn WWT into "WKT/WKG/LWT/WWD". **WKT is another active code, shared by several projects**, so the matcher must not hard-commit on a code with an edit distance of 1.
  - The code of the IBN role was never recognized (adapted: Eben/Imben). Plan spoken aliases per project.
- **Run-to-run variance:** results vary slightly with chunking. For example "Eska" vs "Eska Cockpit" (adapted), and DT partials flipping between TKZ, TK Z and C KZ (fantasy-code check).

## 6. Latency (VERIFIED, M1 Pro)
- **Finalize cost** (end of stream, then `finalizeAndFinishThroughEndOfInput`, trailing audio 0):

| config | median | p90 | max | n |
|---|---|---|---|---|
| ST | 32 ms | 49 ms | 96 ms | 42 |
| ST+ctx | 31 ms | 44 ms | 55 ms | 42 |
| DT | 35 ms | 68 ms | 220 ms | 45 |
| DT+ctx | 39 ms | 61 ms | 121 ms | 45 |

- With 700 ms of trailing audio: ST median 731 ms, DT+ctx median 737 ms, i.e. hangover + about 35 ms. ST+DT together: 736-832 ms.
- **Mid-session `finalize(through: t)`**
  - With t = last speech + 400 ms, so t lies inside audio already fed: the call takes **34-51 ms**.
  - With t = end of fed audio: 72-204 ms, because it waits for the next buffer.
  - **`finalize(through: nil)` with the input stream still open never returned.** The process blocked until the 30-60 s timeout killed it.
  - `finalize(through: endOfFedAudio)` blocks the same way when no further audio arrives. The mic must keep feeding.
- **Without explicit finalize:**
  - ST never auto-finalized within 2.5 s of silence.
  - DT (frequentFinalization) auto-finalized after about **1.4-1.5 s**. Too slow to use as end-of-utterance.
- **Volatile cadence:**
  - ST works in about 1 s blocks. For a short word, the first partial came 428 ms after speech end.
  - DT updates every 200-300 ms.
  - → Feed the overlay's live transcript from DT.
- **Prepare/warm-up:**
  - `prepareToAnalyze`: ST 84-155 ms for the first analyzer in a process, then 4-9 ms. DT 140-200 ms per analyzer (262-380 ms cold). ST+DT 183-436 ms.
  - `warmUp` (asset request + prepare): 1108 ms the first time, 324-414 ms after that.
  - `setContext` mid-session: 1-2 ms for ST only, **109-122 ms with DT**.
  - Not measured: AVAudioEngine input start time.
- **End-to-end `VoiceSession` simulation:** 48 kHz Float32 in 1024-frame tap buffers, energy gate at -45 dBFS, ST+DT, 5 runs.
  - Command final: **618-674 ms** after speech end (hangover 600 ms).
  - Answer final: **469-487 ms** (hangover 450 ms).
  - Every command and answer was resolved correctly: "zwei", "Relaunch", "die zweite", "eins", "drei".

## 7. End-of-utterance and one-word answers
- Do not rely on SpeechDetector (it reports errors only) or on DT auto-finalization (about 1.5 s).
- Use **RMS gate + hangover** on the mic tap. Recommended (ASSUMED for real mics):
  - An adaptive noise floor, e.g. threshold = max(-50 dB, floor + 12 dB).
  - Commands: 600 ms hangover. Answers: 450 ms. Never below 400 ms.
  - A no-speech timeout of 4 s and a maximum utterance of 8 s.
  - Optional (ASSUMED, not measured): shorten the hangover to about 400 ms when the DT partial already resolves uniquely.
- Finalize with `finalize(through: lastLoudFrame + 0.4 s)` while the mic keeps feeding. Do not use `nil` and do not end the stream.
- Session handling:
  - Collect finals per module, keyed by `range.start`. DT re-sent identical finals (twice, with a leading space) after a mid-session finalize, so dedupe.
  - If a module sends no new final (the doc allows this when the volatile result is unchanged), fall back to its last volatile text.
- Answers:
  - Same session, mic open. Re-arm the end-of-utterance logic first, then call `setContext` (about 110 ms) with the numbers and the option keywords.
  - Match against: "1/eins/erste…", "2/zwei/**zwo**/zweite…", "3/drei/dritte…" and so on, plus title keywords.
  - Flo's "drei" came out as "Hi". Consider a re-ask instead of guessing.

## 8. Code (all compiled; paths in section 10)
- `MicPipeline.swift`, class `VoiceSession`: AVAudioEngine tap → AVAudioConverter → one SpeechAnalyzer with ST+DT. It covers the energy end-of-utterance logic, `finalize(through:)`, follow-up answers and pre-building the next analyzer.
  - Full compile to a dylib passes with no warnings.
  - A `-D SIMULATE` hook lets file audio drive the exact same code, which is how section 6 measured it.
  - Core excerpts, verbatim:

```swift
// Module config (one analyzer, both transcribers)
SpeechTranscriber(locale: locale, transcriptionOptions: [],
                  reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions], attributeOptions: [])
DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [],
                     reportingOptions: [.volatileResults, .alternativeTranscriptions], attributeOptions: [])
let analyzer = SpeechAnalyzer(modules: [st, dt], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
context.contextualStrings[.general] = vocabulary          // honored by DT only; keep <= 100 short entries
let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [st, dt])  // 16 kHz Int16 mono
try await analyzer.prepareToAnalyze(in: format)          // do this BEFORE the key press

// Audio thread: gate, then always keep feeding (finalize(through:) needs later audio to return)
framesFed += Int64(converted.frameLength)
if db > speechThresholdDB { heardSpeech = true; lastSpeechFrame = framesFed }
if heardSpeech && Double(framesFed - lastSpeechFrame) / rate >= hangover {
    phase = .idle
    return .finalize(from: utteranceStart, through: lastSpeechFrame + Int64(finalizeLead * rate))  // lead 0.4 s
}
inputCont?.yield(AnalyzerInput(buffer: converted))

// End of utterance: finalize inside the hangover, session stays open for a follow-up answer
try? await analyzer.finalize(through: CMTime(value: through, timescale: CMTimeScale(rate)))
```

- `AnswerParser.swift`: maps answers to an option index and extracts ticket numbers. Self-test output: "Zwei/2" → 2, "die zweite" → 2, "Relaunch" → 1, "Grand Navigation" → 4, "Hi." → nil, "47.285" / "47. 285" → 47285.
- On macOS 27+, `CaptureInputSequenceProvider` and `AnalyzerInputConverter` could replace the engine and converter code. Not usable on 26.6.

## 9. Open points and risks
- All results come from TTS audio. Record 20-30 real utterances from the user (built-in mic and headset) to tune the threshold, hangover and aliases. Bluetooth HFP mics are untested.
- The WWT/WKT and IBN confusion needs phonetic fuzzy matching and user-defined spoken aliases. "S+K" comes out as "S und K" (ST) or "S & K" (DT), so normalize `&`, `+` and `und`.
- DT's "Öffne <App>" prior (Disney+, YouTube) shows up with noisy audio. Treat low match scores as "not understood" and re-ask.

## 10. Files
- `spikes/speech/src/MicPipeline.swift` (VoiceSession, compiled as `bin/libMicPipeline.dylib`)
- `spikes/speech/src/simulate_main.swift` (file-driven VoiceSession test; build: `swiftc -swift-version 6 -D SIMULATE -target arm64-apple-macos26.0 -module-name Sim src/MicPipeline.swift src/simulate_main.swift`)
- `spikes/speech/src/AnswerParser.swift`
- `spikes/speech/src/stt.swift` (streaming/batch harness: `--engine=st|dt|both|sf --ctx --vocab= --trail= --vad --clm= -v`)
- `spikes/speech/src/followup.swift` (two utterances in one session, finalize(through:) behavior)
- `spikes/speech/src/clm.swift`, `.../src/probe.swift`, `.../src/probe2.swift`, `.../src/install.swift`
- Raw results: `spikes/speech/out/` (st.txt, st_ctx.txt, dt.txt, dt_ctx.txt, st_t700.txt, dtctx_t700.txt, both_*.txt, dt_vocab*.txt, dt_ctx_clm*.txt).
- Test audio: `spikes/speech/audio/` (anna_/eddy_/flo_p01-p15.aiff, mix_*.wav, phrases.txt)
- No other local project was modified. The AC API was only read once, through a read-only project list of a local MCP server, to size the vocabulary. No mic, Chrome or app was touched, and no permission prompt was triggered.
