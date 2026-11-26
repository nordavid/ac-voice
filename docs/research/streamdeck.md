# ac-voice: Stream Deck plugin and IPC to the Swift menu-bar app

This document uses fantasy names for project codes, company names and distinctive project titles, the same ones as `Tests/Fixtures/projects.sample.json`. Its examples and transcripts follow these names. The real names stay in the git-ignored `Tests/Fixtures/private`. Project, task and user ids are invented as well.

`spikes/` holds unpublished research code and is not part of this repository.

## TL;DR
- **IPC choice:** use a **Unix domain socket with newline-delimited JSON (NDJSON)** at `~/Library/Application Support/ac-voice/ipc.sock`. The native app owns the state machine. The plugin forwards key edges (`press`/`release`/`choose`/`cancel`) and renders the `state` snapshots the app pushes.
- **Cold start:** the plugin runs `open -g -b <appBundleId>` (LaunchServices), queues the press and delivers it once the socket accepts. The manifest's `ApplicationsToMonitor` tells the plugin when the app launches or exits, so it does not need to poll.
- **Transport speed does not decide this.** Every candidate is far below what a person can notice. Measured from keyDown to the new key image: p50 0.6 ms with the full plugin, a Swift server, and a fake Stream Deck host. The real bottleneck is mic and speech startup in the app (ASSUMED).
- **Hotkey fallback:** Carbon `RegisterEventHotKey` in the Swift app. It needs no TCC permission. Registration works on macOS 26.6 (VERIFIED). It delivers press and release, so the same protocol commands work.
- A working plugin skeleton (TypeScript, SDK v3), a Swift Network.framework socket server, a hotkey probe, benchmarks, and an end-to-end test harness are all in `spikes/streamdeck/`. The plugin typechecks, bundles, and passes `streamdeck validate`.

---

## 1. An existing Stream Deck plugin: reusable pattern (all VERIFIED by reading source, `ps`, `ls`)

Another Stream Deck plugin on the same machine served as the reference. This section keeps only the parts that apply to any SDK v3 plugin.

**Install and link**
- `npx streamdeck link <uuid>.sdPlugin` creates a symlink `~/Library/Application Support/com.elgato.StreamDeck/Plugins/<uuid>.sdPlugin -> repo/<uuid>.sdPlugin`.
- Updates only need a rebuild. `npm run watch` runs `rollup -c -w --watch.onEnd="streamdeck restart <uuid>"`.

**Build**
- Rollup bundles `src/plugin.ts` with the typescript, node-resolve (`exportConditions:["node"]`) and commonjs plugins into `<sdPlugin>/bin/plugin.js` (ESM, SDK and `ws` inlined, about 300 KB). It also writes `bin/package.json` with `{"type":"module"}`.
- tsconfig: ES2023, `moduleResolution: Bundler`, `customConditions:["node"]`, TC39 decorators (no `experimentalDecorators`).
- Dependencies: `@elgato/streamdeck@3.0.4`, `@elgato/utils`, dev `@elgato/cli`, `@resvg/resvg-js` (icon and gallery PNGs), vitest, tsx.

**Runtime**
- Stream Deck 7.6.1 spawns `~/Library/Application Support/com.elgato.StreamDeck/NodeJS/24.22.1/node --no-global-search-paths --enable-source-maps <plugin>/bin/plugin.js -port N -pluginUUID … -registerEvent registerPlugin -info {json}`.
- The working directory is the `.sdPlugin` folder. The SDK reads `manifest.json` from there.
- `info` reports device "Stream Deck" 5x3, type 0, devicePixelRatio 2. Logs go to `<sdPlugin>/logs/<uuid>.N.log`.
- The running reference plugin uses about 25 MB RSS.
- Node 24.22.1 has global `WebSocket` and `fetch`. `EventSource` is undefined.

**Rendering**
- Pure functions `(state, now, frame) -> SVG string` at 144x144.
- A `Painter` keeps the last SVG per key and calls `key.setImage("data:image/svg+xml;charset=utf8,"+encodeURIComponent(svg))` only when the face changed.
- A 500 ms tick drives animation (opacity pulse, rotating dot).
- The source comment notes the Stream Deck SVG engine limits: basic shapes, paths, text and solid colors with opacity attributes. No filters, masks, CSS or rgba().
- A build script renders the default key SVGs, marketplace PNGs and a preview gallery with resvg. A dev page provides a virtual deck in the browser.

**Key handling**
- `SingletonAction` subclasses with `@action({UUID})`. `onWillAppear` registers `ev.action` (KeyAction) with the Painter.
- `PressTracker` sets a 550 ms timer to tell short from long presses. The action fires on keyUp.

