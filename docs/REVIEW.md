# ac-voice v1 plan: skeptical review

This document uses fantasy names for project codes, company names and distinctive project titles, the same ones as `Tests/Fixtures/projects.sample.json`. Its examples and transcripts follow these names. The real names stay in the git-ignored `Tests/Fixtures/private`. Project, task and user ids are invented as well.

`spikes/` holds unpublished research code and is not part of this repository.

Tags: **[V]** means I ran, compiled or read it in the SDK or source during this pass. **[A]** means assumed.

## Verdict
- **No new blocker.** The revoked certificate is still the only verified blocker.
- **7 major issues.** They are about how the system behaves, not about the overall architecture: end-of-utterance logic, the finalize safety net, lifecycle races, main-thread AppleScript, resolver data failures, ticket fallbacks and audio device changes.
- **2 unverified points need a day-1 spike** because either one could turn into a blocker:
  - Does Chrome come to the front when AC Voice was never the active app? (macOS 14+ cooperative activation)
  - Do mic buffers in the signed, bundled app transcribe without speech authorization?

---

## MAJOR

### M1. The end-of-utterance gate fires on the earcon, clicks and hesitations, and never ends with background noise [V]
**Problem**
- `MicPipeline.swift:166`: a single buffer above -45 dBFS sets `heardSpeech`. There is no onset debounce.
- The plan plays an earcon "tick on first converted buffer". The built-in MacBook mic picks it up, because voice processing (echo cancellation) is off.
  - Gate simulation, earcon not blanked: onset at 0.20 s, then a false end of utterance at 0.84 s, before the user starts speaking.
  - Key clicks on the hotkey path and desk knocks behave the same way [A].
- Hangover only ever gets shorter, never longer. Example: "Öffne … (700 ms) … WWT Relaunch".
  - The research gate finalizes "Öffne".
  - `Parser.command` returns `.unknown`, which triggers the retry message mid-sentence.
- There is no end-of-utterance signal besides energy.
  - With music or colleagues talking, every buffer is above the threshold, so each command runs until the 8 s maximum.
  - The planned "20th percentile of non-speech buffers" floor never sees a non-speech buffer.
- The plan uses `fastHangover` = 450 ms for "a ticket with a number". A trailing number is a prefix trap: "Ticket 4…" can still become 412, and "47000" can still become 47285.

**Fix** (compiled and self-tested: `review/gate/EndpointGate.swift`)
- Use 20 ms slices.
- Count onset only after ≥120 ms of voiced slices within 300 ms.
- Blank the gate while an earcon plays, plus 100 ms.
- Use a 1.1 s hangover when the live partial ends in a dangling word (verb, article, "Ticket", "Nummer") or in a number.
- Add a fallback: end the utterance when the DT partial has not changed for 0.9 s.

```swift
mutating func slice(rmsDB db: Float, at t: Double) -> Output {
    if t < blankUntil { return .none }                       // earcon playing
    let isVoiced = db > thresholdDB
    if !started {
        floorDB = db < floorDB ? db : min(db, floorDB + 15 * 0.02)   // fast down, 15 dB/s up, frozen after onset
        if isVoiced { voiced.append(t) }
        voiced.removeAll { $0 < t - cfg.onsetWindow }
        if Double(voiced.count) * 0.02 >= cfg.onsetVoiced { started = true; lastVoiced = t; lastTextChange = t; return .onset }
        return .none
    }
    if isVoiced { lastVoiced = t }
    let budget = transcriptIncomplete ? cfg.incompleteHangover : cfg.hangover
    if t - lastVoiced >= budget { return .end(lastVoiced: lastVoiced, reason: "pause") }
    if !lastText.isEmpty, t - lastTextChange >= cfg.stableTranscript, !transcriptIncomplete {
        return .end(lastVoiced: lastVoiced, reason: "stable transcript")
    }
    return .none
}
```

Self-test output [V]:

| Case | Result |
|---|---|
| Key click (20 ms) | no onset |
| Earcon, blanked | no onset |
| Earcon, not blanked | onset 0.20 s, end 0.84 s (reproduces the bug) |
| Command | end = last voice + 0.6 s |
| "Öffne" + 800 ms pause + rest | no premature end |
| Music at -35 dBFS throughout | ends 0.9 s after the transcript stops changing |

