# AC Voice Stream Deck plugin

One key, "AC Voice", that triggers the AC Voice app and mirrors its state. The app owns all logic; the plugin forwards key edges and paints the snapshots the app pushes.

- Plugin UUID `io.github.nordavid.acvoice.streamdeck`, action `io.github.nordavid.acvoice.streamdeck.voice`, SDK v3, Node 24.
- `ApplicationsToMonitor`: `io.github.nordavid.acvoice` (launch and exit events without polling).
- No choice keys (user decision): a choice is made by voice or by clicking a row in the overlay.

## Key behavior

| Key event | Sent to the app | Meaning (decided by the app) |
|---|---|---|
| keyDown | `press{id, at}` | idle/success/error: listen; listening: end the utterance now (or cancel before speech); choices/processing: cancel |
| keyUp | `release{id, pressId, heldMs}` | `heldMs` >= 600 after speech ends the utterance (push-to-talk) |

When the app is not running, keyDown tries the socket, then runs `open -g -b io.github.nordavid.acvoice` (LaunchServices, so the microphone and Automation permissions belong to AC Voice, not to Stream Deck). The press waits at most 3 s and goes out with its original id and time once the socket accepts; a release that happened meanwhile follows it. The app drops presses older than 3 s anyway (`FlowTimings.stalePress`). `open` exiting with an error status ("Unable to find application") shows "App fehlt"; an `open` that hangs past its 15 s timeout does not, because LaunchServices keeps starting the app.

Every press the app got also gets a release, because the app suspends its end-of-utterance detection while a key is down:
- A key that disappears while held (page or profile switch; Stream Deck sends no keyUp then) sends `release` with `heldMs: 0`. The app resumes its automatic end of utterance instead of cutting the sentence.
- A keyUp while the link is down waits up to 3 s and goes out right after the next `hello`. A restarted app ignores it (pressId mismatch).

Link:
- One persistent connection while a key is visible. Without a visible key the plugin lets go after 1 s, so a page switch with the key on both pages keeps the connection and the face.
- Reconnect with backoff (1 s doubling to 10 s), fast polling for 10 s after a launch or `applicationDidLaunch`.
- Ping every 5 s. No answer within 4 s marks the app as busy (plugin log, property inspector) and nothing else: the key keeps its face, the connection stays, and commands wait in the socket buffer. On a local socket a dead app closes the connection at once; a reconnect would only reach the same stalled process (a Chrome Apple Event, a Keychain or Automation prompt).

## Key faces

Rendered as SVG data URLs (`setImage`), same colors as the overlay orb. `preview/gallery.png` shows all of them (`npm run icons`).

| Face | Look | Animated |
|---|---|---|
| offline | grey orb, "AC", caption "Start" (a press launches the app) | no |
| missing | grey orb, red caption "App fehlt" (LaunchServices found no app) | no |
| launching | grey orb with a cyan spinner, caption "Startet" | yes |
| idle | dim cyan orb with "AC" | no |
| listening | cyan orb with ripples driven by the mic level; a breathing ring while the mic starts | yes |
| processing | violet orb with a rotating arc | yes |
| choices | amber orb with the number of choices and a countdown ring | until the deadline |
| success | green ring and check | no |
| error | red ring and cross, the app's message as a small caption | no |

Animated faces repaint on a 100 ms tick only (at most 10 fps per key, about 1.4 KB per frame); face changes paint at once; identical frames are never sent twice. The key title is off (`UserTitleEnabled: false`).

## Layout

```
src/protocol.ts      IPC v1 codec, mirrors Sources/ACVoiceCore/IPC.swift byte for byte
src/app-link.ts      socket client: queue, launch, reconnect, linger, waiting release, busy detection
src/keys.ts          key edges -> press/release; a held key that disappears gets its release
src/launcher.ts      `open -g -b` via execFile (ACVOICE_TEST_LAUNCHER replaces it in the e2e)
src/view.ts          link events -> View (level smoothing, countdown start)
src/render.ts        View -> SVG faces (pure)
src/painter.ts       setImage policy (dedupe, 10 fps cap, tick only while animating)
src/plugin.ts        Stream Deck SDK glue (the only file that talks to the SDK)
src/icons.ts         static images; scripts/build-icons.ts renders them to PNG with resvg
test/                vitest: protocol fixtures, render, view, painter, keys, app-link with a fake app on a temp socket
test/fixtures/ipc-v1.json   generated from the Swift codec (npm run fixtures)
fake-host/host.mjs   headless e2e: fake Stream Deck host + fake app + launcher stub against the built plugin
io.github.nordavid.acvoice.streamdeck.sdPlugin/   manifest, images, property inspector (ui/voice.html), bin/ (built)
```

## Commands

First time:

```sh
cd streamdeck
npm ci                      # installs the versions in package-lock.json
npm run check               # typecheck, unit tests, build, validate, e2e
npm run link                # streamdeck link io.github.nordavid.acvoice.streamdeck.sdPlugin
```

Then drag "AC Voice" from the "AC Voice" category onto a key. Later changes need only `npm run build` and `npx streamdeck restart io.github.nordavid.acvoice.streamdeck` (or `npm run watch`).

| Script | What it does |
|---|---|
| `npm run build` | rollup bundle into `io.github.nordavid.acvoice.streamdeck.sdPlugin/bin/plugin.js` |
| `npm run typecheck` | `tsc --noEmit` over src, test and scripts |
| `npm test` | vitest (no processes started, no network, sockets in the temp folder) |
| `npm run validate` | `streamdeck validate --no-update-check` (offline) |
| `npm run e2e` | `node fake-host/host.mjs` (needs a build); fails on any ERROR line in the plugin log |
| `npm run icons` | PNG icons (1x/2x) and `preview/gallery.png` |
| `npm run fixtures` | regenerates `test/fixtures/ipc-v1.json` from `IPC.swift` (needs Xcode) |

Test hooks (never set by Stream Deck): `ACVOICE_SOCKET` overrides the socket path, `ACVOICE_TEST_LAUNCHER` replaces `/usr/bin/open` (called with the same `-g -b <bundle id>` arguments).
