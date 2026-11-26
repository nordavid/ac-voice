import Foundation
import ACVoiceCore

/// Choice rows from resolver candidates and ticket refs.
enum ChoiceBuilder {
    static let maxLabel = 12

    /// "WWT: Website Relaunch" (no type).
    static func display(_ p: ProjectEntry) -> String {
        guard let code = p.code else { return p.title.isEmpty ? p.name : p.title }
        return p.title.isEmpty ? code : "\(code): \(p.title)"
    }

    static func badges(_ p: ProjectEntry?, now: Date) -> Set<Badge> {
        guard let p else { return [] }
        var b: Set<Badge> = []
        if p.signals.favorite { b.insert(.favorite) }
        let window = Signals.recentOpenDays * 86_400
        if p.signals.timeRecords30d > 0 || p.signals.recentOpens.contains(where: { now.timeIntervalSince($0) <= window }) {
            b.insert(.recent)
        }
        return b
    }

    static func projects(_ entries: [ProjectEntry], now: Date) -> [ChoiceItem] {
        let labels = Self.labels(entries)
        return entries.enumerated().map { i, p in
            ChoiceItem(n: i + 1, label: labels[i], title: p.title, code: p.code, type: p.type, displayName: display(p),
                       detail: p.name.trimmingCharacters(in: .whitespaces), badges: badges(p, now: now),
                       target: .project(id: p.id))
        }
    }

    static func tickets(_ refs: [TaskRef], projects: [Int: ProjectEntry], mine: Set<Int>, now: Date) -> [ChoiceItem] {
        let entries = refs.map { projects[$0.projectId] }
        let labels = Self.labels(entries)
        return refs.enumerated().map { i, ref in
            let p = entries[i]
            let shown = ref.number > 0 ? ref.number : ref.id
            let name = p.map { $0.name.trimmingCharacters(in: .whitespaces) } ?? "#\(ref.projectId)"
            var badges = Self.badges(p, now: now)
            if mine.contains(ref.id) { badges.insert(.mine) }
            if ref.isCompleted { badges.insert(.completed) }
            return ChoiceItem(n: i + 1, label: p == nil ? "#\(ref.projectId)" : labels[i], title: p?.title ?? name,
                              code: p?.code, type: p?.type, displayName: p.map(display) ?? name,
                              detail: FlowText.ticketTitle(shown, project: name), badges: badges,
                              target: .task(projectId: ref.projectId, taskId: ref.id, number: ref.number))
        }
    }

    /// Short key labels: the whole title when it fits, else the title words no other choice has when they fit,
    /// else the longest of them ("Website Relaunch" next to "Maintenance" -> "Relaunch"), truncated if needed.
    /// Equal labels get the code in front ("IBN Relaunch").
    static func labels(_ entries: [ProjectEntry?]) -> [String] {
        let words: [[String]] = entries.map { e in
            (e?.title ?? "").split(separator: " ").map(String.init)
                .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        }
        var out = entries.indices.map { i -> String in
            let mine = words[i]
            guard !mine.isEmpty else { return truncate(entries[i]?.code ?? entries[i]?.name ?? "") }
            let full = mine.joined(separator: " ")
            if full.count <= maxLabel { return full }
            let others = Set(words.indices.filter { $0 != i }.flatMap { words[$0].map(TextNorm.fold) })
            let distinct = mine.filter { !others.contains(TextNorm.fold($0)) }
            let pool = distinct.isEmpty ? mine : distinct
            let joined = pool.joined(separator: " ")
            if joined.count <= maxLabel { return joined }
            // Longest word first, the earlier one on ties: longer words are the more specific ones.
            let longest = pool.enumerated().max { a, b in
                a.element.count != b.element.count ? a.element.count < b.element.count : a.offset > b.offset
            }!.element
            return truncate(longest)
        }
        let groups = Dictionary(grouping: out.indices, by: { TextNorm.fold(out[$0]) })
        for (_, idx) in groups where idx.count > 1 {
            for i in idx { if let code = entries[i]?.code { out[i] = truncate(code + " " + out[i]) } }
        }
        return out
    }

    static func truncate(_ s: String) -> String {
        s.count <= maxLabel ? s : String(s.prefix(maxLabel - 1)) + "…"
    }
}

/// Live preview, live cancel and hesitations from DT partials (PLAN 2.3, REVIEW M1). The hangover rule and the
/// dangling-word rule live in Core (`HangoverPolicy`, `Parser.looksIncomplete`); the flow owns the values
/// (`FlowTimings.hangovers`) and sends the result to the speech layer.
enum LivePolicy {
    /// Cancel words safe to act on in a partial. "nein" and "egal" are not: "Nein, Ticket 412" goes on.
    static let strongCancel: Set<String> = ["abbrechen", "abbruch", "stopp", "stop", "cancel"]

    static func isStrongCancel(_ text: String) -> Bool {
        TextNorm.tokenize(text).contains { strongCancel.contains($0.key) }
    }

    /// The text the hangover rule reads: the best hypothesis that heard the most words (DT or ST may lag behind on
    /// the last word), the first one on a tie.
    static func leading(_ hyps: [Hypothesis]) -> String {
        let best = hyps.filter { $0.weight >= 1 }
        var lead: (text: String, words: Int)?
        for h in best.isEmpty ? hyps : best {
            let words = TextNorm.tokenize(h.text).count
            if lead == nil || words > lead!.words { lead = (h.text, words) }
        }
        return lead?.text ?? ""
    }

    /// An answer that holds only dangling words and fillers so far ("die", "Nummer", "Öffne das", "äh"): the gate cut
    /// a hesitation, so the flow listens on without counting a failed answer.
    static func isHesitation(_ text: String) -> Bool {
        !TextNorm.tokenize(text).isEmpty && Parser.looksIncomplete(text, choosing: true)
    }

    static func preview(_ i: Interpretation) -> String? {
        switch i {
        case .myTasks:
            return FlowText.myTasks
        case .project(.unique(let s), _):
            return ChoiceBuilder.display(s.project)
        case .project(.ambiguous(let list), _):
            return FlowText.projectCount(list.count, code: commonCode(list.map(\.project)))
        case .task(let r):
            let project: String?
            switch r.projects {
            case .unique(let s)?: project = ChoiceBuilder.display(s.project)
            case .ambiguous(let list)?: project = commonCode(list.map(\.project))
            default: project = nil
            }
            return FlowText.ticketTitle(r.number, project: project)
        default:
            return nil
        }
    }

    /// The code all candidates share, if any.
    static func commonCode(_ projects: [ProjectEntry]) -> String? {
        let codes = Set(projects.map { $0.code.map(ProjectEntry.codeKey) })
        guard codes.count == 1, let first = projects.first?.code else { return nil }
        return first
    }
}
