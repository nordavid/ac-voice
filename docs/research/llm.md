# FoundationModels as an intent-parser fallback for ac-voice

This document uses fantasy names for project codes, company names and distinctive project titles, the same ones as `Tests/Fixtures/projects.sample.json`. Its examples and transcripts follow these names. The real names stay in the git-ignored `Tests/Fixtures/private`. Project, task and user ids are invented as well.

`spikes/` holds unpublished research code and is not part of this repository.

## TL;DR
- **The on-device model is unavailable on this Mac.** VERIFIED: `SystemLanguageModel.default.availability` returns `.unavailable(.appleIntelligenceNotEnabled)`. Apple Intelligence is turned off on the test Mac. So the LLM path compiles here but cannot run, and I could not measure its latency. The latency figures below are estimates (ASSUMED).
- **The rules parser handles all 11 required inputs and 22 extra speech-to-text variants.** It takes about 17 µs per parse. Resolving against the live project list (about 60 projects) takes 0.03 to 1.9 ms. VERIFIED: compiled and run.
- **Recommendation: rules first.** An LLM fallback stays optional behind a feature flag. It only handles low-confidence project queries and never runs in the selection window. In practice v1 is rules-only, unless the user turns on Apple Intelligence.

---

## 1. FoundationModels API (read from the SDK swiftinterface)

**SDK vs OS.** VERIFIED: the installed Xcode SDK is **macOS 27.2**, but the OS is **26.6.2**. The interface has 276 `macOS 27.0` and 19 `macOS 27.2` availability annotations. Anything marked 27 must not be used (it cannot run on this machine). Build with deployment target 26.0 and wrap anything newer in `#available`.

| API | Availability | Notes |
|---|---|---|
| `SystemLanguageModel.default`, `init(useCase: .general/.contentTagging, guardrails: .default/.permissiveContentTransformations)` | 26.0 | VERIFIED |
| `availability: .available / .unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`, `isAvailable` | 26.0 | VERIFIED. `Observable`, so a UI can react when the state changes |
| `supportedLanguages: Set<Locale.Language>`, `supportsLocale(_:)` | 26.0 | VERIFIED at runtime: 23 languages including `de-Latn-DE`. `supportsLocale(de_DE) == true` |
| `contextSize` | 26.0 | VERIFIED: the inlined code returns `4096` below macOS 27. Runtime prints 4096 |
| `tokenCount(for: Prompt/Instructions/[Tool]/GenerationSchema/…)` | **26.4** | VERIFIED: needs `-target arm64-apple-macos26.4` or `#available`. **It works even when Apple Intelligence is off** |
| `LanguageModelSession(model:tools:instructions:)` (String / `Instructions` / builder), `init(…transcript:)` | 26.0 | VERIFIED |
| `session.prewarm(promptPrefix: Prompt? = nil)` | 26.0 | VERIFIED. Synchronous fire-and-forget, no completion callback |
| `respond(to:generating:includeSchemaInPrompt:options:) async throws -> Response<T>` (`.content`, `.rawContent`, `.transcriptEntries`) | 26.0 | VERIFIED |
| `streamResponse(…generating:)` → `ResponseStream<T>` of `Snapshot.content: T.PartiallyGenerated` | 26.0 | VERIFIED |
| `isResponding`. Concurrent calls on one session throw `GenerationError.concurrentRequests` | 26.0 | VERIFIED (declaration). Conclusion: use one session per utterance |
| `GenerationOptions(samplingMode: .greedy / .random(top:seed:) / .random(probabilityThreshold:seed:), temperature:, maximumResponseTokens:)` | 26.0 | VERIFIED |
| `GenerationError`: `exceededContextWindowSize, assetsUnavailable, guardrailViolation, unsupportedGuide, unsupportedLanguageOrLocale, decodingFailure, rateLimited, concurrentRequests, refusal` | 26.0 (deprecated in 27 in favour of `LanguageModelError`) | VERIFIED |
| `@Generable(description:)` on struct **and enum** | 26.0 | VERIFIED: compiles. The enum becomes a JSON-schema `enum` |
| `@Generable(description:representNilExplicitlyInGeneratedContent:)` | 26.4 | VERIFIED (declaration) |
| `@Guide(description:)`, `@Guide(description:, GenerationGuide…)`, `@Guide(description:, Regex)` | 26.0 | VERIFIED |
| `GenerationGuide`: String `.constant/.anyOf/.pattern`; Int/Float/Double/Decimal `.minimum/.maximum/.range`; arrays `.count/.minimumCount/.maximumCount/.element` | 26.0 | VERIFIED |
| `protocol Tool { name; description; parameters: GenerationSchema; includesSchemaInInstructions; @concurrent func call(arguments:) async throws -> Output }`, where `Arguments: ConvertibleFromGeneratedContent` (in practice `@Generable`; String/Int/Bool arguments are marked unavailable) | 26.0 | VERIFIED |
| `GenerationOptions.toolCallingMode`, `ContextOptions(reasoningLevel:)`, `Usage`, `LanguageModel` protocol, `PrivateCloudComputeLanguageModel`, `DynamicInstructions/Profile`, `Variant.core3/.coreAdvanced3` | **27.0** | VERIFIED: **cannot be used on this Mac** |
| `SystemLanguageModel.Adapter` | deprecated 26.4, obsoleted 27 | VERIFIED |