### M2. The 1.2 s "finalize timeout, then volatile fallback" does not work as specified [V, `review/hang/hangprobe`]
**Probe:** feed audio, then call `finalize(through:)` with a time 1 s beyond the fed audio while no more audio arrives.

| Attempt to unblock | Result |
|---|---|
| `Task.cancel()` | still pending after 3 s |
| `cancelAnalysis(before: fedEnd)` | still pending after 3 s |
| `cancelAndFinishNow()` | throws `CancellationError` within ~0 ms. Both result streams end with `CancellationError`, so the session is dead |

**Consequences**
- The timeout has to kill the session.
- An answer phase after that needs a new analyzer (prepare takes 140-430 ms) and a new input stream.
- A Swift-task race leaves a zombie `finalize` running and the analyzer wedged.
- Seen in the probe: when utterance 1 is not finalized at its boundary, DT merges the command tail and the answer into one final ("…Projekt zwei"). Filtering finals by `range.start` then assigns the answer to the command.
- Realistic triggers:
  - The engine stops itself on a device change (see M7).
  - The mic is stopped on push-to-talk release before `finalize` returns.

**Fix, which also saves latency [V, `review/hang/tailprobe`]**
- On press-to-end or push-to-talk release, append a 500 ms synthetic noise-floor tail at once.
- Then call `finalize(through: speechEnd + 0.4 s)`.
- Measured release-to-final times:
  - "eins": 43-132 ms
  - "zwei" / "drei": 54-55 ms
  - "Öffne WWT Ticket 412": 79 ms
  - "Öffne WWT Relaunch": 188 ms
- Short words came through intact in both ST and DT.
- Compared with waiting for real audio, this saves ≥350 ms, and it cannot hang.

```swift
@available(macOS 26, *)
func finalizeOrKill(_ analyzer: SpeechAnalyzer, through: CMTime, timeout: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { (try? await analyzer.finalize(through: through)) != nil }
        group.addTask { try? await Task.sleep(for: timeout); return false }
        let ok = await group.next() ?? false
        if !ok { await analyzer.cancelAndFinishNow() }   // the only call that releases a waiting finalize
        group.cancelAll()
        for await _ in group {}
        return ok                                        // false: rebuild analyzer + input stream
    }
}
```
`syntheticTail(format:seconds:)` is in the same file. Both type-check under Swift 6 with no warnings.

### M3. VoiceSession lifecycle races and stale events [V by reading MicPipeline.swift, not executed]
**Problems**
- `stop()` awaits `finalizeAndFinishThroughEndOfInput`, then the result tasks, then `prepareAnalyzer()` (about 200-500 ms). Only at the end does it swap `self.analyzer`.
- `start()` reads `self.analyzer` without waiting for that.
- Race in the natural "cancel the list, press again at once" flow:
  1. `start()` runs on the already finished analyzer.
  2. `stop()` then swaps in a new analyzer that was never started.
  3. The next `finalize(through:)` goes to an analyzer with no input and hangs (see M2).
- `finalizeUtterance` runs in a detached `Task` and reads `self.analyzer` late.
- `converter` and `format` are read on the audio thread without the lock (lines 162, 253). `converter` is also set in `start()` without the lock.
- `Event` has no session ID. A late `.utterance` from session N arrives in session N+1's listening phase and is interpreted as a command.

**Fix**
- Serialize the lifecycle: `start()` awaits any pending `stop()`.
- Capture the analyzer, converter and format per session.
- Stamp every event with a (session, utterance) generation. The reducer drops events whose generation does not match.

### M4. Chrome control runs on the main actor with no timeout [V code / A activation]
**Main-thread blocking**
- `ChromeOpener` is `@MainActor` and calls `executeAppleEvent` synchronously.
- `open-ac.applescript` has no `with timeout`.
- The IPC listener and the overlay also run on main.
- So a hung or busy Chrome, or an Automation prompt that is still pending, freezes the whole app:
  - the overlay
  - the Stream Deck key state
  - the hotkey