**Talking to other processes**
- An HTTP server on a fixed `127.0.0.1` port. Clients must send a custom header, which forces a CORS preflight. A Host-header check blocks DNS rebinding.
- `execFile` runs system tools such as `open` and `osascript`.
- The README states that keystrokes and Automation need TCC permission for **"Stream Deck"**. Anything the plugin process does is attributed to Stream Deck. This matters for ac-voice (see 3.6).

**What to reuse for ac-voice:** the repo layout, rollup/tsconfig, the `link` and `watch` scripts, the Painter dedupe, the pure SVG renderers with a resvg gallery, and a fake host or virtual deck for development.

**What changes:**
- Fire on **keyDown**, not keyUp. This saves the press duration.
- Long press becomes `release{heldMs}`, and the app decides what it means.
- The animation tick runs at 100 ms and only while something animates.
- No TCP port.

## 2. Plugin "ac-voice" (built; typecheck, bundle and validate VERIFIED)

**Identifiers (proposed)**
- Plugin UUID `io.github.nordavid.acvoice`.
- Actions `io.github.nordavid.acvoice.voice` and `io.github.nordavid.acvoice.choice`.
- App bundle id `io.github.nordavid.acvoice.app`.

**Manifest excerpt** (validated offline: `streamdeck validate --no-update-check` reported "Validation successful", VERIFIED):
```json
"SDKVersion": 3, "Nodejs": { "Version": "24", "Debug": "enabled" },
"OS": [{ "Platform": "mac", "MinimumVersion": "13" }],
"UUID": "io.github.nordavid.acvoice",
"ApplicationsToMonitor": { "mac": ["io.github.nordavid.acvoice.app"] },
"Actions": [ { "UUID": "io.github.nordavid.acvoice.voice", "Controllers": ["Keypad"], "UserTitleEnabled": false, ... },
             { "UUID": "io.github.nordavid.acvoice.choice", ... } ]
```
`streamDeck.system.onApplicationDidLaunch/Terminate` exist in SDK 3.0.4, and `ev.application` is the bundle id (VERIFIED in the .d.ts files).

**Voice key behavior**
- keyDown sends `press`. keyUp sends `release{heldMs}`.
- A tap starts listening, and VAD ends the utterance.
- Pressing again while listening means "done now".
- Pressing during choices cancels.
- A hold of 600 ms or more acts as push-to-talk and ends the utterance on release.
- The app interprets all of this, so the Stream Deck key, the hotkey and the menu bar item behave the same.

**Choice keys (optional, implemented)**
- Up to N keys next to the voice key. They are numbered in reading order per device, so no property inspector is needed.
- During `choices` they light up with "1 / Relaunch" and a countdown bar. Pressing one sends `choose{index}`.
- Pressing a key is faster than speaking a number.
- Alternative: `switchToProfile(deviceId, profile)` exists, but it only switches to profiles bundled in the manifest (VERIFIED in the d.ts). A temporary "choice pad" profile is possible as a v1.1 option.

**Faces** (all rendered, see `preview/gallery.png`):

| Face | Content |
|---|---|
| offline | grey mic, "Offline" |
| App fehlt | red label |
| launching | spinner, "Startet …" |
| idle | white mic, "AC Voice" |
| listening (mic starting) | dim ring |
| listening | pulsing cyan frame, 9-bar scrolling waveform from `level`, transcript tail "…WWT-Projekt" |
| processing | rotating arc |
| choices | amber frame, count "4", countdown ring, "Sag 1-4" |
| success | green check and message |
| error | red cross and message |

User-facing strings are German, code comments English.

**Paint policy**
- A face is painted immediately on every state change.
- `level` messages (15 Hz) only update a buffer. The 100 ms tick paints it.
- The tick runs only while the view is animated.
- Measured in the end-to-end test: **11.4-12 setImage/s while listening, about 1.86 KB per data URL**.
- Whether real hardware sustains 10 fps is ASSUMED. Fallback: a 200 ms tick.

**Cold-path core** (`plugin/src/app-link.ts`, compiles):
```ts
press(): void {
  const at = Date.now();
  if (this.#send({ v: 1, t: "press", id: this.#id(), at })) return;        // warm: <1 ms
  if (this.#status === "launching" && this.#queuedPress) return;           // one launch only
  this.#queuedPress = { at };
  this.#setStatus("launching");
  this.#launchUntil = at + QUEUED_PRESS_TTL_MS;                            // 10 s
  this.launch().then(() => this.#scheduleRetry(0), (e: Error) => {         // `open -g -b <bundle>`
    this.#queuedPress = undefined; this.#launchUntil = 0;
    this.#setStatus("offline", "App fehlt");
  });
}
// on 'connect': send hello, then the queued press if younger than the TTL.
// on 'close': 50 ms retries while launching, otherwise backoff 1 s -> 10 s, only while a key is visible.
```