**Tool calling and latency.** Each tool call is one more model turn: the model emits the call, our code runs it, then the model generates again. ASSUMED: that roughly doubles latency. For ac-voice, resolve projects in code and do not use tools.

## 2. Availability on this Mac (VERIFIED)

Source: `spikes/llm/avail/main.swift`

```
availability: unavailable(...UnavailableReason.appleIntelligenceNotEnabled)
isAvailable: false
supportedLanguages(23): da-Latn-DK, de-Latn-DE, en-…, …
supportsLocale(de_DE): true   contextSize: 4096
```

- **What fails when it is off.** VERIFIED: `respond()` throws `GenerationError.assetsUnavailable` ("Apple Intelligence is not enabled.") **after 5 to 7 ms**. A fallback that is switched off costs almost nothing.
- **Hardware.** The M1 Pro is eligible (ASSUMED: M1 or newer is required, and the reason code is not `deviceNotEligible`).
- **Enabling it.** The user has to turn it on in System Settings > Apple Intelligence & Siri. That triggers a multi-GB model download and turns on Apple Intelligence system-wide (ASSUMED). I did not change any setting.

## 3. LLM intent parser (compiles under Swift 6; cannot run here)

Source: `spikes/llm/fm/main.swift`

Binary `fm/fmintent` exits 2 when the model is unavailable. `--force` prints the error.

```swift
import Foundation
import FoundationModels

@Generable
enum IntentKind: String { case openProject, openTask, openMyTasks, select, unknown }

@Generable(description: "Parsed voice command for the ActiveCollab launcher")
struct VoiceCommand {
    @Guide(description: "What the user wants to do")
    var intent: IntentKind
    @Guide(description: "Project code and/or title words, spelled letters joined (we we te -> WWT, S und K -> S+K). Omit filler words. Null if none.")
    var projectQuery: String?
    @Guide(description: "Ticket number as digits", .range(1...9_999_999))
    var taskNumber: Int?
    @Guide(description: "1-based position picked from the visible list", .range(1...10))
    var selectionIndex: Int?
}

// Per utterance: fresh session (4096-token context), prewarm on key press, greedy decoding.
let session = LanguageModelSession(model: .default, instructions: instructionsText)
session.prewarm(promptPrefix: Prompt("Auswahlliste sichtbar: nein\nBefehl:"))
let r = try await session.respond(to: "Auswahlliste sichtbar: nein\nBefehl: \(utterance)",
                                  generating: VoiceCommand.self,
                                  options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 80))
```

**Schema the model receives.** VERIFIED via `JSONEncoder` on `VoiceCommand.generationSchema`:
- `required: ["intent"]`
- `intent.enum` lists the 5 cases
- the integers carry `minimum`/`maximum`
- `x-order` follows the declaration order

So `intent` is generated first. With `streamResponse` the overlay could show the intent early.

**Token budget.** VERIFIED via `tokenCount`, binary `fm/diag/fmdiag --diag`:

| Part | Tokens |
|---|---|
| Instructions | 233 |
| Schema | 282 |
| Prompt | 29 |
| **Total per call** | **≈ 544** |

`includeSchemaInPrompt: false` plus shorter `@Guide` texts would save about 280 tokens.

