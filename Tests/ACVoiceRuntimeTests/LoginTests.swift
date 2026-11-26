import ACVoiceAC
import ACVoiceCore
import ACVoiceFlow
import Foundation
import Testing
@testable import ACVoiceRuntime

/// Sign-in with e-mail and password, and the AC address in the setup window. Fakes only: no request leaves the
/// process, nothing touches the Keychain. The credentials are test values.
@MainActor
@Suite struct LoginTests {
    static let user = "someone@example.com"
    static let secret = "Not-A-Real-Password-123"
    static let address = URL(string: "https://ac.example.test")!
    static let signedIn = AppText.de.tokenStored(host: "ac.example.test")

    /// A rig whose config names a real (non-placeholder) AC address.
    static func rig(token: StoredToken = .missing) -> Rig {
        var config = Fixture.config
        config.acBaseURL = address
        return Rig(token: token, config: config)
    }

    func tokenRow(_ model: OnboardingModel) -> OnboardingModel.Step? { model.steps.first { $0.id == .token } }

    @Test func loginAttachesTheIndexForTheTokenUserAndOpensNothing() async {
        let rig = Self.rig()
        await rig.start()
        #expect(rig.controller.status.token == .missing && rig.index == nil && rig.controller.needsSetup)
        #expect(await rig.controller.login(username: Self.user, password: Self.secret))
        await rig.settle()
        #expect(rig.tokens.logins.map(\.base) == [Self.address] && rig.tokens.logins.map(\.username) == [Self.user])
        #expect(rig.tokens.loginHadPassword == [true])
        // The issued token "538-…" names the user: its index, at the configured address.
        #expect(rig.factory.made.map(\.userId) == [538] && rig.factory.bases == [Self.address])
        #expect(rig.index?.calls.prefix(2) == ["loadFromDisk", "refreshFast"])
        #expect(rig.controller.status.token == .present && rig.controller.status.tokenMessage == nil)
        #expect(!rig.controller.needsSetup && rig.controller.flowConfig.userId == 538)
        // A sign-in opens nothing and shows no overlay.
        #expect(rig.chrome.opened.isEmpty && rig.overlay.shows == 0 && rig.speech.starts.isEmpty)
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        #expect(tokenRow(model)?.status == Self.signedIn && tokenRow(model)?.tone == .done && !model.showsSignIn)

        // The flow uses the new token's user right away.
        await rig.command("Meine Aufgaben")
        #expect(rig.chrome.opened == [URL(string: "https://ac.example.test/users/538/tasks")!])
    }

    @Test func failedLoginKeepsTheStateAndSaysWhy() async {
        let rig = Self.rig(token: .present(userId: 538))
        await rig.start()
        let index = rig.index
        func transport(_ code: URLError.Code) -> ACError { .transport(code: code.rawValue) }
        let cases: [(ACError, String)] = [
            (.credentialsRejected, AppText.de.loginRejected),
            (transport(.notConnectedToInternet), AppText.de.loginOffline),
            (transport(.networkConnectionLost), AppText.de.loginOffline),
            (transport(.timedOut), AppText.de.loginOffline),
            // A mistyped host or a host that is no ActiveCollab: the message points to the address.
            (transport(.cannotFindHost), AppText.de.loginAddress),
            (transport(.dnsLookupFailed), AppText.de.loginAddress),
            (transport(.cannotConnectToHost), AppText.de.loginAddress),
            (transport(.serverCertificateUntrusted), AppText.de.loginAddress),
            (transport(.secureConnectionFailed), AppText.de.loginAddress),
            (.http(status: 404, path: ACTokenIssuer.path), AppText.de.loginAddress),
            (.unexpectedRedirect(path: ACTokenIssuer.path), AppText.de.loginAddress),
            (.decoding(path: ACTokenIssuer.path, detail: "root"), AppText.de.loginAddress),
            (.http(status: 502, path: ACTokenIssuer.path), AppText.de.loginFailed),
        ]
        for (error, text) in cases {
            rig.tokens.loginResult = .failure(error)
            #expect(await rig.controller.login(username: Self.user, password: Self.secret) == false)
            await rig.settle()
            #expect(rig.controller.status.tokenMessage == text)
            // The stored token and its index stay as they were.
            #expect(rig.controller.status.token == .present && rig.index === index && rig.factory.made.count == 1)
            #expect(index?.resets == 0)
        }
        #expect(AppText.de.loginOffline == "AC antwortet nicht. Prüfe die Internetverbindung.")
        #expect(AppText.de.loginAddress == "AC antwortet unter dieser Adresse nicht. Prüfe die AC-Adresse.")
        #expect(AppText.de.loginRejected == "AC lehnt E-Mail oder Passwort ab.")
        // The message belongs to the form: it shows while the form is open ...
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        model.signingInAgain = true
        model.rebuild()
        #expect(tokenRow(model)?.status == AppText.de.loginFailed && tokenRow(model)?.tone == .todo)
        // ... and once the window closes the row says where the app is signed in again.
        model.windowClosed()
        #expect(tokenRow(model)?.status == Self.signedIn && tokenRow(model)?.tone == .done)
        #expect(rig.controller.status.tokenMessage == nil && !model.showsSignIn)

        // Without a stored token a failed sign-in keeps the row asking for one.
        let fresh = Self.rig()
        await fresh.start()
        fresh.tokens.loginResult = .failure(.credentialsRejected)
        #expect(await fresh.controller.login(username: Self.user, password: Self.secret) == false)
        #expect(fresh.controller.status.token == .missing && fresh.index == nil)
        #expect(fresh.controller.status.tokenMessage == AppText.de.loginRejected)
    }

