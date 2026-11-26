import Foundation

/// One normalized word of an utterance or a project name.
public struct Token: Sendable, Hashable, CustomStringConvertible {
    /// Folded lowercase text, may contain "+" or "&" (e.g. "s+k").
    public var text: String
    /// True for "WWT", "CKZ", "S+K" in the source or for collapsed spellings ("we we te").
    public var isAcronym: Bool
    public init(text: String, isAcronym: Bool = false) { self.text = text; self.isAcronym = isAcronym }
    /// Alphanumeric-only form used for all comparisons ("s+k" -> "sk").
    public var key: String { String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
    public var description: String { isAcronym ? text.uppercased() : text }
}

public enum TextNorm {
    /// Rewrites digits and punctuation before tokenizing. Keeps case for acronym detection.
    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "ß", with: "ss")
        // German thousands groups from STT: "47.285", "47. 285", "47 285" -> "47285".
        t = t.replacingOccurrences(of: #"\b(\d{1,3})(?:\.\s?|\s)(\d{3})\b"#, with: "$1$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[-_/–—]"#, with: " ", options: .regularExpression)
        // STT glues acronyms to the next word: "WWTilonch" -> "WWT ilonch".
        t = t.replacingOccurrences(of: #"\b(\p{Lu}{2,})(\p{Ll}{3,})"#, with: "$1 $2", options: .regularExpression)
        // "S&K" / "S+K" stay one token; a free-standing "&" or "+" becomes its own token.
        t = t.replacingOccurrences(of: #"\s([&+])\s"#, with: " $1 ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}+& ]"#, with: " ", options: .regularExpression)
        return t
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")).lowercased()
    }

    /// Full pipeline: clean, split, fold, detect acronyms, collapse spelled letters.
    public static func tokenize(_ raw: String) -> [Token] {
        let words = clean(raw).split(separator: " ").map(String.init)
        let tokens = words.map { w -> Token in
            let letters = w.filter(\.isLetter)
            let acronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            // "S&K" and "S+K" are the same code.
            return Token(text: fold(w.count > 1 ? w.replacingOccurrences(of: "&", with: "+") : w), isAcronym: acronym)
        }
        return collapseSpelling(tokens)
    }

    /// Stable key of a filler-free query: token keys joined by one space ("eben betreuung").
    /// Used for learned picks in `History` and as the alias text in `History.learnedAliases`.
    public static func queryKey(_ tokens: [Token]) -> String {
        tokens.map(\.key).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// German letter names as spoken. Values are the letter.
    static let letterNames: [String: String] = [
        "a": "a", "ah": "a", "be": "b", "beh": "b", "ce": "c", "tse": "c", "de": "d", "deh": "d", "e": "e", "eh": "e",
        "ef": "f", "eff": "f", "ge": "g", "geh": "g", "ha": "h", "hah": "h", "i": "i", "ih": "i", "jot": "j",
        "ka": "k", "kah": "k", "el": "l", "ell": "l", "em": "m", "emm": "m", "en": "n", "enn": "n", "o": "o",
        "oh": "o", "pe": "p", "peh": "p", "ku": "q", "kuh": "q", "er": "r", "err": "r", "es": "s", "ess": "s",
        "te": "t", "teh": "t", "tee": "t", "u": "u", "uh": "u", "vau": "v", "fau": "v", "we": "w", "weh": "w",
        "ix": "x", "ypsilon": "y", "zett": "z", "zet": "z",
    ]
    /// Letter names that are also everyday German words. They only count inside a run with strong letters, and never
    /// next to an acronym: "Geh WWT Relaunch" is the verb and WWT, not "GWWT".
    static let weakLetters: Set<String> = ["a", "e", "i", "o", "u", "de", "er", "es", "en", "em", "el", "eh", "oh", "ah", "geh"]
    static let joiners: Set<String> = ["und", "plus", "&", "+"]
    /// Multi-character strong letter names, longest first, for splitting glued spellings ("wewete").
    static let gluedNames: [String] = letterNames.keys
        .filter { $0.count >= 2 && !weakLetters.contains($0) }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }

    static func letter(_ t: Token) -> String? {
        if t.text.count == 1, t.text.first!.isLetter { return t.text }
        return letterNames[t.text]
    }

    /// "WW" in "WW T": a short all-caps token that joins a run of single spelled letters.
    static func shortAcronym(_ t: Token) -> String? {
        guard t.isAcronym, (2...3).contains(t.text.count), t.text.allSatisfy(\.isLetter) else { return nil }
        return t.text
    }

    /// "wewete" -> "wwt": a single word made of at least 3 strong letter names and nothing else.
    static func gluedSpelling(_ word: String) -> String? {
        guard word.count >= 5, word.allSatisfy(\.isLetter) else { return nil }
        let chars = Array(word)
        // Memoized DFS over positions; the first full segmentation with >= 3 names wins.
        var failed = Set<Int>()
        func walk(_ at: Int) -> [String]? {
            if at == chars.count { return [] }
            if failed.contains(at) { return nil }
            for name in gluedNames where at + name.count <= chars.count && String(chars[at..<(at + name.count)]) == name {
                if let rest = walk(at + name.count) { return [letterNames[name]!] + rest }
            }
            failed.insert(at)
            return nil
        }
        guard let letters = walk(0), letters.count >= 3 else { return nil }
        return letters.joined()
    }

    /// "we we te" -> WWT, "w w t" -> WWT, "WW T" -> WWT, "Wewete" -> WWT,
    /// "s und k" / "es und ka" / "k & t" -> S+K.
    static func collapseSpelling(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            if i + 2 < tokens.count, let a = letter(tokens[i]), joiners.contains(tokens[i + 1].text),
               let b = letter(tokens[i + 2]),
               !(weakLetters.contains(tokens[i].text) && weakLetters.contains(tokens[i + 2].text)) {
                out.append(Token(text: "\(a)+\(b)", isAcronym: true)); i += 3; continue
            }
            // A run of spelled letters, optionally with short acronyms next to single letters ("WW T").
            var j = i, letters = "", strong = 0, units = 0, weakSingles = 0, acronyms = 0
            while j < tokens.count {
                if let l = letter(tokens[j]) {
                    letters += l; units += 1
                    if weakLetters.contains(tokens[j].text) { weakSingles += 1 } else { strong += 1 }
                } else if let s = shortAcronym(tokens[j]), letters.count + s.count <= 4,
                          j > i || (j + 1 < tokens.count && letter(tokens[j + 1]) != nil) {
                    // Codes have 2-4 letters: "WW T" joins, "Q Z CRM" stays "QZ" + "CRM".
                    letters += s; units += 1; strong += 1; acronyms += 1
                } else { break }
                j += 1
            }
            // With an acronym in the run, every single letter must be a strong letter name ("WW T", not "IT e").
            let spelled = acronyms > 0 ? (units > acronyms && weakSingles == 0) : (units >= 2 && strong * 2 >= units)
            if spelled {
                out.append(Token(text: letters, isAcronym: true)); i = j; continue
            }
            if !tokens[i].isAcronym, let glued = gluedSpelling(tokens[i].text) {
                out.append(Token(text: glued, isAcronym: true)); i += 1; continue
            }
            out.append(tokens[i]); i += 1
        }
        return out
    }
}

/// German cardinal and ordinal words.
public enum GermanNumbers {
    private static let morphemes: [(String, Int)] = [
        ("siebzehn", 17), ("achtzehn", 18), ("neunzehn", 19), ("dreizehn", 13), ("vierzehn", 14),
        ("funfzehn", 15), ("sechzehn", 16), ("zwanzig", 20), ("dreissig", 30), ("vierzig", 40),
        ("funfzig", 50), ("sechzig", 60), ("siebzig", 70), ("achtzig", 80), ("neunzig", 90),
        ("hundert", 100), ("tausend", 1000), ("sieben", 7), ("zwolf", 12), ("sechs", 6),
        ("eins", 1), ("eine", 1), ("zwei", 2), ("zwo", 2), ("drei", 3), ("vier", 4), ("funf", 5),
        ("acht", 8), ("neun", 9), ("zehn", 10), ("null", 0), ("elf", 11), ("ein", 1), ("und", -1),
    ]