- The prompt can be pending after a TCC reset, after re-signing with another identity, or when onboarding was skipped.
- The default Apple Event timeout is 120 s [A].
- **Fix:**
  - Wrap the `tell` block in `with timeout of 3 seconds`.
  - Before each call, run `AEDeterminePermissionToAutomateTarget(ask:false)` (cheap on main).
  - On -1744, use the NSWorkspace fallback and schedule the prompt off-main.
  - Alternative: an `osascript` child process with a kill timer (65 ms overhead per call, measured in the packaging research).

**Incognito window**
- The new-tab fallback (`make new tab` in `window 1`) ignores the window mode.
- Chrome's sdef has `mode` = 'normal' | 'incognito' [V].
- If the front window is incognito, AC opens logged out.
- **Fix:** use the first window whose `mode is "normal"`.

**Cooperative activation**
- From macOS 14, an app can only activate when the current app yields (`NSApplication.h` / `NSRunningApplication.h` [V]).
- AC Voice is never the active app (non-activating panel, Stream Deck trigger), so it cannot yield.
- Whether Chrome honors AppleScript `activate` from such a sender is unverified. If it does not, the URL changes but Chrome stays in the background, so the core promise fails silently.
- **Spike on day 1**, with another app in front (VS Code or Finder):
  - Check `NSWorkspace.frontmostApplication` 200 ms later.
  - Fallback: `NSWorkspace.openApplication(at:configuration: activates=true)` [A].
- The same applies to the onboarding window: open it from the menu-bar click, which is a user action.

### M5. Resolver failures on the real project names [V, `acvoice-resolve` against a private list of the real names]

| Utterance | Prototype result | Problem |
|---|---|---|
| WWT / "Öffne das WWT-Projekt" | choices(4), 628 first | **The order of #2-#4 changes from run to run**: [628,315,314,693], then [628,314,315,693]. Ties are decided by `Dictionary` iteration order. "WWT → zwei" picks different projects on different presses |
| we we te / W.W.T. / VWT / W W D | choices(4) | ok. "Wewete" and "WW T" give notUnderstood |
| WWT Relaunch / We We Tee Relaunch / WWT Re-Launch | unique 628 | ok |
| S und K / Es und Ka / S & K / SK | choices(2) [2012,2011] | ok |
| **Öffne S und K Partner** | choices(3) | The exact two-word code "S+K Partner" ties with the "S+K" projects at 3.0 |
| **Hollenstein** | choices(3) of **5** Hollenstein-coded projects | 2023 and 2024 are dropped silently. Partial code credit = 3·matched/len penalizes 3-word codes. The "& → und" variant becomes `codeSeqs.first` (3 tokens) |
| Hollenstein Navigation | 3 Hollenstein-coded projects, no WWT | Needs company aliases |
| TKZ Touren Planer | choices(2) | ok, but the plan's reasoning is wrong. **Both** TKZ titles contain the glued token, one with a doubled-letter typo |
| **Öffne TKZ Tourenplaner / Öffne Tourenplaner** | **unique 2032** | Wrong half the time. Exact (1.0) vs. fuzzy (0.6) on the same word, and only the typo creates the margin |
| QZ CRM / QZ-CRM / Q.Z. CRM / Kuh Zett CRM / KW CRM | unique 2071 | ok |
| Q Z C R M / ku zett ce er em | notUnderstood | The collapse step joins code and title into "QZCRM" |
| Grand Navigation / Öffne Grand / Öffne WWT Grand | unique 693 | ok |
| **WKT Relaunch** | 4 WKT projects, 628 missing | The lookalike credit is dropped whenever any exact code hits |
| WWT Maintenance / WWT Wartung | unique 314 | 315 also contains "maintenance". `fullTitleBonus` 0.4 > epsilon 0.3. This is a product decision, so make it explicit |

