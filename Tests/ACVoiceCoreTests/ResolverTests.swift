import Foundation
import Testing
@testable import ACVoiceCore

@Suite struct ResolverTests {
    typealias F = Fixture

    @Test func codeOnlyGivesStableRankedChoices() {
        // Favorite + own time records first, then the stable tier (693 idle for a year), then id. No daily drift.
        let expected = "choices 628,314,315,693"
        for _ in 0..<5 { #expect(F.run("Öffne das WWT-Projekt") == expected) }
        for days in [1.0, 7, 29] {
            #expect(F.run("Öffne das WWT-Projekt", now: F.now.addingTimeInterval(days * 86_400)) == expected, "+\(days) d")
        }
        #expect(F.run("WWT") == expected)
    }

    @Test(arguments: ["öffne mir mal das we we te projekt", "W.W.T.", "WW T", "Wewete", "VWT", "W W D"])
    func spelledOrLookalikeCode(_ s: String) { #expect(F.run(s) == "choices 628,314,315,693", "\(s)") }

    @Test(arguments: [
        ("Öffne WWT Relaunch", 628), ("mach WWT Relaunch auf", 628), ("bring mich mal zu dem Relaunch von WWT", 628),
        ("Öffne WWT Relonch", 628), ("WWT Re-Launch", 628), ("We We Tee Relaunch", 628), ("WWT Website Relaunch", 628),
        ("Öffne das S und K. Leasing Cockpit", 2011), ("Öffne das S & K Leasing Cockpit", 2011), ("Öffne S und K Partner", 2013),
        ("zeig mir das Grand Navigation Projekt", 693), ("Grantnavigation", 693), ("Braun Navigation", 693), ("Öffne Grand", 693),
        ("Öffne WWT Grand", 693), ("BDG Pilzdatenbank", 2051), ("Im Pilzdatenbank", 2051), ("IBN Betreuung", 2041),
        ("Ebenbetreuung", 2041), ("Öffne Eben Betreuung", 2041), ("ku zett CRM", 2071), ("QZ CRM", 2071), ("QZ-CRM", 2071),
        ("Q.Z. CRM", 2071), ("Kuh Zett CRM", 2071), ("Q Z C R M", 2071), ("ku zett ce er em", 2071), ("QZCRM", 2071),
        ("Hollenstein Optical", 2025), ("Hollenstein Nordic", 2023), ("Hollenstein und Co", 2024),
        ("Öffne das TYPO 3 Projekt von WWT", 315), ("Öffne WWT Typo drei", 315), ("Öffne WWT TYPO3", 315),
        ("Öffne TKZ Schulung", 2031), ("Öffne TKZ Datenimport", 2032), ("ZMF Sensor 45", 2091),
        ("Öffne QZ Website Relaunch 2027", 2076), ("Öffne die WWT Wartung", 314), ("Öffne WWT Maintenance", 314),
    ])
    func unique(text: String, id: Int) { #expect(F.run(text) == "unique \(id)", "\(text)") }

    @Test(arguments: ["Öffne TKZ Tourenplaner", "Öffne Tourenplaner", "TKZ Touren Planer", "Öffne TKZ TourenpPlaner", "TKZ Touren-Planer",
                      "Öffne Touren Planer", "Touren Planer", "Öffne den Touren Planer", "Öffne Touren-Planer"])
    func gluedTypoTitlesListBoth(_ s: String) {
        // REVIEW M5: one title has a doubled-letter typo; both must match equally instead of by typo margin.
        #expect(F.run(s) == "choices 2031,2032", "\(s)")
    }

    @Test func canonicalTitleKeys() {
        let tkz = F.resolver.projects.filter { [2031, 2032].contains($0.id) }
        #expect(tkz.allSatisfy { $0.titleKeys.contains("tourenplaner") && !$0.titleKeys.contains("tourenpplaner") })
        // Glued in one title, two words in another: same score either way.
        let r = Resolver(projects: [ProjectEntry(id: 1, name: "ABC: Touren Planer"), ProjectEntry(id: 2, name: "ABD: TourenPlaner")])
        for q in ["Touren Planer", "Tourenplaner"] {
            let s = r.score(TextNorm.tokenize(q))
            #expect(s.count == 2 && s[0].text == s[1].text, "\(q)")
        }
    }

    @Test func mergedHypotheses() {
        // DT hears the code, ST hears the title.
        #expect(F.run("Öffne TKZ Touren", "Öffne CKZ Touren Planer.") == "choices 2031,2032")
        #expect(F.run("Öffne TKZ Tauben", "Öffne CKZ Datenimport.") == "unique 2032")
        #expect(F.run("Öffne WWT Relaunch", "Öffne WWTilonch.") == "unique 628")
    }

    @Test func choices() {
        #expect(F.run("Öffne WWT Website") == "choices 628,315")
        #expect(F.run("Öffne Hollenstein") == "choices 2021,2022,2023,2024,2025")     // all 5 Hollenstein codes
        #expect(F.run("Hollenstein TS") == "choices 2021,2022")
        #expect(F.run("S und K") == "choices 2011,2012")
        #expect(F.run("Öffne IBN") == "choices 2041,2042,2043")
        #expect(F.run("Öffne QZ 2027") == "choices 2076,2079")
        let qz = F.run("Öffne QZ")
        #expect(qz.hasPrefix("choices 2073,2071,") && qz.split(separator: ",").count == 12)
    }

    @Test(arguments: ["Öffne YouTube", "Öffne Disney+", "Hallo Welt", "App TV", "Öffne 412",
                      // Short command words are no lookalike codes ("hat" was one edit from the old fixture code).
                      "Was hat Relaunch", "Was ist Relaunch", "Wer hat Relaunch"])
    func rejectsNoise(_ s: String) { #expect(F.run(s) == "none", "\(s)") }

    @Test func lookalikeCodeNeverAutoOpens() {
        // "WWD" (DT without context) is one edit from WWT: list, never a silent open.
        #expect(F.run("Öffne das WWD Projekt") == "choices 628,314,315,693")
        // REVIEW M5: a lookalike that explains title words joins the exact-code list, first by its personal tier.
        #expect(F.run("WKT Relaunch") == "choices 628,2001,2002,2003,2004")
    }

    @Test func aliasesComeFromConfigOnly() {
        let plain = Interpreter(resolver: Resolver(projects: F.projectsWithoutAliases))
        // Without the IBN alias "Ebenbetreuung" only matches the generic "Betreuung" titles.
        #expect(F.run("Ebenbetreuung", using: plain) == "choices 2111,2112")
    }

    @Test func learnedPicksOrderButNeverOpen() {
        var h = History()
        for _ in 0..<3 { h.recordPick(query: "wwt", projectId: 693) }
        h.recordPick(query: "tkz tourenplaner", projectId: 2032)
        let i = Interpreter(resolver: F.resolver, history: h)
        #expect(F.run("Öffne das WWT-Projekt", using: i) == "choices 693,628,314,315")
        #expect(F.run("Öffne TKZ Tourenplaner", using: i) == "choices 2032,2031")
        #expect(F.run("Öffne WWT Relaunch", using: i) == "unique 628")
    }

    @Test func scoredReportsCallerIndices() {
        // "qzcrm" is split internally; `got` and coverage refer to the caller's single token.
        let s = F.resolver.score(TextNorm.tokenize("QZCRM")).first { $0.project.id == 2071 }
        #expect(s?.got == [0] && s?.coverage == 1)
    }

    @Test func interpretationIsFast() {
        let cases = ["Öffne das WWT-Projekt", "WWT Relaunch 412", "Öffne TKZ Tourenplaner", "Q Z C R M", "Ticket 412 im WWT Relaunch"]
        _ = F.run(cases[0])
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<20 { for c in cases { _ = F.run(c, "\(c).") } } }
        // Generous debug-build bound; release runs about 10x faster (PLAN: <= 3 ms per interpretation).
        #expect(elapsed / 100 < .milliseconds(50), "\(elapsed / 100) per interpretation")
    }
}

@Suite struct TicketCommandTests {
    typealias F = Fixture

    @Test(arguments: [
        ("Öffne WWT Ticket 412", "task 412 choices 628,314,315,693"),
        ("Öffne WWT 412", "task 412 choices 628,314,315,693 implicit"),
        ("WWT Relaunch 412", "task 412 unique 628 implicit"),
        ("Ticket 412 im WWT Relaunch", "task 412 unique 628"),
        ("Öffne WWT Ticket vierhundertzwölf", "task 412 choices 628,314,315,693"),
        ("Ticket 12 im TYPO 3 von WWT", "task 12 unique 315"),
        ("Öffne Disney Ticket 50", "task 50 notRecognized"),
        ("Ticket 412", "task 412 -"), ("Ticket 4 12", "task 412 -"), ("Öffne Ticket 400 12", "task 412 -"),
        ("Ticket 47.285", "task 47285 -"), ("Ticket 412 und 5", "task 412 - lowconf"),
        ("Ticket 412 WWT 5", "task 412 choices 628,314,315,693 lowconf"),
        ("Öffne meine Aufgabe 412", "task 412 -"),
    ])
    func parse(text: String, expect: String) { #expect(F.run(text) == expect, "\(text)") }

    @Test func numbersInTitlesStayProjects() {
        #expect(F.run("Öffne das TYPO 3 Projekt von WWT") == "unique 315")
        #expect(F.run("Öffne QZ Website Relaunch 2027") == "unique 2076")
        #expect(F.run("ZMF Sensor 45") == "unique 2091")
        #expect(F.run("Öffne RBZ 2024") == "unique 2062")      // major part of "Stand 2024.3"
    }

    @Test(arguments: [1, 2, 3, 5, 12])
    func versionFractionsAreNoTitleWords(n: Int) {
        // Review: "Stand 2024.3 auf Stand 2025.1" made "Öffne RBZ 3" and "RBZ 1" open the project.
        #expect(F.run("Öffne RBZ \(n)") == "task \(n) choices 2061,2062,2063,2064,2065 implicit")
    }

    @Test func versionTitleKeys() {
        #expect(ProjectEntry(id: 1, name: "RBZ: Umzug Stand 2024.3 auf Stand 2025.1").titleKeys
                    == ["umzug", "stand", "2024", "auf", "stand", "2025"])
        #expect(ProjectEntry(id: 2, name: "ABC: Shop 2.0, TYPO3 v12.4").titleKeys == ["shop", "2", "typo3", "v12"])
        #expect(ProjectEntry(id: 3, name: "ABC: Messe 21.09.2026 und 47.285").titleKeys == ["messe", "21", "09", "2026", "47285"])
    }

    @Test(arguments: [
        ("Öffne Ticket 412, danke", "task 412 -"), ("Ticket 412 bitte schön", "task 412 -"), ("Ticket 412 ja", "task 412 -"),
        ("Öffne Ticket 412 gleich", "task 412 -"), ("Ticket 412 please", "task 412 -"),
        // The fixture has the alias IBN = "eben": "mal eben" must not scope the ticket to IBN.
        ("Öffne mal eben Ticket 412", "task 412 -"), ("Öffne mal eben Pilzdatenbank", "unique 2051"),
        ("Öffne mal eben Grand Navigation", "unique 693"), ("Öffne eben mal WWT Relaunch", "unique 628"),
        ("Öffne Eben Betreuung", "unique 2041"), ("Öffne Relaunch danke", "choices 628,2042,2043,2076,2114,2115,2116"),
        ("Öffne gleich WWT Ticket 58", "task 58 choices 628,314,315,693"), ("Danke schön", "cancel"),
    ])
    func softFillers(text: String, expect: String) { #expect(F.run(text) == expect, "\(text)") }

    @Test func alternativesNeverNarrowABareTicket() {
        // Review: project words of a 0.9 alternative scoped a bare ticket to unrelated projects.
        #expect(F.run("Ticket 412", "Ticket 412 Portal", weights: [1, 0.9]) == "task 412 -")
        // A best hypothesis without project words keeps the scope open when the other's words match nothing.
        #expect(F.run("Ticket 412", "Ticket 412 Disney", weights: [1, 1]) == "task 412 - lowconf")
        #expect(F.run("Ticket 412", "Ticket 412 danke", weights: [1, 1]) == "task 412 -")
        // Words that match still scope the ticket (DT hears the code, ST does not).
        #expect(F.run("Öffne Ticket 412", "Öffne WWT Ticket 412", weights: [1, 1]) == "task 412 choices 628,314,315,693")
        #expect(F.request("Öffne Ticket 412", "Öffne WWT Ticket 412")?.query == "wwt")
        // Only alternatives: their words count.
        #expect(F.run("Öffne WWT Ticket 412", weights: [0.9]) == "task 412 choices 628,314,315,693")
        // A ticket number from a best hypothesis wins over an alternative's.
        #expect(F.run("Ticket 58", "Ticket 412", weights: [0.9, 1]) == "task 412 -")
    }

    @Test func requestFields() {
        let t = F.request("Öffne WWT Relaunch 412")
        #expect(t?.number == 412 && t?.query == "wwt relaunch" && t?.implicit == true && t?.confident == true)
        if case .none? = F.request("Öffne Disney Ticket 50")?.projects {} else { Issue.record("expected .none projects") }
        #expect(F.request("Ticket 412")?.projects == nil)
    }
}