    /// "412", "vierhundertzwolf", "siebenundvierzigtausendzweihundertfunfundachtzig".
    /// Digit strings return their value (nil beyond `Int.max`); number words above `composeLimit` return nil
    /// ("hunderthunderthundert…" must never overflow).
    public static func cardinal(_ token: String) -> Int? {
        if let n = Int(token) { return n }
        var rest = Substring(token), total = 0, current = 0, saw = false
        while !rest.isEmpty {
            guard let (m, v) = morphemes.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            rest = rest.dropFirst(m.count)
            switch v {
            case -1: continue
            case 100: current = max(current, 1) * 100
            case 1000: total += max(current, 1) * 1000; current = 0
            default: current += v
            }
            // Both stay <= composeLimit before the next step, so no step above can overflow.
            if current > composeLimit || total > composeLimit || total + current > composeLimit { return nil }
            saw = true
        }
        return saw ? total + current : nil
    }

    /// "erste" ... "zehnte" with inflections; "letzte" = -1.
    public static func ordinal(_ token: String) -> Int? {
        let stems: [(String, Int)] = [
            ("erst", 1), ("zweit", 2), ("dritt", 3), ("viert", 4), ("funft", 5), ("sechst", 6),
            ("siebent", 7), ("siebt", 7), ("acht", 8), ("neunt", 9), ("zehnt", 10), ("letzt", -1),
        ]
        for (stem, v) in stems where token.hasPrefix(stem) {
            if ["e", "er", "en", "es", "em"].contains(String(token.dropFirst(stem.count))) { return v }
        }
        return nil
    }