- **The test fixture does not mirror the real data where it matters.** It has one separated "TKZ: Touren Planer" project and 3 Hollenstein projects. The real data has 2 glued titles, one with a typo, and 5 Hollenstein-coded projects. The fixture passes exactly the cases that fail on real data.
- **Fix** (patch `review/resolver-fixes.diff`; architect tests: 19 of 20 pass, and the failing one asserts the old WKT limitation):
  1. Break ties deterministically by project ID. Verified: 3 runs give identical output.
  2. Partial-code credit: 1.5 for the head word plus 1.0 per further code word, using the shortest code variant. "Hollenstein" then lists all 5.
  3. Exact multi-word code: +1.0 per extra code word. "S und K Partner" then resolves uniquely to 2013.
  4. Keep the lookalike-code credit (+0.5) when that project explains title words the exact-code projects miss. "WKT Relaunch" then lists 5 with 628 first.
- **Not fixed:**
  - TKZ typo: canonicalize title tokens at index time (OSA ≤1, length ≥8) [A].
  - Build a git-ignored regression list from the real names.
- **Order stability:** the prior includes team `lastActivity`, which changes daily, so positions #2-#4 drift. Order by learned picks first, then by a fixed key.

### M6. The ticket path silently widens its scope [V]
- `TicketResolver.resolve` treats `projects == .none` like `nil`, so the search falls through to own tasks, then favorites, then all projects.
  - Example: "Öffne <misheard project> Ticket 50" opens #50 in whichever favorite is the only one that has it.
  - **Fix:** if project words were spoken but did not resolve, answer "Projekt nicht erkannt" and retry. Never fall back to a global search.
- `Parser.number`:
  - "Ticket 4 12" gives **#4**, and "Ticket 400 12" gives **#400** (CLI output).
  - **Fix:** compose adjacent numerals (400+12, 47000+285, digit runs). Treat leftover numerals as low confidence.
- "Öffne WWT 412" without the word "Ticket" gives a project list (V). Parse `<project> <number>` as a ticket.
- **Collisions** (from the cached task lists of the acapi research, no new API calls):
  - Task numbers restart at 1 in every project, and the WWT projects have number ranges of different length.
  - So "WWT Ticket N" hits all 4 projects for small N, and still 2 or 3 projects for mid-range N.
  - Rank open before completed and own-assigned first.
  - Also rank by the project in the active Chrome AC tab. The AppleScript already reads all tab URLs.
- Bare "Ticket N" with ≤4 digits: search the active tab's project first.
- The plan's "exactly one hit, so open even with incomplete archives" rule can open the wrong project's open ticket while the intended ticket is completed in a sibling project.

### M7. Audio device changes [header V, behaviour A]
- `AVAudioEngine.h` says: on a change in hardware channel count or sample rate, "the engine stops itself".
  - Buffers stop, so a pending `finalize` hangs (see M2).
  - Example triggers: AirPods switching to HFP, plugging in a headset.
- `MicPipeline` keeps one engine and installs the tap with the format it reads at start. A stale or zero format is a known assertion crash [A].
- AirPods as the default input:
  - The mic start switches them to HFP, so the output quality drops for the whole session [A].
  - The mic also starts slowly, so first syllables can be lost [A].
- **Fix:**
  - Use a new engine per session, or observe `.AVAudioEngineConfigurationChange`.
  - Validate the format before installing the tap: sample rate > 0 and channel count > 0.
  - On a change mid-utterance: synthetic tail, then finalize.
  - Default to the built-in mic when the default input is Bluetooth (config override).

---

## MINOR
- **m1. Tap buffer size [V header]:** the tap's `bufferSize` "Supported range is [100, 400] ms". The research simulation fed 1024-frame (21 ms) buffers.
  - Expect ≥100 ms buffers: +0-100 ms on the end-of-utterance decision.
  - The level meter can only reach 10 Hz, not the planned 15 Hz.
  - Compute RMS per 20 ms slice inside each buffer.
  - Re-run the simulation with 4800-frame chunks.
- **m2. Latency budget is optimistic:**
  - 600 ms hangover + slice granularity + finalize (35-50 ms) + Apple Events gives 0.65-0.85 s, not 0.5-0.7 s.
  - The AC single-page app reload probably dominates what the user perceives [A].
  - Measure it in M5.
  - Optional: in-app navigation with Chrome `execute` (in the sdef [V]) plus pushState/popstate [A]. This needs the Chrome setting "Allow JavaScript from Apple Events", which is a security trade-off.