    /// The password field empties after every attempt, and the password stays nowhere in the model, the status or
    /// the fakes. The e-mail address stays for the next try.
    @Test func passwordIsNotKeptAfterAnAttempt() async {
        let rig = Self.rig()
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        #expect(model.address == Self.address.absoluteString)   // prefilled with the configured address
        model.email = Self.user
        #expect(!model.canLogin)   // no password yet
        await model.login()
        #expect(rig.tokens.logins.isEmpty)

        func expectNoTrace() {
            #expect(model.password.isEmpty && model.email == Self.user)
            for child in Mirror(reflecting: model).children {
                #expect(!String(describing: child.value).contains(Self.secret), "\(child.label ?? "?")")
            }
            #expect(!String(describing: rig.controller.status).contains(Self.secret))
            #expect(!String(describing: rig.tokens.logins).contains(Self.secret))
            for step in model.steps { #expect(!step.status.contains(Self.secret)) }
        }

        rig.tokens.loginResult = .failure(.credentialsRejected)
        model.password = Self.secret
        #expect(model.canLogin)
        await model.login()
        await rig.settle()
        expectNoTrace()
        #expect(tokenRow(model)?.status == AppText.de.loginRejected && !model.canLogin)

        rig.tokens.loginResult = .success("538-IssuedTestTokenAbc")
        model.password = Self.secret
        await model.login()
        await rig.settle()
        expectNoTrace()
        #expect(rig.tokens.loginHadPassword == [true, true])
        #expect(rig.controller.status.token == .present && tokenRow(model)?.status == Self.signedIn)
    }

    /// A token paste, a close of the window or a form that hides leave the form without a sign-in attempt. The password
    /// goes in each case, so a later "Neu anmelden" never starts with a filled-in password.
    @Test func passwordIsNotKeptWithoutAnAttempt() async {
        let rig = Self.rig()
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        model.email = Self.user
        model.password = Self.secret
        model.showsTokenSignIn = true
        model.pastedToken = "538-PastedTestTokenAbc"
        await model.savePastedToken()
        await rig.settle()
        #expect(rig.controller.status.token == .present && rig.tokens.logins.isEmpty)
        #expect(model.password.isEmpty && model.pastedToken.isEmpty && !model.showsSignIn)
        model.beginSignInAgain()
        #expect(model.showsSignIn && model.password.isEmpty && !model.canLogin)

        // Typed, then the window closes ("Fertig" or the close button): nothing stays and the form closes. The
        // address field shows the address the app uses, not the unsaved edit.
        model.password = Self.secret
        model.pastedToken = "538-AnotherTestTokenAbc"
        model.address = "https://ac.other.example.test"
        model.windowClosed()
        #expect(model.password.isEmpty && model.pastedToken.isEmpty && !model.signingInAgain && !model.showsSignIn)
        #expect(model.address == "https://ac.example.test" && model.email == Self.user)
        for child in Mirror(reflecting: model).children {
            #expect(!String(describing: child.value).contains(Self.secret), "\(child.label ?? "?")")
        }
        #expect(rig.store.baseURLs.isEmpty && rig.tokens.saved == ["538-PastedTestTokenAbc"])

        // Without a token the form stays after a close, but empty.
        let fresh = Self.rig()
        await fresh.start()
        let form = OnboardingModel(controller: fresh.controller, copy: { _ in }, openURL: { _ in })
        form.password = Self.secret
        form.windowClosed()
        #expect(form.password.isEmpty && form.showsSignIn)
        // A token that arrives from elsewhere hides the form and clears it.
        form.password = Self.secret
        #expect(await fresh.controller.saveToken("538-OtherTestTokenAbc"))
        await fresh.settle()
        form.rebuild()
        #expect(!form.showsSignIn && form.password.isEmpty)
    }

    /// Review: a failed sign-in after "Neu anmelden" used to close the form because the old token stays valid. Only a
    /// successful sign-in or save closes it now; the reason stays next to the form for the next try.
    @Test func failedSignInAgainKeepsTheFormOpen() async {
        let rig = Self.rig(token: .present(userId: 538))
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        #expect(!model.showsSignIn && tokenRow(model)?.status == Self.signedIn)
        model.beginSignInAgain()
        #expect(model.showsSignIn && model.address == "https://ac.example.test")
        model.email = Self.user
        rig.tokens.loginResult = .failure(.credentialsRejected)
        model.password = Self.secret
        await model.login()
        await rig.settle()
        #expect(rig.controller.status.token == .present && !rig.controller.needsSetup)
        #expect(model.showsSignIn && model.signingInAgain && model.password.isEmpty && model.email == Self.user)
        #expect(tokenRow(model)?.status == AppText.de.loginRejected && tokenRow(model)?.tone == .todo)
        model.rebuild()   // a status change from a background refresh
        #expect(model.showsSignIn && tokenRow(model)?.status == AppText.de.loginRejected)

        // A pasted token the Keychain does not take keeps the form open too.
        rig.tokens.saveError = .noToken
        model.pastedToken = "not a token"
        await model.savePastedToken()
        #expect(model.showsSignIn && model.pastedToken.isEmpty && tokenRow(model)?.status == ACError.noToken.userMessage)
        rig.tokens.saveError = nil

        // The next try works: the form closes, the same user's index resets its token.
        rig.tokens.loginResult = .success("538-IssuedTestTokenAbc")
        model.password = Self.secret
        await model.login()
        await rig.settle()
        #expect(!model.showsSignIn && !model.signingInAgain && tokenRow(model)?.status == Self.signedIn)
        #expect(rig.factory.made.count == 1 && rig.index?.resets == 1)

        // "Neu anmelden" again starts without the message of an earlier attempt.
        rig.tokens.loginResult = .failure(.credentialsRejected)
        model.password = Self.secret
        model.beginSignInAgain()
        await model.login()
        model.windowClosed()
        model.beginSignInAgain()
        #expect(tokenRow(model)?.status == Self.signedIn && rig.controller.status.tokenMessage == nil)
    }

    /// A new user fills address, e-mail and password and clicks one button: the address is saved first.
    @Test func signInSavesTheTypedAddressFirst() async {
        let rig = Rig(token: .missing)   // placeholder address
        await rig.start()
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        #expect(model.address.isEmpty && !model.canLogin)
        model.address = "  AC.example.test/projects/628 "
        model.email = Self.user
        model.password = Self.secret
        await model.login()
        await rig.settle()
        #expect(rig.store.baseURLs == [Self.address] && rig.chrome.bases == [Self.address])
        #expect(rig.tokens.logins.map(\.base) == [Self.address])
        #expect(model.address == "https://ac.example.test" && model.password.isEmpty)
        #expect(rig.controller.status.token == .present && rig.factory.bases == [Self.address])

        // An invalid address stops before the sign-in.
        let other = Rig(token: .missing)
        await other.start()
        let form = OnboardingModel(controller: other.controller, copy: { _ in }, openURL: { _ in })
        form.address = "http://ac.example.test"
        form.email = Self.user
        form.password = Self.secret
        await form.login()
        #expect(other.tokens.logins.isEmpty && other.store.baseURLs.isEmpty && form.password.isEmpty)
        #expect(other.controller.status.tokenMessage == AppText.de.addressInvalid)
        #expect(other.controller.config.hasPlaceholderBaseURL)
    }

    /// Saving the address writes only `acBaseURL` and applies it without a restart: Chrome's AC tabs, the Keychain
    /// account (host), the index and the flow follow. A new host has no token yet, so the row asks for a sign-in.
    @Test func addressChangeAppliesWithoutRestart() async {
        let rig = Rig()   // token and index for ac.example.com
        await rig.start()
        let old = rig.index
        #expect(rig.controller.status.token == .present && rig.controller.status.projects > 0)
        #expect(await rig.controller.setACBaseURL("https://AC.Example.test/projects/628/"))
        await rig.settle()
        #expect(rig.controller.config.acBaseURL == Self.address)
        #expect(rig.store.baseURLs == [Self.address] && rig.store.launchAtLogin.isEmpty)
        #expect(rig.chrome.bases == [Self.address])
        #expect(rig.tokens.reads.last == Self.address)
        // The old token belongs to the old host: no index, no projects, the row asks for a sign-in.
        #expect(rig.controller.status.token == .missing && rig.controller.index == nil && rig.controller.needsSetup)
        #expect(rig.controller.status.projects == 0 && rig.controller.env.interpreter.resolver.projects.isEmpty)
        #expect(rig.factory.made.count == 1 && old?.resets == 0)
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        #expect(tokenRow(model)?.status == AppText.de.tokenNone && model.showsSignIn)
        #expect(model.address == "https://ac.example.test")
        await rig.command("WWT Relaunch")
        #expect(rig.phase == .error && rig.model.message == FlowText.de.noProjectData && rig.chrome.opened.isEmpty)
        await rig.advance(2)

        // The same address again changes nothing.
        #expect(await rig.controller.setACBaseURL("ac.example.test"))
        #expect(rig.store.baseURLs.count == 1 && rig.chrome.bases.count == 1)
        // An invalid one is refused and keeps the address.
        #expect(await rig.controller.setACBaseURL("http://ac.example.test") == false)
        #expect(rig.controller.status.tokenMessage == AppText.de.addressInvalid && rig.controller.config.acBaseURL == Self.address)

        // Signing in at the new address brings its index; the flow opens pages there.
        #expect(await rig.controller.login(username: Self.user, password: Self.secret))
        await rig.settle()
        #expect(rig.tokens.logins.map(\.base) == [Self.address] && rig.factory.bases.last == Self.address)
        await rig.command("Meine Aufgaben")
        #expect(rig.chrome.opened == [URL(string: "https://ac.example.test/users/538/tasks")!])

        // Back to the first host: its Keychain item still holds a token, so its index comes back without a sign-in.
        #expect(await rig.controller.setACBaseURL("https://ac.example.com"))
        await rig.settle()
        #expect(rig.controller.status.token == .present && rig.factory.bases.last == Fixture.base)
        #expect(rig.chrome.bases == [Self.address, Fixture.base] && rig.tokens.logins.count == 1)
    }

    /// The Keychain account carries a non-default port, as `Config.sameBase` does: a token issued for one port never
    /// goes to another one.
    @Test func portOnlyAddressChangeAsksForASignIn() async {
        var config = Fixture.config
        config.acBaseURL = URL(string: "https://ac.example.test:8443")!
        let rig = Rig(config: config)   // a token for ac.example.test:8443
        await rig.start()
        #expect(rig.controller.status.token == .present && rig.factory.made.count == 1)
        #expect(rig.tokens.account == "ac.example.test:8443")
        #expect(await rig.controller.setACBaseURL("https://ac.example.test"))
        await rig.settle()
        #expect(rig.controller.status.token == .missing && rig.controller.index == nil && rig.factory.made.count == 1)
        #expect(rig.store.baseURLs == [Self.address] && rig.tokens.reads.last == Self.address)
        // :443 is the same origin as no port: nothing changes.
        #expect(await rig.controller.setACBaseURL("https://ac.example.test:443"))
        #expect(rig.store.baseURLs == [Self.address])
        // Back to 8443: its own token comes back without a sign-in.
        #expect(await rig.controller.setACBaseURL("ac.example.test:8443"))
        await rig.settle()
        #expect(rig.controller.status.token == .present && rig.factory.bases.last == config.acBaseURL)
        #expect(rig.tokens.logins.isEmpty && rig.tokens.saved.isEmpty)
    }

    /// A hand-written address ("https://ac.example.test/") is kept verbatim. The same address in the field is no change:
    /// before the fix the first sign-in rebuilt the index and re-read the rejected token as present.
    @Test func sameAddressInAnotherSpellingChangesNothing() async {
        var config = Fixture.config
        config.acBaseURL = URL(string: "https://ac.example.test/")!
        let rig = Rig(config: config)
        await rig.start()
        let index = rig.index
        rig.index?.fastReport = FakeIndex.report(errors: [.unauthorized])
        rig.controller.refreshIndexNow()
        await rig.settle()
        #expect(rig.controller.status.token == .invalid)
        let model = OnboardingModel(controller: rig.controller, copy: { _ in }, openURL: { _ in })
        #expect(model.address == "https://ac.example.test/" && model.showsSignIn)
        model.email = Self.user
        model.password = Self.secret
        rig.tokens.loginResult = .failure(.credentialsRejected)
        await model.login()
        await rig.settle()
        #expect(rig.store.baseURLs.isEmpty && rig.chrome.bases.isEmpty && rig.factory.made.count == 1 && rig.index === index)
        #expect(rig.controller.status.token == .invalid && model.showsSignIn)
        #expect(tokenRow(model)?.status == AppText.de.loginRejected && rig.tokens.logins.count == 1)
        for text in ["AC.Example.test", "https://ac.example.test:443/projects/628"] {
            #expect(await rig.controller.setACBaseURL(text))
        }
        #expect(rig.store.baseURLs.isEmpty && rig.factory.made.count == 1 && rig.controller.status.token == .invalid)
    }

    /// A `userId` in config.json belongs to the address it was written for. After a switch to another ActiveCollab the
    /// new token's user id applies, for the index and for "Meine Aufgaben".
    @Test func pinnedUserIdOfTheOldAddressDoesNotApply() async {
        var config = Fixture.config
        config.userId = 538
        let rig = Rig(config: config)
        await rig.start()
        #expect(await rig.controller.setACBaseURL("ac.example.test"))
        rig.tokens.loginResult = .success("12-IssuedTestTokenAbc")
        #expect(await rig.controller.login(username: Self.user, password: Self.secret))
        await rig.settle()
        #expect(rig.factory.made.map(\.userId) == [538, 12] && rig.factory.bases.last == Self.address)
        #expect(rig.controller.flowConfig.userId == 12 && rig.controller.config.userId == 538)
        await rig.command("Meine Aufgaben")
        #expect(rig.chrome.opened == [URL(string: "https://ac.example.test/users/12/tasks")!])
    }

    @Test func fileStoreWritesOnlyTheAddress() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acvoice-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStore(configURL: dir.appendingPathComponent("config.json"),
                              historyURL: dir.appendingPathComponent("history.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // An old config.json that still names the removed token import key.
        let old = #"{"acBaseURL":"https://ac.example.com","tokenImportPath":"~/old","earcons":false,"myOwnKey":"keep"}"#
        try Data(old.utf8).write(to: store.configURL)
        #expect(!store.loadConfig().earcons && store.loadConfig().hasPlaceholderBaseURL)
        store.saveACBaseURL(Self.address)
        store.flush()
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.configURL)) as? [String: Any])
        #expect(json["acBaseURL"] as? String == "https://ac.example.test")
        #expect(json["earcons"] as? Bool == false && json["myOwnKey"] as? String == "keep" && json["tokenImportPath"] as? String == "~/old")
        #expect(json.count == 4)
        let config = store.loadConfig()
        #expect(config.acBaseURL == Self.address && !config.earcons)
    }
}
