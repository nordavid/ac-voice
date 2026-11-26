import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ACVoiceCore
import ACVoiceFlow

/// Offscreen renders of the overlay, for design review and tests. Uses `ImageRenderer` only: no window, no panel.
/// Glass needs the window server, so the card gets a rendered stand-in (the wallpaper behind it, blurred and
/// tinted) that matches the live look.
@MainActor
public enum OverlaySnapshot {
    /// Renders one model over a wallpaper. `now` sets the orb animation phase and the countdown; `level` the mic
    /// level. Light wallpaper renders the light appearance, dark the dark one.
    public static func image(_ model: OverlayModel, wallpaper: SnapshotWallpaper, now: Date, level: Double = 0.5,
                             choicesWindow: Double = 6, accessibility: OverlayAccessibility = .init(),
                             scale: CGFloat = 2) -> CGImage? {
        let scene = SnapshotScene(state: OverlayViewState(model: model), wallpaper: wallpaper, now: now, level: level,
                                  choicesWindow: choicesWindow, accessibility: accessibility)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.cgImage
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Renders every scenario on every wallpaper into `<directory>/<name>-<wallpaper><suffix>.png`.
    @discardableResult
    public static func renderAll(to directory: URL, scenarios: [OverlayScenario] = OverlayGallery.scenarios(),
                                 wallpapers: [SnapshotWallpaper] = SnapshotWallpaper.allCases,
                                 accessibility: OverlayAccessibility = .init(), suffix: String = "",
                                 scale: CGFloat = 2) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for scenario in scenarios {
            for wallpaper in wallpapers {
                guard let img = image(scenario.model, wallpaper: wallpaper, now: scenario.now, level: scenario.level,
                                      accessibility: accessibility, scale: scale),
                      let data = png(img) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "render failed: \(scenario.name)"])
                }
                let url = directory.appendingPathComponent("\(scenario.name)-\(wallpaper.rawValue)\(suffix).png")
                try data.write(to: url)
                written.append(url)
            }
        }
        return written
    }
}

/// The card over a wallpaper, with the shadow margin around it.
struct SnapshotScene: View {
    var state: OverlayViewState
    var wallpaper: SnapshotWallpaper
    var now: Date
    var level: Double
    var choicesWindow: Double
    var accessibility: OverlayAccessibility

    var body: some View {
        OverlayView(state: state, clock: .fixed(now: now, level: level), background: .rendered(wallpaper),
                    interactive: false, choicesWindow: choicesWindow, onChoose: { _ in }, onDismiss: {})
            .padding(.horizontal, 48)
            .padding(.top, 40)
            .padding(.bottom, 64)
            .background(alignment: .topLeading) { WallpaperView(kind: wallpaper) }
            .clipped()
            .coordinateSpace(.named(WallpaperView.space))
            .environment(\.colorScheme, wallpaper == .dark ? .dark : .light)
            .environment(\.overlayAccessibility, accessibility)
    }
}

/// A named overlay state for snapshots and previews.
public struct OverlayScenario: Sendable {
    public var name: String
    public var model: OverlayModel
    /// Render time: sets the countdown and the orb's animation phase.
    public var now: Date
    /// Mic level 0...1.
    public var level: Double

    public init(name: String, model: OverlayModel, now: Date, level: Double = 0.5) {
        self.name = name; self.model = model; self.now = now; self.level = level
    }
}

/// Every overlay state with synthetic data in the style of `Tests/Fixtures/projects.sample.json`.
public enum OverlayGallery {
    /// Fixed render time, so snapshots are reproducible.
    public static let reference = Date(timeIntervalSinceReferenceDate: 812_000_000)