- **m3. False selections from ambient speech** (`review/proto/Sources/sel`, 4 WWT options [V]):
  - "Ja." or "Genau" → #1
  - "Frei." → #3
  - "Nein." → cancel. With the 450 ms answer hangover, "Nein, … die zweite" cancels the list.
  - "Ne, die Vier" → unclear
  - **Fix:** accept confirm words only when the list has 1 item. "nein" alone keeps the mic listening. Add "ne/nee/nö" as negation prefixes. Drop the "frei" lookalike until real recordings justify it.
- **m4. Push-to-talk and protocol** [V fields]:
  - Suspend energy end-of-utterance detection while the key is down. Otherwise a pause during a hold ends the utterance.
  - `release` should carry the press ID.
  - `choose` should carry `seq`, because "narrow" may renumber the list.
- **m5. Cold start** [V]: `MicPipeline.start` throws when `analyzer` is nil (line 79), and the queued press TTL is 10 s.
  - Accept the press, show "Sprachmodell lädt" and buffer audio into the stream.
  - Drop presses older than about 3 s.
  - Ignore press-to-end before onset (accidental double tap).
  - Allow a press to cancel during processing, which includes the archive search of up to 2.5 s.
- **m6. Dev and TCC hygiene:**
  - A bare `swift run` or Xcode-debugged binary has no Info.plist, so it has no usage strings and no bundle ID, and TCC attributes it to Terminal or Xcode.
  - Embed the plist with a dev bundle ID. Verified, the binary prints `io.github.nordavid.acvoice.dev` and the usage string:
    ```swift
    .executableTarget(name: "probe", linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
        "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])])
    ```
  - Keep the dev CLI out of the Keychain. Unsigned rebuilds cause ACL prompts [A].
  - Fix the signing identity before the first Keychain write. A later DR change means TCC and Keychain prompts again [A].
  - Do not use `kSecUseDataProtectionKeychain`. It needs an entitlement and a provisioning profile [A].
  - Keep only one installed copy. A second copy in `dist/` can make `open -b` launch a stale build [A].
- **m7. Speech authorization in the bundled, hardened app** [A]: the research only ran unbundled CLIs. In onboarding, transcribe a bundled 1 s clip without the mic. Request authorization only if that fails.
- **m8. Small parser gaps** [V]:
  - "Zeige meine Aufgabe" (singular) → notUnderstood.
  - Spelled runs that cover code plus title ("Q Z C R M") → notUnderstood. Split a collapsed run at known code prefixes.
- **m9. Self-healing aliases:** when the user picks the same project twice for the same heard query (e.g. "eben betreuung" → IBN), promote that query to an alias.
- **m10. Contextual strings:** 50 entries is untested. Measured so far: 19 helped, 100 and 185 hurt. Measure 19, 35 and 50 in M3, and prefer codes with personal signals.
- **m11. Real-mic smoke test after M3, not in M7:** the energy gate, earcon pickup and AirPods behaviour only show up with real audio.
- **m12. Clickable rows:** test that rows in a `canBecomeKey=false` panel receive the first click [A].

## Files
All under `spikes/review/`:
- `spikes/review/hang/hangprobe.swift`
- `spikes/review/hang/tailprobe.swift`
- `spikes/review/hang/FinalizeGuard.swift`
- `spikes/review/gate/EndpointGate.swift` (with `main.swift` self-test)
- `spikes/review/resolver-fixes.diff`
- `spikes/review/proto/` (patched copy of the prototype plus the `sel` selection probe)
- `spikes/review/run_cases.sh`, `spikes/review/cases1.txt`, `spikes/review/cases2.txt` (inputs) and `spikes/review/orig.txt`, `spikes/review/patched5.txt` (results, IDs only)
- `spikes/review/plistembed/Package.swift`

## Compliance
- **AC API:** I made no calls. The ticket collisions come from task lists the acapi researcher had already cached.
- **Mic, Chrome, apps:** no mic access, no Apple Events, no apps opened, no permission prompts.
- **Repos:** other local repositories are unchanged. The architect's prototype was copied before I patched it.
- **Timeouts:** every run used `alarm`, and none timed out.
- **Stray file:** one probe copy landed in the system temp directory by mistake. I deleted it.