## 3. IPC decision

### 3.1 Measurements
All VERIFIED. Client: Stream Deck's own Node 24.22.1. Sequential ping/pong, n=2000 after 200 warm-up rounds, M1 Pro.

| Transport | p50 | p99 | Connect | Notes |
|---|---|---|---|---|
| **UDS NDJSON to Swift NWListener** | **0.042 ms** | **0.086 ms** | 1.0-1.2 ms | the real target stack, includes JSONDecoder |
| UDS NDJSON to Node server | 0.012-0.015 ms | 0.05-0.07 ms | 1.3 ms | |
| TCP NDJSON 127.0.0.1 | 0.042 ms | 0.072 ms | 0.7 ms | |
| WebSocket (Node global WebSocket to `ws`) | 0.053 ms | 0.110 ms | **31 ms** first connect | |
| HTTP POST (fetch, keep-alive) | 0.161 ms | 1.30 ms | - | max 21 ms |
| HTTP POST then SSE push | 0.175 ms | 0.55 ms | - | Node 24 has no EventSource, so it needs a hand-written parser |
| Spawn helper then DistributedNotificationCenter | 6.5 ms | p95 9.3 ms | - | one-way. Node needs a helper binary per command |
| `/usr/bin/open -g -b <unknown>` (fails at lookup) | 6.8 ms | max 13 ms | - | lower bound for URL-scheme or `open` triggers. Real delivery to an app is ASSUMED to take 20-100 ms or more |
| Detect a dead app: ENOENT / ECONNREFUSED (stale file) | 0.021 / 0.020 ms | | | instant and unambiguous |

### 3.2 Comparison and verdict

- **UDS + NDJSON (recommended)**
  - Bidirectional and persistent, with the lowest latency.
  - Unreachable from browsers. A Chrome page can open `ws://127.0.0.1:port` with no CORS, and can CSRF a simple POST. Either would switch on the microphone.
  - Filesystem permissions are the authentication: `~/Library` is 0700 (VERIFIED) and the socket is chmod 0600.
  - No port collisions. Other local tools, such as the reference plugin, already hold fixed ports.
  - No Application Firewall involvement. With ALF enabled, a locally signed Swift app with a TCP listener might still prompt (ASSUMED).
  - A crashed app is reported immediately via `close` / ECONNREFUSED. No heartbeat is needed.
  - Debug with `nc -U`.
  - Swift: Network.framework `NWListener` on `.unix(path:)` works (VERIFIED).
- **localhost WebSocket:** close second. It needs an Origin check plus a token file, port management, a 31 ms first connect, and ALF exposure.
- **HTTP + SSE:** two channels, a hand-written SSE parser, and the same browser exposure.
- **URL scheme `ac-voice://press`:** one-way with no state back. It may activate the app. Still useful as a secondary trigger for Raycast, Shortcuts or Alfred (optional `CFBundleURLTypes`). Not used by the plugin.
- **Distributed Notifications:** Node cannot post or observe them without a helper or native addon. One-way, best-effort delivery. Rejected.

**Gotcha (VERIFIED):** macOS `sun_path` is limited to 104 bytes. A 150-byte path fails with `EINVAL` on listen and connect.

| Socket path | Length | Status |
|---|---|---|
| `~/Library/Application Support/ac-voice/ipc.sock` | home path + about 50 bytes | OK |
| Sandbox container path | home path + about 95 bytes | **fails** with a typical home path |
| Group Container | home path + about 70 bytes | OK |

So the app must run **unsandboxed**, which is fine with Developer ID or Apple Development signing. Alternatively, keep the socket path short.

### 3.3 Protocol v1
Socket at `~/Library/Application Support/ac-voice/ipc.sock`: the app creates the directory with 0700, `unlink()`s the old socket file before bind, then chmods it 0600. One UTF-8 JSON object per `\n`, max 64 KB per line, `v:1`, unknown `t` values ignored. Types are in `plugin/src/protocol.ts` and mirrored in `swift/IPCServer.swift`.

Plugin to app:
```jsonc
{"v":1,"t":"hello","client":"streamdeck","version":"0.1.0"}
{"v":1,"t":"press","id":"sd-7","at":1732440000000}      // key down; meaning depends on the app's phase
{"v":1,"t":"release","id":"sd-8","heldMs":812}           // >=600 while listening = push-to-talk end
{"v":1,"t":"choose","id":"sd-9","index":2}               // choice key
{"v":1,"t":"cancel","id":"sd-10"}
{"v":1,"t":"ping","id":"sd-11"}
```