    /// German cardinal as written, 1...99 ("eins", "zwölf", "einundzwanzig", "dreißig"); nil outside. `cardinal`
    /// reads every result back. Used for the answer-phase contextual strings.
    public static func spelled(_ n: Int) -> String? {
        let units = ["", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun"]
        let teens = ["zehn", "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"]
        let tens = ["", "", "zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig"]
        switch n {
        case 1...9: return units[n]
        case 10...19: return teens[n - 10]
        case 20...99:
            let (t, u) = (n / 10, n % 10)
            guard u > 0 else { return tens[t] }
            return (u == 1 ? "ein" : units[u]) + "und" + tens[t]
        default: return nil
        }
    }

    /// Largest number `compose` returns. Task ids have 5 digits today, task numbers 4.
    public static let composeLimit = 999_999

    /// One spoken numeral of a run: its value and whether it was the bare word "hundert"/"tausend".
    public struct Part: Sendable, Equatable {
        public var value: Int
        public var isMultiplierWord: Bool
        /// True for a standalone "und" between numerals ("acht und funfzig").
        public var isJoiner: Bool
        public init(value: Int, isMultiplierWord: Bool = false, isJoiner: Bool = false) {
            self.value = value; self.isMultiplierWord = isMultiplierWord; self.isJoiner = isJoiner
        }
    }

    /// Composes adjacent numerals the way STT splits them (REVIEW M6):
    /// "4 12" -> 412, "400 12" -> 412, "47000 285" -> 47285, "vier eins zwei" -> 412,
    /// "vier hundert zwolf" -> 412, "sieben und vierzig tausend ..." -> 47...
    /// A value is added when the running group has enough trailing zeros ("400" + "12"), otherwise its digits are appended.
    /// Returns nil for an empty run or a result above `composeLimit`. Never traps: every part and every
    /// intermediate value is checked against `composeLimit` before the next multiplication.
    public static func compose(_ parts: [Part]) -> Int? {
        var total = 0
        var group: Int? = nil
        var pendingJoiner = false
        for p in parts {
            if p.isJoiner { pendingJoiner = group != nil; continue }
            defer { pendingJoiner = false }
            guard (0...composeLimit).contains(p.value) else { return nil }
            if p.isMultiplierWord {
                if p.value >= 1000 { total = (total + (group ?? 1)) * p.value; group = nil }
                else { group = (group ?? 1) * p.value }
            } else if let g = group {
                let v = p.value
                var place = 10                                   // 10^(digits of v)
                while place <= v { place *= 10 }
                if pendingJoiner, (20...90).contains(v), v % 10 == 0, g % 100 < 10 {
                    group = g - g % 10 + v + g % 10              // "acht und funfzig" -> 58
                } else if v != 0, g % place == 0, g >= place {
                    group = g + v                                // "400 12" -> 412
                } else {
                    group = g * place + v                        // "4 12" -> 412, "4 1 2" -> 412
                }
            } else {
                group = p.value
            }
            if total + (group ?? 0) > composeLimit { return nil }
        }
        guard group != nil || total > 0 else { return nil }
        let n = total + (group ?? 0)
        return n <= composeLimit ? n : nil
    }
}

public enum Fuzzy {
    /// Optimal string alignment distance (Damerau-Levenshtein without repeated edits), capped.
    public static func osa(_ a: String, _ b: String, cap: Int = 3) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > cap { return cap + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    /// Koelner Phonetik for folded lowercase input ("relaunch", "relonch", "rilonch" -> "7564").
    public static func cologne(_ s: String) -> String {
        let c = Array(s.filter { $0 >= "a" && $0 <= "z" })
        var codes: [Character] = []
        for i in c.indices {
            let ch = c[i], prev: Character? = i > 0 ? c[i - 1] : nil, next: Character? = i + 1 < c.count ? c[i + 1] : nil
            var code: String
            switch ch {
            case "a", "e", "i", "j", "o", "u", "y": code = "0"
            case "h": code = ""
            case "b": code = "1"
            case "p": code = next == "h" ? "3" : "1"
            case "d", "t": code = (next.map { "csz".contains($0) } ?? false) ? "8" : "2"
            case "f", "v", "w": code = "3"
            case "g", "k", "q": code = "4"
            case "c":
                if i == 0 { code = (next.map { "ahkloqrux".contains($0) } ?? false) ? "4" : "8" }
                else if let p = prev, "sz".contains(p) { code = "8" }
                else { code = (next.map { "ahkoqux".contains($0) } ?? false) ? "4" : "8" }
            case "x": code = (prev.map { "ckq".contains($0) } ?? false) ? "8" : "48"
            case "l": code = "5"
            case "m", "n": code = "6"
            case "r": code = "7"
            case "s", "z": code = "8"
            default: code = ""
            }
            codes.append(contentsOf: code)
        }
        var out: [Character] = []
        for (i, d) in codes.enumerated() where i == 0 || d != codes[i - 1] { out.append(d) }
        return String(out.enumerated().filter { $0.offset == 0 || $0.element != "0" }.map(\.element))
    }
}
