import ACVoiceCore
@testable import ACVoiceSystem
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Testing

/// Hotkey mapping only: nothing is registered.
struct HotkeyTests {
    @Test func defaultIsControlOptionSpace() throws {
        let spec = try #require(CarbonHotkey(.default))
        #expect(spec.keyCode == UInt32(kVK_Space))
        #expect(spec.modifiers == UInt32(controlKey | optionKey))
        #expect(Hotkey.default.display == "⌃⌥Leertaste")
    }

    @Test func coreConstantsMatchCarbon() {
        #expect(Hotkey.cmdKey == UInt32(cmdKey))
        #expect(Hotkey.shiftKey == UInt32(shiftKey))
        #expect(Hotkey.optionKey == UInt32(optionKey))
        #expect(Hotkey.controlKey == UInt32(controlKey))
        #expect(UInt32(kEventHotKeyPressed) != UInt32(kEventHotKeyReleased))
    }

    @Test func invalidCombinationsAreRejected() {
        #expect(CarbonHotkey(Hotkey(keyCode: 49, modifiers: Hotkey.controlKey | Hotkey.optionKey, enabled: false)) == nil)
        #expect(CarbonHotkey(Hotkey(keyCode: 200, modifiers: Hotkey.cmdKey)) == nil)
        #expect(CarbonHotkey(Hotkey(keyCode: UInt32(kVK_Space), modifiers: 0)) == nil)
        #expect(CarbonHotkey(Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(alphaLock))) == nil)
        // Esc alone is never a valid configured hotkey; the runtime registers `CarbonHotkey.escape` only while the
        // overlay shows.
        #expect(CarbonHotkey(Hotkey(keyCode: UInt32(kVK_Escape), modifiers: 0)) == nil)
        #expect(CarbonHotkey.escape.keyCode == 53 && CarbonHotkey.escape.modifiers == 0)
        // Esc with the held hotkey modifiers (push-to-talk): ⌃⌥Esc for ⌃⌥Space. Never with ⌘ (⌥⌘Esc is Force Quit),
        // never without a modifier (that is plain `escape`), unknown bits dropped.
        let held = CarbonHotkey.escape(heldWith: Hotkey.controlKey | Hotkey.optionKey | UInt32(alphaLock))
        #expect(held?.keyCode == 53 && held?.modifiers == Hotkey.controlKey | Hotkey.optionKey)
        #expect(CarbonHotkey.escape(heldWith: Hotkey.cmdKey | Hotkey.optionKey) == nil)
        #expect(CarbonHotkey.escape(heldWith: 0) == nil)
        #expect(CarbonHotkey.escape(heldWith: UInt32(alphaLock)) == nil)
        // Function keys work alone.
        #expect(CarbonHotkey(Hotkey(keyCode: UInt32(kVK_F19), modifiers: 0)) == CarbonHotkey(Hotkey(keyCode: 80, modifiers: 0)))
        // Unknown bits are dropped.
        let spec = CarbonHotkey(Hotkey(keyCode: 49, modifiers: Hotkey.controlKey | Hotkey.optionKey | UInt32(alphaLock)))
        #expect(spec?.modifiers == UInt32(controlKey | optionKey))
    }