App to plugin:
```jsonc
// Full snapshot. Sent on every connect (so reconnects render correctly) and on every change.
// The plugin drops seq <= last seq.
{"v":1,"t":"state","seq":6,"phase":"choices","since":1732440001234,
 "transcript":"Öffne das WWT-Projekt","deadline":1732440006234,
 "choices":[{"n":1,"label":"Relaunch","detail":"WWT: Website Relaunch [AGIL]"}, ...]}
// phase: idle|listening|processing|choices|success|error
// listening adds "micReady": false|true; success/error add "message".
{"v":1,"t":"level","rms":0.42}     // ~15 Hz while listening, not part of the snapshot
{"v":1,"t":"pong","id":"sd-11"}
```

`press` transitions owned by the app (as implemented in the fake app):

| Phase when pressed | Result |
|---|---|
| idle / success / error | listening |
| listening | processing (end the utterance now) |
| choices | idle (cancel) |
| processing | ignored |

During `choices` the app keeps the mic open until `deadline` for "eins" or "Relaunch". `choose` from a key ends it immediately. The app should send short `label`s of 12 characters or fewer. The plugin truncates with an ellipsis.

Plugin-only link status: `offline` (pressing launches the app), `launching`, `online`.

### 3.4 Swift server core
VERIFIED: compiles with `swiftc -swift-version 6`, Swift 6.4.2, macOS 26.6 SDK, and serves the Node plugin. Full file: `swift/IPCServer.swift`.

```swift
unlink(path)                                        // stale file after a crash
let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
let listener = try NWListener(using: params)
listener.newConnectionHandler = { conn in MainActor.assumeIsolated { self.accept(conn) } }
listener.stateUpdateHandler = { st in MainActor.assumeIsolated { if case .ready = st { chmod(self.path, 0o600) } } }
listener.start(queue: .main)
// accept(): on .ready send the current state snapshot; receive loop splits client.buffer on 0x0A.
// The per-connection holder must be `@MainActor final class Client`. A plain class fails the
// Swift 6 Sendable-capture check (VERIFIED compiler error).
```

### 3.5 End-to-end test (VERIFIED)
Setup:
- `fake-host/host.mjs` acts as a fake Stream Deck: a WebSocket host using the same Node binary and command-line arguments as the real one.
- It runs the bundled `plugin.js`, with `swift/ipc-server` playing the app over the socket.
- The app's scripted flow: listening → transcript → processing → 4 WWT choices → success → idle.

| Measurement | Result |
|---|---|
| Warm keyDown to "listening" face | p50 **0.61 ms**, max 3.3 ms (n=30) |
| keyDown while listening to "processing" | p50 1.7 ms |
| Hold-to-talk keyUp to "processing" | 2.1 ms |
| Choice key to "success" | 1.0-2.6 ms |
| Cold start: keyDown to "launching" face | 2.5-3.2 ms |
| Cold start: keyDown to "listening" (with a 300 ms simulated launch) | 359-367 ms, of which about 50 ms is retry granularity |
| App killed with SIGKILL to "offline" face | 1.2 ms |
| External app start plus `applicationDidLaunch` to reconnected "idle" | 54 ms |
| App not installed (real `open -g -b invalid…`, exit 1, no dialog seen) to "App fehlt" | 10.5 ms |

- Face sequence: offline > launching > idle > listening(mic starting) > listening > processing > choices > success > idle.
- Fixed during testing: an "Offline" flash between connect and the first snapshot.
- Remaining: a roughly 1 ms "idle" frame on cold start, because the snapshot arrives before the queued press is answered. Not visible. It can be suppressed if wanted.

### 3.6 Architectural rules from this
- **Permissions belong to the app.** Microphone, Speech, and Apple Events to Chrome must live in the app. The app must be started by LaunchServices (`open -b`), never spawned by the plugin. Otherwise TCC treats Stream Deck as the "responsible process" and asks for **Stream Deck**. ASSUMED from documented TCC behavior; the reference plugin's README describes Accessibility and Automation prompts for "Stream Deck", which shows this attribution.
- **Register the app as a login item** (`SMAppService.mainApp`) so the cold path is rare.
- **The overlay must be a non-activating `NSPanel`** so Chrome keeps focus until the app opens the URL. ASSUMED, app side.
- **Optional hardening:** read the peer's audit token on accept (`LOCAL_PEERTOKEN`) and log or verify it. ASSUMED. The risk is low, because a same-user process that triggers listening is visible through the overlay and the system mic indicator.

