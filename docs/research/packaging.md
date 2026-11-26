# ac-voice: packaging, permissions, overlay, Chrome control. Report

Working folder: `spikes/packaging`. `spikes/` holds unpublished research code and is not part of this repository.
Environment (VERIFIED): macOS 26.6, **Xcode 27.2**, Swift 6.4.2, `PackageDescription` has `.macOS(.v26)`/`.v27`. Chrome is installed and ships a static `scripting.sdef`.

## 0. CRITICAL: the Apple Development certificate is revoked
- VERIFIED: the only identity (`<sha1>`, "Apple Development: <account> (<team id>)", not yet expired) is **revoked**. `security verify-cert -p codeSign -R ocsp -R require` returns `CSSMERR_TP_CERT_REVOKED`.
- VERIFIED: an app signed with this cert, with or without hardened runtime, does not launch. `open` fails with `RBSRequestErrorDomain 5 / POSIX 163 "Launchd job spawn failed"`. The amfid log shows `Trust evaluate failure: [leaf Revocation4]`, AMFI -420, "Broken signature with Team ID fatal".
- VERIFIED: the first `codesign` with this cert worked, and so did `codesign --verify` and `find-identity -v`. After trustd cached the OCSP answer, `codesign` itself failed and `find-identity` tagged the cert `(CSSMERR_TP_CERT_REVOKED)`. It still prints "1 valid identities found".
- **Action for the user:** Xcode > Settings > Accounts > Manage Certificates > "+" > Apple Development, then delete the revoked cert from the login keychain. ASSUMED: the new cert keeps the CN "Apple Development: <account> (<team id>)", so the designated requirement (DR) and any TCC grants still match.
- **Fallback (VERIFIED end to end):** a self-signed code-signing cert. I created one with openssl in an isolated keychain inside my folder. It signed with hardened runtime and both entitlements, AMFI accepted it, and the app launched. Its DR is `identifier "<bundle id>" and certificate leaf = H"<sha1>"`, which stays the same across rebuilds as long as the cert does. For the user's setup: Keychain Access > Certificate Assistant > Create a Certificate (Self-Signed Root, type Code Signing), in the login keychain. ASSUMED: codesign asks for key access once ("Always Allow").
- VERIFIED: codesign finds an identity only in a keychain on the user search list. `--keychain <file>` alone gives "no identity found". The untrusted self-signed cert (`CSSMERR_TP_NOT_TRUSTED`) still signs fine.
- VERIFIED: ad-hoc signing (`-s -`) launches, but its DR is `cdhash H"…"`, which changes with every code change. ASSUMED (well known): TCC prompts again after each rebuild, so ad-hoc is not acceptable for development.

## 1. Build pipeline without .xcodeproj (VERIFIED)
Layout: `Package.swift` (tools 6.2, `.macOS(.v26)`) with targets `ACVoiceShared` (lib), `HelloMenuBar` (SwiftUI `App` + `MenuBarExtra`), `OverlayDemo` (AppKit `main.swift` + NSPanel) and `ASBench` (CLI).