    /// The gallery in `language`: the flow's and the overlay's texts and the spoken commands in that language. Project
    /// names stay as they are (they come from AC).
    public static func scenarios(reference t0: Date = reference, language: AppLanguage = .de) -> [OverlayScenario] {
        let f = FlowText(language)
        // What the user said, per language.
        func said(_ de: String, _ en: String) -> String { language == .de ? de : en }
        func model(_ phase: FlowPhase, seq: Int, _ edit: (inout OverlayModel) -> Void) -> OverlayModel {
            var m = OverlayModel()
            m.seq = seq
            m.phase = phase
            m.visible = true
            m.since = t0
            m.language = language
            m.micReady = phase == .listening || phase == .retry || phase == .choices
            edit(&m)
            return m
        }
        let openWWT = said("Öffne das WWT-Projekt", "Open WWT")
        let ticket412 = said("Öffne WWT Ticket 412", "Open WWT ticket 412")
        let wwt = [
            item(1, 628, "WWT: Website Relaunch [AGIL]", badges: [.favorite, .recent]),
            item(2, 315, "WWT: TYPO3 Website maintenance [AGIL]", badges: [.recent]),
            item(3, 314, "WWT: Maintenance [SLA]"),
            item(4, 693, "WWT: Grand Navigation [AGIL]"),
        ]
        let qz = [
            (2071, "QZ: CRM [INT]"), (2072, "QZ: KI-Assistent [INT]"), (2073, "QZ: Allgemein [INT]"),
            (2074, "QZ: Vertrieb [INT]"), (2075, "QZ: Git Server [INT]"), (2076, "QZ: Website Relaunch 2027 [INT]"),
            (2077, "QZ: IT Support [INT]"), (2078, "QZ: Telefonie [INT]"),
            (2079, "QZ: Schulungen 2027 - Zeiten nur im CRM!!!  [INT]"), (2080, "QZ: Handbuch [INT]"),
            (2081, "QZ: R3NO [INT]"), (2082, "QZ Monitoring [INT]"),
        ].enumerated().map { i, p in item(i + 1, p.0, p.1, badges: p.0 == 2073 || p.0 == 2071 ? [.recent] : []) }

        let long = [
            (2062, "RBZ: Kassensystem Umzug von Stand 2024.3 auf Stand 2025.1 [AGIL]"),
            (2122, "Tourismusverband Nord-Ost: Webportal Neubau mit Buchungsstrecke und Partnerbereich [AGIL]"),
            (2121, "Acme Germany: Lagerverwaltung und Versand"),
            (2052, "BDG: Datenbank – Export Katalog und Bilder [AGIL]"),
            (2117, "ZLK Holding: Einführung Zeiterfassung [AGIL]"),
            (2021, "Hollenstein TS: Katalog App & Website "),
            (2025, "Hollenstein Optical: Hotline [SLA]"),
        ].enumerated().map { i, p in item(i + 1, p.0, p.1, badges: i == 0 ? [.favorite, .recent] : (i == 2 ? [.recent] : [])) }

        // The most frequent state first: mic hot, nothing heard yet.
        return [
            OverlayScenario(name: "listening-ready", model: model(.listening, seq: 2) { _ in },
                            now: t0.addingTimeInterval(0.4), level: 0.08),
            OverlayScenario(name: "listening-starting", model: model(.listening, seq: 1) {
                $0.micReady = false
            }, now: t0.addingTimeInterval(0.05), level: 0),
            OverlayScenario(name: "listening-cold", model: model(.listening, seq: 1) {
                $0.micReady = false
                $0.warming = true
                $0.message = f.loadingModel
            }, now: t0.addingTimeInterval(0.6), level: 0),
            OverlayScenario(name: "listening-partial", model: model(.listening, seq: 4) {
                $0.transcript = Transcript(stable: said("Öffne WWT", "Open WWT"), volatile: "Relaunch")
                $0.preview = "WWT: Website Relaunch"
            }, now: t0.addingTimeInterval(1.35), level: 0.62),
            OverlayScenario(name: "listening-long", model: model(.listening, seq: 5) {
                $0.transcript = Transcript(
                    stable: said("Öffne bitte das Projekt Hollenstein Optical mit der Hotline und danach noch das Ticket",
                                 "Please open the Hollenstein Optical project with the hotline and after that the ticket"),
                    volatile: said("siebenundvierzigtausend", "forty-seven thousand"))
                $0.preview = f.projectCount(5, code: nil)
            }, now: t0.addingTimeInterval(2.2), level: 0.35),
            OverlayScenario(name: "processing", model: model(.processing, seq: 6) { _ in },
                            now: t0.addingTimeInterval(0.2), level: 0),
            OverlayScenario(name: "processing-search", model: model(.processing, seq: 7) {
                $0.transcript = Transcript(stable: ticket412)
                $0.message = f.searchingTicket(412)
            }, now: t0.addingTimeInterval(0.42), level: 0),
            OverlayScenario(name: "choices", model: model(.choices, seq: 9) {
                $0.transcript = Transcript(stable: openWWT)
                list(&$0, wwt, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(1.8), level: 0.15),
            OverlayScenario(name: "choices-answer", model: model(.choices, seq: 10) {
                $0.transcript = Transcript(stable: openWWT)
                list(&$0, wwt, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6.4), f)
                $0.answer = Transcript(stable: said("Die", "Number"), volatile: said("zweite", "two"))
            }, now: t0.addingTimeInterval(2.4), level: 0.55),
            OverlayScenario(name: "choices-held", model: model(.choices, seq: 11) {
                $0.transcript = Transcript(stable: openWWT)
                list(&$0, wwt, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(30), f)
                $0.countdownFrozen = 3.4
            }, now: t0.addingTimeInterval(4.0), level: 0.05),
            OverlayScenario(name: "choices-more", model: model(.choices, seq: 12) {
                $0.transcript = Transcript(stable: said("Öffne QZ", "Open QZ"))
                list(&$0, qz, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(1.4), level: 0.1),
            OverlayScenario(name: "choices-page2", model: model(.choices, seq: 14) {
                $0.transcript = Transcript(stable: said("Öffne QZ", "Open QZ"))
                list(&$0, qz, page: 1, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(0.9), level: 0.1),
            OverlayScenario(name: "choices-narrowed", model: model(.choices, seq: 12) {
                $0.transcript = Transcript(stable: openWWT)
                list(&$0, [item(1, 628, "WWT: Website Relaunch [AGIL]", badges: [.favorite, .recent]),
                           item(2, 315, "WWT: TYPO3 Website maintenance [AGIL]", badges: [.recent])],
                     page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
                $0.hint = f.narrowed("Website", count: 2)
            }, now: t0.addingTimeInterval(1.1), level: 0.2),
            OverlayScenario(name: "choices-unclear", model: model(.choices, seq: 11) {
                $0.transcript = Transcript(stable: openWWT)
                list(&$0, wwt, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(7.5), f)
                $0.hint = f.unclearAnswer("Hi.")
                $0.hintIsAlert = true
            }, now: t0.addingTimeInterval(4.1), level: 0.05),
            OverlayScenario(name: "choices-nomore", model: model(.choices, seq: 13) {
                $0.transcript = Transcript(stable: openWWT)
                list(&$0, wwt, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
                $0.hint = f.noMoreChoices
            }, now: t0.addingTimeInterval(1.6), level: 0.05),
            OverlayScenario(name: "choices-long-titles", model: model(.choices, seq: 15) {
                $0.transcript = Transcript(stable: said("Öffne Plattform", "Open Plattform"))
                list(&$0, long, page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(1.0), level: 0.1),
            OverlayScenario(name: "choices-confirm", model: model(.choices, seq: 10) {
                $0.transcript = Transcript(stable: said("Öffne Ebenbetreuung", "Open IBN Betreuung"))
                list(&$0, [item(1, 2041, "IBN: Betreuung Plattform [SLA]", badges: [.recent])],
                     page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(2.6), level: 0.1),
            OverlayScenario(name: "choices-tickets", model: model(.choices, seq: 9) {
                $0.transcript = Transcript(stable: said("Öffne WWT Ticket 112", "Open WWT ticket 112"))
                list(&$0, [
                    item(1, 628, "WWT: Website Relaunch [AGIL]", badges: [.favorite, .recent, .mine], ticket: (40112, 112)),
                    item(2, 315, "WWT: TYPO3 Website maintenance [AGIL]", badges: [.recent], ticket: (31877, 112)),
                    item(3, 314, "WWT: Maintenance [SLA]", ticket: (24410, 112)),
                    item(4, 693, "WWT: Grand Navigation [AGIL]", badges: [.completed], ticket: (18233, 112)),
                ], page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(1.2), level: 0.1),
            OverlayScenario(name: "choices-ticket-chips", model: model(.choices, seq: 9) {
                $0.transcript = Transcript(stable: "Ticket 412")
                list(&$0, [
                    item(1, 628, "WWT: Website Relaunch [AGIL]", badges: [.mine], ticket: (40112, 412)),
                    item(2, 2071, "QZ: CRM [INT]", ticket: (31877, 41)),
                    item(3, 2041, "IBN: Betreuung Plattform [SLA]", badges: [.completed], ticket: (24410, 4120)),
                ], page: 0, pageSize: 6, deadline: t0.addingTimeInterval(6), f)
            }, now: t0.addingTimeInterval(1.2), level: 0.1),
            OverlayScenario(name: "retry", model: model(.retry, seq: 6) {
                $0.transcript = Transcript(stable: said("Hallo Welt", "Hello world"))
                $0.message = f.notUnderstoodRetry
            }, now: t0.addingTimeInterval(0.8), level: 0.12),
            OverlayScenario(name: "retry-nothing", model: model(.retry, seq: 6) {
                $0.message = f.nothingHeardRetry
            }, now: t0.addingTimeInterval(0.8), level: 0.05),
            OverlayScenario(name: "opening", model: model(.opening, seq: 15) {
                $0.transcript = Transcript(stable: openWWT)
                $0.preview = "WWT: TYPO3 Website maintenance"
            }, now: t0.addingTimeInterval(0.15), level: 0),
            OverlayScenario(name: "success", model: model(.success, seq: 16) {
                $0.transcript = Transcript(stable: openWWT)
                $0.message = "WWT: TYPO3 Website maintenance"
            }, now: t0.addingTimeInterval(0.55), level: 0),
            OverlayScenario(name: "success-long", model: model(.success, seq: 16) {
                $0.message = f.ticketTitle(1234, project: "RBZ: Kassensystem Umzug von Stand 2024.3 auf Stand 2025.1")
            }, now: t0.addingTimeInterval(0.55), level: 0),
            OverlayScenario(name: "success-hint", model: model(.success, seq: 16) {
                $0.message = f.ticketTitle(47285, project: "QZ: CRM")
                $0.hint = f.automationSetupHint
            }, now: t0.addingTimeInterval(1.0), level: 0),
            OverlayScenario(name: "error", model: model(.error, seq: 8) {
                $0.transcript = Transcript(stable: ticket412)
                $0.message = f.ticketNotFound(412, code: "WWT")
            }, now: t0.addingTimeInterval(0.5), level: 0),
            OverlayScenario(name: "error-offline", model: model(.error, seq: 8) {
                $0.transcript = Transcript(stable: ticket412)
                $0.message = f.acUnreachable
                $0.hint = f.hint(forError: f.acUnreachable)
            }, now: t0.addingTimeInterval(0.5), level: 0),
            OverlayScenario(name: "error-mic", model: model(.error, seq: 3) {
                $0.message = f.micDenied
                $0.hint = f.hint(forError: f.micDenied)
            }, now: t0.addingTimeInterval(0.5), level: 0),
            OverlayScenario(name: "error-nothing", model: model(.error, seq: 3) {
                $0.message = f.nothingHeard
                $0.hint = f.hint(forError: f.nothingHeard)
            }, now: t0.addingTimeInterval(0.5), level: 0),
        ]
    }

    /// A choice row as the flow builds it (`ChoiceBuilder`), from an AC project name.
    public static func item(_ n: Int, _ projectId: Int, _ name: String, badges: Set<Badge> = [],
                            ticket: (taskId: Int, number: Int)? = nil) -> ChoiceItem {
        let p = ProjectEntry(id: projectId, name: name)
        let display = p.code.map { p.title.isEmpty ? $0 : "\($0): \(p.title)" } ?? p.title
        let target: ChoiceTarget = ticket.map { .task(projectId: projectId, taskId: $0.taskId, number: $0.number) }
            ?? .project(id: projectId)
        // "Ticket 412 · WWT: …" reads the same in both languages.
        let detail = ticket.map { FlowText.de.ticketTitle($0.number, project: name.trimmingCharacters(in: .whitespaces)) }
            ?? name.trimmingCharacters(in: .whitespaces)
        let label = p.title.count <= 12 ? p.title : String(p.title.prefix(11)) + "…"
        return ChoiceItem(n: n, label: label, title: p.title, code: p.code, type: p.type, displayName: display,
                          detail: detail, badges: badges, target: target)
    }

    /// Fills the list fields the way `VoiceFlow.renderList` does.
    static func list(_ m: inout OverlayModel, _ items: [ChoiceItem], page: Int, pageSize: Int, deadline: Date,
                     _ f: FlowText = .de) {
        let pageCount = max(1, (items.count + pageSize - 1) / pageSize)
        let lo = min(page * pageSize, items.count)
        m.choices = Array(items[lo..<min(lo + pageSize, items.count)])
        m.total = items.count
        m.page = page
        m.pageCount = pageCount
        m.pageSize = pageSize
        m.deadline = deadline
        m.hint = items.count == 1 ? f.sayYesOrOne : nil
    }
}