## 4. Fallback trigger without a Stream Deck

**Recommended: a global hotkey via Carbon `RegisterEventHotKey`** in the Swift app (`swift/GlobalHotkey.swift`, compiles in Swift 6 mode, VERIFIED).
- It is system-wide, swallows the key combo, and delivers `kEventHotKeyPressed` and `kEventHotKeyReleased`. These map 1:1 to `press` and `release{heldMs}`, so tap and hold-to-talk both work.
- **Permission: none.** No Accessibility or Input Monitoring is needed, unlike `NSEvent.addGlobalMonitorForEvents` (needs Accessibility, cannot swallow keys) or `CGEventTap` (needs Input Monitoring). Both of those are rejected.
- Probe on macOS 26.6 (VERIFIED, each combo registered and immediately released): ⌃⌥⌘F19, ⌥F19, ⌥⇧F19, ⌃⌥Space, ⌃F19, F19, ⌥K, ⌥⇧K, ⌃⌥K and ⌥Space all returned `noErr` with no entitlements.
- Actual event delivery needs a physical key press and was not tested. Option-only combos are reported to be restricted since macOS 15 (ASSUMED), so avoid them.
- **Default proposal: ⌃⌥Space**, configurable in the app.
  - On this Mac the system shortcuts ⌃Space (id 60) and ⌃⌥Space (id 61) are **disabled**, while ⌘Space (Spotlight) and ⌥⌘Space (Finder search) are enabled (VERIFIED via `com.apple.symbolichotkeys`).
  - ⌃⌥Space is the macOS default for "next input source" on other machines, so it must stay configurable.

```swift
let hk = try GlobalHotkey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { edge in
    edge == .pressed ? stateMachine.press(source: .hotkey) : stateMachine.release(heldMs: …)
}
```

Further triggers, all free:
- clicking the menu-bar item;
- an optional `ac-voice://press` URL scheme for Raycast or Shortcuts;
- Stream Deck's built-in "Hotkey" action sending ⌃⌥Space. That one needs no plugin but shows no live state (ASSUMED to work with Carbon hotkeys).

## 5. Open points for the user and the architect
1. **Identifiers:** confirm the bundle ids (`io.github.nordavid.acvoice` / `.app`) and that the app ships unsandboxed (socket path, Apple Events to Chrome).
2. **Choice keys:** should they be permanent keys next to the voice key, or a temporary bundled profile via `switchToProfile`?
3. **Hardware frame rate:** measure the setImage rate on the real deck (10 fps is ASSUMED to be fine; the reference plugin uses 2 fps).
4. **Where the latency goes:** it is in the app (audio engine start, speech model warm-up, Chrome tab reuse), not the IPC. The app should send `listening{micReady:false}` immediately and `micReady:true` once audio flows. The key and overlay show the difference, and an earcon when the mic goes live is advisable.

## Files
All under `spikes/streamdeck/`.

Plugin:
- `spikes/streamdeck/plugin/src/protocol.ts`
- `spikes/streamdeck/plugin/src/app-link.ts`
- `spikes/streamdeck/plugin/src/render.ts`
- `spikes/streamdeck/plugin/src/plugin.ts`
- `spikes/streamdeck/plugin/io.github.nordavid.acvoice.sdPlugin/manifest.json` (plus built `bin/plugin.js` and `imgs/`)
- `spikes/streamdeck/plugin/scripts/build-icons.ts`
- `spikes/streamdeck/plugin/preview/gallery.png` (all faces)
- `spikes/streamdeck/plugin/package.json`, `tsconfig.json` and `rollup.config.mjs` in the same folder.
- The spike borrowed the `node_modules` of another local plugin read-only for tsc, rollup, tsx and the CLI. A real repo needs `npm ci`.

Swift:
- `spikes/streamdeck/swift/IPCServer.swift` (plus `ipc-server` binary)
- `spikes/streamdeck/swift/GlobalHotkey.swift` (plus `hotkey-probe`)
- `spikes/streamdeck/swift/DNProbe.swift` (plus `dn-probe`)

Benchmarks:
- `spikes/streamdeck/ipc-bench/servers.mjs`
- `spikes/streamdeck/ipc-bench/bench.mjs`
- `spikes/streamdeck/ipc-bench/dn-bench.mjs`

End-to-end harness:
- `spikes/streamdeck/fake-host/host.mjs` (run with Stream Deck's Node; `--missing` runs the app-not-installed case).

**Compliance**
- Nothing was installed into the Stream Deck plugins folder.
- No AC API calls were made. Chrome was not touched and no apps were opened.
- Other local repositories and the reference plugin are unchanged in content.