Script `scripts/bundle.sh` (VERIFIED: builds, signs, and the apps launch). Usage: `scripts/bundle.sh <Product> <BundleID> <AppName> [url-scheme]`.
```bash
#!/bin/bash
set -euo pipefail
PRODUCT="${1:?product}"; BUNDLE_ID="${2:?bundle id}"; APP_NAME="${3:?app name}"; URL_SCHEME="${4:-}"
CONFIG="${CONFIG:-release}"; HARDENED="${HARDENED:-1}"
PKG="$(cd "$(dirname "$0")/.." && pwd)"; OUT="${OUT:-$PKG/dist}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ && !/REVOKED/ {print $2; exit}')}"
[ -n "$SIGN_ID" ] || { echo "no Apple Development identity found" >&2; exit 1; }
# OCSP revocation pre-check (find-identity/codesign --verify don't check; AMFI does at launch)
if [[ "$SIGN_ID" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  PEM="$(security find-certificate -a -Z -p 2>/dev/null | awk -v h="$(echo "$SIGN_ID" | tr a-f A-F)" '
    /^SHA-1 hash:/ { on = ($3 == h) } on { print } /END CERTIFICATE/ { if (on) exit }' | sed -n '/BEGIN/,/END/p')"
  if [ -n "$PEM" ]; then TMP_PEM="$(mktemp)"; echo "$PEM" > "$TMP_PEM"
    VERIFY_OUT="$(security verify-cert -c "$TMP_PEM" -p codeSign -R ocsp -R require 2>&1 || true)"   # '|| true': pipefail trap
    [[ "$VERIFY_OUT" == *REVOKED* ]] && { echo "ERROR: signing certificate $SIGN_ID is revoked" >&2; rm -f "$TMP_PEM"; exit 2; }
    rm -f "$TMP_PEM"; fi
fi
VERSION="${VERSION:-0.1.0}"; BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
swift build --package-path "$PKG" -c "$CONFIG" --product "$PRODUCT"
BIN_DIR="$(swift build --package-path "$PKG" -c "$CONFIG" --show-bin-path)"
APP="$OUT/$APP_NAME.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Info.plist via heredoc: CFBundleIdentifier/Name/DisplayName/Executable, CFBundlePackageType APPL,
# CFBundleShortVersionString/Version, LSMinimumSystemVersion 26.0, LSUIElement true, NSHighResolutionCapable,
# NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription, NSAppleEventsUsageDescription (German texts),
# optional CFBundleURLTypes/CFBundleURLSchemes; then plutil -lint; PkgInfo "APPL????"
SIGN_ARGS=(--force --sign "$SIGN_ID" --timestamp=none)
[ -n "${SIGN_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
if [ "$HARDENED" = "1" ]; then  # entitlements: com.apple.security.device.audio-input, com.apple.security.automation.apple-events
  SIGN_ARGS+=(--options runtime --entitlements "$OUT/$PRODUCT.entitlements"); fi
codesign "${SIGN_ARGS[@]}" "$APP"; codesign --verify --strict --verbose=1 "$APP"
```
(The full spike file, including the Info.plist and entitlements heredocs, is at `spikes/packaging/scripts/bundle.sh`. The repository's own `scripts/bundle.sh` grew out of it.)

Results (VERIFIED):
- Incremental `bundle.sh` run takes about 3.4 s. A clean release build of all targets takes about 20 s.
- Hello menu-bar app (`io.github.nordavid.acvoice.probe`, self-signed, hardened runtime with both entitlements): started via `open -g`, `policy=1` (accessory, from LSUIElement), `active=false`, quit itself after the timer. Process gone afterwards.
- Launch latency: first launch after signing is about 1.0 s from `open` to `didFinishLaunching`. Warm launches take 267–280 ms. **So the app must stay resident.** Do not launch it on each key press.
- DR stability: with the Apple cert, a rebuild with changed code gives a new CDHash and an identical DR, and `codesign --verify -R=<old DR>` passes. Note: a comment-only change produces a byte-identical binary.
- TCC reads do not prompt: `AVCaptureDevice.authorizationStatus(.audio)=0`, `SFSpeechRecognizer.authorizationStatus()=0`, `SMAppService.mainApp.status=3 (.notFound, because the app sits in /tmp)`.
- SwiftPM resources: the generated `Bundle.module` accessor checks `Bundle.main.resourceURL` first, so copying `*.bundle` into `Contents/Resources` is correct.

Entitlements and runtime:
- Hardened runtime is not required for a local, non-notarized app. I recommend `HARDENED=1` anyway with `com.apple.security.device.audio-input` and `com.apple.security.automation.apple-events`. The app then stays ready for Developer ID notarization. VERIFIED: it launches with a self-signed cert and no provisioning profile is needed.
- ASSUMED (Apple docs): without these entitlements under hardened runtime, microphone access and Apple Events fail silently.
- VERIFIED: `AEDeterminePermissionToAutomateTarget` returns -1744 with or without the apple-events entitlement. A preflight check therefore cannot detect a missing entitlement.
- Speech: no entitlement, only `NSSpeechRecognitionUsageDescription` (ASSUMED). No App Sandbox.

xcodebuild versus script: I recommend the script. Xcode can open `Package.swift` directly for editing, debugging and previews. A generated or hand-made `.xcodeproj` pays off only for extensions, widgets, asset catalogs or an archive/notarize pipeline (ASSUMED). An icon also works without a project: `iconutil` → `.icns` + `CFBundleIconFile`, or `xcrun actool`.

## 2. Overlay (VERIFIED compile and run, each run about 3 s)
Code: `Sources/ACVoiceShared/OverlayPanel.swift`.
```swift
public final class OverlayPanel: NSPanel {
  public init(contentView view: NSView) {
    super.init(contentRect: .init(x: 0, y: 0, width: 560, height: 120),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false) // nonactivating at init
    isFloatingPanel = true; level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false; backgroundColor = .clear; hasShadow = true
    hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = true; isMovable = false
    isReleasedWhenClosed = false; animationBehavior = .utilityWindow; ignoresMouseEvents = false
    contentView = view
  }
  override public var canBecomeKey: Bool { false }
  override public var canBecomeMain: Bool { false }
  public static func activeScreen() -> NSScreen {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
  }
  public func place(size: NSSize, on screen: NSScreen = OverlayPanel.activeScreen()) {
    let vf = screen.visibleFrame; let top = vf.maxY - vf.height * 0.25   // top edge pinned, grows downward
    setFrame(.init(x: (vf.midX - size.width/2).rounded(), y: (top - size.height).rounded(),
                   width: size.width, height: size.height), display: true)
  }
}
// Glass: NSGlassEffectView (macOS 26) with an NSHostingView as contentView, or SwiftUI .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
// Show: panel.orderFrontRegardless() + alpha fade 0.15 s
```
Run results (VERIFIED, both the AppKit `NSGlassEffectView` and the SwiftUI `.glassEffect` variant):
- The frontmost app stayed unchanged (Chrome before, during and after). `NSApp.isActive=false`, `isKeyWindow=false`.
- Window-server layer 3 (`.floating`), `isOnActiveSpace=true`, 2 screens detected, panel placed on the screen under the mouse.
- Geometry checks out: x=1000 for width 560 on a 2560-wide screen. The top edge sits at 25% of `visibleFrame`, and the panel grew downward from 64 pt to 207 pt when the 4 candidates appeared.
- Glass looks: NOT verified. A screenshot would need Screen Recording permission, so I avoided it.

Gotchas:
- (VERIFIED) `CGWindowListCopyWindowInfo` returns the old height if read in the same run-loop turn as `setFrame`.
- (ASSUMED) Setting `.nonactivatingPanel` after init does not take effect reliably.
- (ASSUMED) Keep `hidesOnDeactivate=false`, otherwise the panel hides after a menu-bar click.
- Keyboard: `canBecomeKey=false` means no Esc. Cancel instead with a second key tap, the word "abbrechen" or a timeout. A typed fallback would need `canBecomeKey=true`. A non-activating panel can become key without activating the app (ASSUMED), but it then takes focus.
- Click-through: set `ignoresMouseEvents=true` for a pure HUD. Clickable candidates may need an `NSHostingView` subclass with `acceptsFirstMouse` returning true (ASSUMED).
- Multiple monitors: use the screen under the mouse, because `NSScreen.main` is ambiguous for an inactive agent app (ASSUMED). Re-place on `didChangeScreenParametersNotification`.
- Full-screen apps: needs accessory/LSUIElement + `.fullScreenAuxiliary` (ASSUMED). If something covers the panel, raise to `.statusBar`.
- Speed: create the panel once at launch and only order it in and out.
- Fallback material: `NSVisualEffectView(.hudWindow, .behindWindow, state: .active)`.

## 3. Chrome control
Script: `support/open-ac.applescript`. It is compiled with `osacompile` to `support/open-ac.scpt` (VERIFIED, 0.38 s) and embedded in Swift as `OpenACScript.generated.swift`. NSAppleScript also compiles it in 32 ms (VERIFIED, Chrome terms resolve from the static sdef). **It never ran against Chrome**, so its runtime behavior is ASSUMED.
```applescript
on run argv
	return openac(item 1 of argv, "https://ac.example.com")
end run
on openac(targetURL, acOrigin)
	tell application id "com.google.Chrome"
		set winCount to count of windows
		if winCount is 0 then
			make new window
			set URL of active tab of window 1 to targetURL
			activate
			return "newwindow"
		end if
		set winIDs to id of every window                -- bulk reads: 1 event each
		set urlLists to URL of every tab of every window
		set activeIdx to active tab index of every window
		set hitWin to 0
		set hitTab to 0
		repeat with wi from 1 to winCount               -- pass 1: active tab already AC
			set u to item (item wi of activeIdx) of (item wi of urlLists)
			if my isAC(u, acOrigin) then
				set hitWin to wi
				set hitTab to item wi of activeIdx
				exit repeat
			end if
		end repeat
		if hitWin is 0 then                             -- pass 2: any AC tab, front-most window first
			repeat with wi from 1 to winCount
				set tabURLs to item wi of urlLists
				repeat with ti from 1 to count of tabURLs
					if my isAC(item ti of tabURLs, acOrigin) then
						set hitWin to wi
						set hitTab to ti
						exit repeat
					end if
				end repeat
				if hitWin is not 0 then exit repeat
			end repeat
		end if
		if hitWin is not 0 then
			tell window id (item hitWin of winIDs)      -- id, not index: index shifts on reorder
				set URL of tab hitTab to targetURL
				set active tab index to hitTab
				if minimized then set minimized to false
				set index to 1
			end tell
			activate
			return "reused"
		end if
		tell window 1
			make new tab with properties {URL:targetURL}
			if minimized then set minimized to false
		end tell
		activate
		return "newtab"
	end tell
end openac
on isAC(u, acOrigin)
	if u is missing value then return false
	return (u is acOrigin) or (u starts with (acOrigin & "/"))
end isAC
```
Calling it from Swift (`Sources/ACVoiceShared/ChromeOpener.swift`, compiles):
- Compile one `NSAppleScript` at startup. Call the handler through an Apple Event with no recompile and no string injection:
```swift
let ev = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
         targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
ev.setDescriptor(NSAppleEventDescriptor(string: "openac"), forKeyword: AEKeyword(keyASSubroutineName)) // lowercase!
let l = NSAppleEventDescriptor.list(); l.insert(.init(string: url), at: 1); l.insert(.init(string: origin), at: 2)
ev.setDescriptor(l, forKeyword: AEKeyword(keyDirectObject))
var err: NSDictionary?; let r = script.executeAppleEvent(ev, error: &err)   // err[NSAppleScript.errorNumber] == -1743 → denied
```
- If Chrome is not running, the Swift code skips Apple Events entirely and uses `NSWorkspace.open([url], withApplicationAt: chromeURL, configuration:)`. That means no TCC prompt. The same path is the fallback after -1743.

Latency (VERIFIED with `ASBench`, no external events):
| Path | Cost |
|---|---|
| NSAppleScript first compile (OSA component load) | 105 ms, one time, do it at startup |
| Real script compile | 32 ms |
| Warm handler-call overhead | 0.03 ms median |
| `osascript` subprocess with `.scpt` | 65–67 ms median, 136 ms max, per call |

- Recommendation: in-process NSAppleScript on the main thread. ASSUMED (Apple docs): NSAppleScript is main-thread only. The Chrome round trips (5–7 events) are ASSUMED to take a few ms each.
- ASSUMED: setting the URL on an existing tab fully reloads the AC single-page app. Client-side navigation would need "Allow JavaScript from Apple Events" in Chrome, which is off by default.

Automation permission flow:
1. Required: the Info.plist key `NSAppleEventsUsageDescription`, plus `com.apple.security.automation.apple-events` when hardened runtime is on.
2. VERIFIED: `AEDeterminePermissionToAutomateTarget(chrome, typeWildCard, typeWildCard, askUserIfNeeded:false)` returns `-1744` (not determined) without a prompt.
3. From the SDK header: the target must be running (otherwise -600), and the call must not run on the main thread when `ask:true`.
4. Plan: an onboarding step calls `ask:true` on a background queue while Chrome runs. This shows the "AC Voice wants to control Google Chrome" prompt. ASSUMED: otherwise the first voice command blocks the main thread on the prompt.
5. ASSUMED: after a denial, every call fails with -1743 and no new prompt. Show a hint pointing to Privacy & Security > Automation. Reset with `tccutil reset AppleEvents io.github.nordavid.acvoice`.
6. Avoid `System Events`/AXRaise for raising windows, because it needs an Accessibility grant. Known risk (ASSUMED): `set index to 1` does not always raise the right window when there are several.

## 4. Autostart
- **Recommendation: `SMAppService.mainApp.register()`**, behind an "Beim Anmelden starten" toggle. Install the app in `~/Applications`. Code: `Sources/ACVoiceShared/LaunchAtLogin.swift` (compiles, never registered).
- ASSUMED: SMAppService shows up under Login Items with the app name and sends a one-time notification. It needs no plist. LaunchServices starts the app, so TCC attribution is correct.
- VERIFIED: an app under /tmp reports `.notFound`.
- LaunchAgent alternative: `support/io.github.nordavid.acvoice.plist` (`plutil -lint` OK). It runs `/usr/bin/open -g -b io.github.nordavid.acvoice` at load. `KeepAlive` only works with the direct binary path. ASSUMED: macOS 13+ also lists it under "Allow in Background". Only worth it if crash-restart is needed; then prefer `SMAppService.agent(plistName:)`.

## Trigger and IPC findings (affect packaging)
- VERIFIED: delivering a URL to the running app with `open -g -a <app> "acvoice-probe://listen?t=…"` takes **85–124 ms**. The app stays inactive and the frontmost app does not change.
- VERIFIED: `open` **without `-g`** activates the LSUIElement app and takes focus. When it quit, focus returned to the previous app.
- VERIFIED: LaunchServices registers the scheme ("claimed schemes: acvoice-probe:"). For an app under `/private/tmp`, though, URL resolution and `-b` lookup return nothing (`kLSApplicationNotFoundErr`). ASSUMED: this works from `~/Applications`.
- Recommended hot path: the Stream Deck plugin talks to the resident app over a Unix domain socket or a 127.0.0.1 HTTP endpoint. ASSUMED: about 1 ms, and it allows sending state back to the key (listening, choosing, done). Launch fallback: `open -g -b io.github.nordavid.acvoice`.
- Alternative without a plugin: a Carbon `RegisterEventHotKey` hotkey (no permission needed) triggered by a Stream Deck Hotkey action (ASSUMED).
- ASSUMED: the plugin must never spawn the binary as a child process. Microphone and automation TCC would then be charged to the Stream Deck app as the responsible process.

## Hygiene
- No Apple Events were sent to Chrome. No TCC entries were created and no permission prompts appeared.
- All probe LaunchServices registrations are removed (`lsregister -dump | grep -c ac-voice` = 0).
- The keychain search list is restored to its original state (VERIFIED). The probe keychain, private key and p12 are deleted.
- ac-mcp and other local repositories were not touched.

Files (all under `spikes/packaging/`): `Package.swift`, `scripts/bundle.sh`, `Sources/ACVoiceShared/{OverlayPanel,ChromeOpener,LaunchAtLogin,Log,OpenACScript.generated}.swift`, `Sources/HelloMenuBar/HelloMenuBarApp.swift`, `Sources/OverlayDemo/main.swift`, `Sources/ASBench/main.swift`, `support/open-ac.applescript`, `support/open-ac.scpt`, `support/io.github.nordavid.acvoice.plist`, `bench/*.log` (raw measurements), `bench/with-probe-keychain.sh` (probe-only).