    /// The configured hotkey and Esc are two `GlobalHotkey` instances. Every Carbon handler sees every hotkey event
    /// and answers only its own id: a shared id would let the Esc handler take ⌃⌥Space while the overlay shows.
    @MainActor
    @Test func hotkeyIdsAreUniqueAcrossInstances() {
        let ids = (0..<5).map { _ in GlobalHotkey.allocateId() }
        #expect(Set(ids).count == ids.count)
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func appKitFlagsRoundTrip() {
        let bits: [UInt32] = [UInt32(cmdKey), UInt32(shiftKey), UInt32(optionKey), UInt32(controlKey)]
        for mask in 0..<16 {
            var carbon: UInt32 = 0
            for (i, b) in bits.enumerated() where mask & (1 << i) != 0 { carbon |= b }
            let flags = CarbonHotkey.flags(from: carbon)
            #expect(CarbonHotkey.modifiers(from: flags) == carbon)
        }
        #expect(CarbonHotkey.modifiers(from: [.control, .option, .capsLock, .function]) == UInt32(controlKey | optionKey))
        #expect(CarbonHotkey.flags(from: UInt32(controlKey | optionKey)) == [.control, .option])
    }

    @Test func edgeFilter() {
        var f = HotkeyEdgeFilter()
        #expect(f.accept(pressed: false, at: 0.0) == nil)          // release without press
        #expect(f.accept(pressed: true, at: 1.0) == .pressed)
        #expect(f.isDown)
        #expect(f.accept(pressed: true, at: 1.1) == nil)           // key repeat
        #expect(f.accept(pressed: false, at: 1.812) == .released(heldMs: 812))
        #expect(!f.isDown)
        #expect(f.accept(pressed: false, at: 2.0) == nil)
        #expect(f.accept(pressed: true, at: 3.0) == .pressed)
        #expect(f.accept(pressed: false, at: 3.0) == .released(heldMs: 0))
    }

    @Test func eventKinds() {
        #expect(HotkeyEdgeFilter.isPressed(eventKind: UInt32(kEventHotKeyPressed)) == true)
        #expect(HotkeyEdgeFilter.isPressed(eventKind: UInt32(kEventHotKeyReleased)) == false)
        #expect(HotkeyEdgeFilter.isPressed(eventKind: 999) == nil)
    }

    @Test func messagesFollowTheStyle() {
        let all = [HotkeyError.invalid, .registrationFailed(Int32(eventHotKeyExistsErr)), .registrationFailed(-1),
                   .handlerInstallFailed(-1)].map { $0.message(.de) }
        #expect(all.contains("Eine andere App nutzt das Tastenkürzel. Ändere hotkey in config.json."))
        for m in all { #expect(styleViolations(m).isEmpty, "\(m)") }
    }
}

struct LogTests {
    @Test func privateTextNeverReachesThePublicPart() {
        let r = Log.render([.int("projectId", 628), .ms("elapsed", seconds: 0.0234), .bool("ac", true),
                            .text("result", "reused"), .private("url", "https://ac.example.com/projects/628"),
                            .private("heard", "Öffne WWT Ticket 412")])
        #expect(r.public == "projectId=628 elapsed=23.4ms ac=true result=reused")
        #expect(!r.public.contains("example.com"))
        #expect(!r.public.contains("Öffne"))
        #expect(r.private.contains("url=https://ac.example.com/projects/628"))
        #expect(r.private.contains("heard=Öffne WWT Ticket 412"))
    }

    @Test func secretsAreRedacted() {
        #expect(Log.redactSecrets("Authorization: Bearer abc.def") == "Authorization: Bearer [redacted]")
        #expect(Log.redactSecrets("token: 538-AbCdEfGh0123456789xyz") == "token: [redacted]")
        #expect(Log.redactSecrets("x 538-AbCdEfGh0123456789xyzQ y") == "x [redacted] y")
        #expect(Log.redactSecrets("etag \"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"") == "etag [redacted]")
        #expect(Log.redactSecrets("mail max@example.com") == "mail [redacted]")
        #expect(Log.redactSecrets("feed_token=abc123") == "[redacted]")
        // Speech and AC URLs stay readable (in the private part).
        for s in ["Öffne das WWT-Projekt", "Ticket 47285", "S und K Leasing Cockpit", "https://ac.example.com/projects/628/tasks/47285"] {
            #expect(Log.redactSecrets(s) == s)
        }
        #expect(Log.render([.private("t", "Bearer secret")]).private == "t=Bearer [redacted]")
    }

    @Test func categoriesAndSubsystem() {
        #expect(Log.subsystem == "io.github.nordavid.acvoice")
        let names = Set(Log.Category.allCases.map(\.rawValue))
        #expect(names.isSuperset(of: ["ipc", "chrome", "hotkey", "earcon", "login"]))
        // Logging itself must not crash with odd input.
        Log.event(.app, "test.event", .int("n", 1), .private("x", "Bearer y"))
        Log.transcript(.speech, "test.transcript", "Öffne WWT Relaunch")
        Log.error(.app, "test.error", CocoaError(.fileNoSuchFile))
    }
}

struct LoginItemTests {
    @Test func statusMapping() {
        #expect(LoginItemStatus(SMAppService.Status.enabled) == .enabled)
        #expect(LoginItemStatus(SMAppService.Status.notRegistered) == .disabled)
        #expect(LoginItemStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
        #expect(LoginItemStatus(SMAppService.Status.notFound) == .notFound)
    }

    @Test func hintsFollowTheStyle() {
        #expect(LoginItemStatus.enabled.hint(.de) == nil)
        #expect(LoginItemStatus.disabled.hint(.de) == nil)
        for s in [LoginItemStatus.requiresApproval, .notFound] {
            let h = s.hint(.de) ?? ""
            #expect(!h.isEmpty)
            #expect(styleViolations(h).isEmpty, "\(h)")
        }
    }
}