**Latency.** The harness measures it per case: one cold call, then 11 warm calls each with `prewarm` and an 800 ms simulated speech gap. **It could not run here.** Estimates (ASSUMED, extrapolated from Apple's published figures of about 0.6 ms per prompt token and about 30 tok/s on an A17, with the M1 Pro faster):

| Situation | Estimate |
|---|---|
| Warm, prewarmed | 0.4 to 1.2 s |
| Cold (model load) | 1.5 to 4 s |

Either way this is **4 to 5 orders of magnitude slower than the rules parser**.

**Expected accuracy.** ASSUMED, not testable here: the model probably handles the 11 inputs well. Known risks of a ~3B model:
- It may "correct" project codes it does not know.
- It may produce letter-spelling mistakes ("we we te").
- It may raise false `guardrailViolation` errors.
- It cannot map "Wartung" to "Maintenance" or "Hollenstein Navigation" to WWT unless the prompt contains the candidates or aliases.

## 4. Deterministic rule parser (VERIFIED: compiled and run)

Sources:
- `spikes/llm/rules/RuleParser.swift`
- `spikes/llm/rules/Resolver.swift`
- `spikes/llm/rules/main.swift` (test harness)

### Pipeline
1. **Fold.** Lowercase, strip diacritics, `ß`→`ss`. Join German thousands groups (`47.285` / `47 285` → `47285`). Hyphens become spaces. Drop punctuation except `+ &`.
2. **Collapse spelling.** Spelled German letters become a code: `we we te`, `weh weh te` and `W W T` → `WWT`; `S und K` and `es und ka` → `S+K`; `ku zett` → `QZ`. Letter names that are also common words (`es, er, en, de, e, …`) only count inside a run that has at least 50 % unambiguous letters.
3. **Intents, in order:**
   - my-tasks phrases (`meine aufgaben`, `bei mir an`, `was steht (heute) an`, …)
   - `ticket|task|aufgabe [nummer] <number>`. Project words may come before or after the number.
   - ordinals `erste…zehnte` (+ `-r/-n/-s/-m`, `letzte` = -1)
   - `nummer|nr|option N`
   - a bare number word
   - while a list is visible, any utterance without an "open" verb counts as a pick by name
   - otherwise `openProject` with the remaining words, after removing filler words
4. **German number words.** The parser matches the longest number part first: `vierhundertzwölf`→412, `siebenundvierzigtausendzweihundertfünfundachtzig`→47285. Digit-by-digit input also works: `vier eins zwei`→412.
5. **Resolver.** It scores the "CODE: Title [TYPE]" names. An exact code anywhere in the query scores +10. A code one edit away (Levenshtein 1) scores +4. Each title word scores +3 (exact), +2 (prefix), +1.5 (one edit away) or -1 (no match). Covering more of the title breaks ties. The resolver returns every project with the top score, together with an `unmatched` word count. That count is the confidence signal.

### Results on the required inputs (11/11 PASS)

Parse times are 11 to 34 µs. The resolver ran against the live project list (GET `/api/v1/projects`, about 60 active projects). The candidate ids below are the invented ids of the fixture.

| Input | Parsed | Resolver |
|---|---|---|
| öffne das WWT Projekt | openProject "wwt" | WWT candidates [314, 693, 315, 628] → list |
| öffne mir mal das we we te projekt | openProject "WWT" | the same WWT candidates → list |
| mach WWT Relaunch auf | openProject "wwt relaunch" | **628** |
| öffne WWT Ticket 412 | openTask "wwt" 412 | all WWT projects (see open issues) |
| zeig mir Ticket 47285 | openTask 47285 | – |
| meine Aufgaben bitte | openMyTasks | – |
| was liegt bei mir an | openMyTasks | – |
| die zweite | select 2 | – |
| nummer drei | select 3 | – |
| nimm Grand Navigation | select "grand navigation" | resolved against the visible candidates |
| öffne S und K Leasing Cockpit | openProject "S+K leasing cockpit" | 1 candidate (S+K Leasing Cockpit) |

### Speech-to-text variants (all as intended)
- "Öffne das WWT-Projekt."
- "W W T"
- "weh weh te"
- "Ticket vierhundertzwölf"
- "Ticket Nummer 47.285"
- "Ticket vier eins zwei"
- "Nummer 2"
- "Die Zweite, bitte."
- "zwei"
- "die letzte"
- "ku zett CRM" → the QZ CRM project
- "zeig mir das Grand Navigation Projekt" → 693
- "Ticket 412 im WWT Relaunch" → task 412 in 628
- "kannst du mir bitte WWT aufmachen"
- "bring mich mal zu dem Relaunch von WWT" → 628

**Throughput:** 17 µs average over 10,000 parses.

### Where rules are not confident or are wrong (VERIFIED)

| Input | Result | Cause |
|---|---|---|
| "Hallo Welt" | 0 candidates | Correctly not confident |
| "zeig mir die Wartung von WWT" | all WWT candidates, `unmatched=1` | German "Wartung" vs English title "Maintenance". Needs a synonym map |
| "öffne das Projekt von Hollenstein Navigation" | Wrongly resolves to 693, `unmatched=1` | Customer name instead of code. Needs aliases from `company_id` → companies |
| "öffne das zweite WWT Projekt" | Ordinal ignored | More than 4 tokens |
| "WKT Relaunch" (mis-hearing of WWT) | Lands on the WKT projects | WKT also exists as a project code |

## 5. Hybrid router (VERIFIED: compiles; the LLM branch is skipped at runtime)

Sources:
- `spikes/llm/hybrid/LLMParser.swift`
- `spikes/llm/hybrid/main.swift`

```swift
func route(_ utterance: String, listVisible: Bool) async -> (Command, Source) {
    let r = rules.parse(utterance, listVisible: listVisible)
    switch r.intent {
    case .openMyTasks, .openTask, .select:
        return (r, .rules)
    // Confident only if the best match consumed every query word.
    case .openProject where resolver.resolve(r.projectQuery ?? "").first.map({ $0.unmatched == 0 }) ?? false:
        return (r, .rules)
    default:
        if let l = await llm.parse(utterance, listVisible: listVisible) { return (l, .llm) }  // 1.5 s budget, nil if unavailable
        return (r, .none)
    }
}
```

The LLM side uses a task group that races `respond` against a `Task.sleep(budget)` timeout. `prewarm` runs on key press.

## 6. Recommendation (UX only)

**Rules first. The LLM fallback is optional and off by default.** Today that effectively means **rules-only**.

- **Latency.** Rules plus resolution take ≤2 ms, which is invisible next to speech-to-text end-of-utterance detection (usually several hundred ms, ASSUMED). The LLM adds an estimated 0.4 to 1.2 s warm and several seconds cold (ASSUMED). That hurts most in the "eins/zwei" selection, which has to be instant. **Never send the selection window to the LLM.**
- **Fast path that only rules allow.** Run the parser on every *partial* transcript. When a list is visible and a partial already matches `die zweite`, `zwei` or `nummer 3`, act at once without waiting for the speech pause. At 17 µs this is free. An LLM cannot run per partial (design ASSUMED, parser speed VERIFIED).
- **Accuracy.** For this narrow command set, rules are deterministic and testable. Most remaining errors are data gaps (synonyms like "Wartung" → "Maintenance", customer-name aliases, codes that sound alike), and the LLM cannot know those without the same data. Bigger accuracy gains (ASSUMED) come from:
  - passing project codes and titles to the speech recogniser as contextual strings
  - a synonym table
  - aliases from AC `company_id` (the field exists on projects, VERIFIED)
- **When the LLM is worth it.** Only for free phrasing with `unmatched > 0` or `unknown`, and only if the user enables Apple Intelligence. The fallback is cheap to keep: it fails in 5 to 7 ms when unavailable (VERIFIED), and `isAvailable` can be checked up front.

## 7. Open issues for the architect

1. **Ticket numbers are per project.** "WWT Ticket 412" matches every WWT project, so the app must look up `task_number=412` in each candidate project (GET only) or show the list.
2. **Ticket without a project.** "Ticket 47285" without a project is most likely a global task ID. The web URL needs `{pid}`, so the app needs an ID → project lookup.
3. **Code collisions and the 1–10 range.** VERIFIED on the live project list:
   - Many codes are shared by several projects.
   - "öffne QZ" returns **more than 10** candidates (all `QZ:` projects plus `QZ Dashboard`), which exceeds the 1–10 selection range. The overlay needs to cap the list or page it.
4. **Name pattern exceptions.** VERIFIED:
   - A few names have no colon or no `[TYPE]`.
   - Some codes are not a plain uppercase acronym: multi-word codes such as "S+K Partner", and codes with `+`, `&` or spaces.
   - The resolver handles multi-word codes through token sequences.

## Files
All under `spikes/llm/`:
- `avail/main.swift` (+ binary `avail/fmavail`)
- `fm/main.swift` (+ `fm/fmintent`)
- `fm/diag/` (schema dump and token counts)
- `rules/{RuleParser,Resolver,main}.swift` (+ `rules/rules`)
- `hybrid/{LLMParser,main}.swift` (+ `hybrid/hybrid`)
- `adv/main.swift` (free-phrasing probes)
- `fm_condensed.swift` (readable copy of the swiftinterface)

Build all of them with `swiftc -O -swift-version 6 …`.

**Compliance:**
- AC access was a single GET on `/api/v1/projects`.
- Nothing in ac-mcp or any other local project was modified.
- No apps were opened, no settings changed, and no permission dialogs appeared.
- Every command ran under an `alarm` timeout, and none timed out.