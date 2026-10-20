import Foundation

/// The kind of a script line, following the Fountain format (fountain.io), plus the Italian
/// conventions (EST. for exteriors, transitions ending in " A:").
enum Element: String {
    case titlePage, sceneHeading, action, character, parenthetical, dialogue, transition, centered
    case pageBreak, section, synopsis, note, empty
}

struct Emphasis: OptionSet, Hashable {
    let rawValue: Int
    static let italic = Emphasis(rawValue: 1)
    static let bold = Emphasis(rawValue: 2)
    static let underline = Emphasis(rawValue: 4)
}

/// *Italic*, **bold** or _underlined_ text, as a UTF-16 range.
struct StyledRun: Equatable {
    var range: NSRange
    var style: Emphasis
}

struct Line {
    var element: Element
    /// What gets printed: forcing marks, notes and emphasis marks removed.
    var text: String
    /// UTF-16 range in the source, without the line break.
    var range: NSRange
    var sceneNumber: String?
    /// Emphasis in `text`.
    var runs: [StyledRun] = []
}

/// One "Key: value" of the title page; values can span several lines.
struct TitleField: Equatable {
    var key: String
    var value: String
}

/// Who plays a character and how to reach them. Kept in the title page under "Cast:", one line each:
/// `MARCO | Mario Rossi | +39 333 1234567 | mario@example.com | notes`. Other apps don't print it.
struct CastMember: Equatable {
    var name: String
    var actor = ""
    var phone = ""
    var email = ""
    var notes = ""

    var isEmpty: Bool { actor.isEmpty && phone.isEmpty && email.isEmpty && notes.isEmpty }

    static func list(_ fields: [TitleField]) -> [CastMember] {
        let value = fields.last { $0.key.lowercased() == "cast" }?.value ?? ""
        return value.components(separatedBy: .newlines).compactMap { line in
            let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            func part(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
            return CastMember(name: name.uppercased(), actor: part(1), phone: part(2), email: part(3), notes: part(4))
        }
    }

    /// The title page fields with `members` as their "Cast:" value; members with nothing filled in are dropped.
    static func setting(_ members: [CastMember], in fields: [TitleField]) -> [TitleField] {
        let lines = members.filter { !$0.isEmpty }.map { m in
            var parts = [m.name, m.actor, m.phone, m.email, m.notes]
                .map { $0.replacingOccurrences(of: "|", with: "/").components(separatedBy: .newlines).joined(separator: " ") }
            while parts.last?.isEmpty == true { parts.removeLast() }
            return parts.joined(separator: " | ")
        }
        var fields = fields.filter { $0.key.lowercased() != "cast" }
        if !lines.isEmpty { fields.append(TitleField(key: "Cast", value: lines.joined(separator: "\n"))) }
        return fields
    }
}

struct ScriptScene: Identifiable {
    var id: Int
    var number: String
    var heading: String
    var setting: String      // INT., EXT., INT./EXT.
    var location: String     // CASA DI MARCO - CUCINA
    var time: String         // NOTTE
    /// The time of day to shoot it: a CONTINUOUS or LATER scene takes the time of the one before.
    var shootingTime = ""
    var offset: Int          // UTF-16 offset of the heading in the source
    var lines: Range<Int>    // indexes into Screenplay.lines, heading included
    var characters: [String] = []

    /// The place before any sub-location: CASA DI MARCO for CASA DI MARCO - CUCINA.
    var mainLocation: String { location.components(separatedBy: " - ").first ?? location }
}

nonisolated struct CharacterInfo: Identifiable, Sendable {
    var name: String
    var lines = 0
    var scenes: [Int] = []
    var id: String { name }
    var sceneCount: Int { scenes.count }
    var firstScene: Int { scenes.first ?? .max }
}

/// A parsed script. Cheap enough to rebuild on every keystroke.
struct Screenplay {
    private(set) var lines: [Line]
    private(set) var scenes: [ScriptScene] = []
    private(set) var characters: [CharacterInfo] = []

    init(_ source: String, activeLocation: Int? = nil, titlePage: Bool = true) {
        lines = Fountain.parse(source, activeLocation: activeLocation, titlePage: titlePage)
        var info: [String: CharacterInfo] = [:]
        var order: [String] = []
        for i in lines.indices {
            let line = lines[i]
            switch line.element {
            case .sceneHeading:
                if !scenes.isEmpty { scenes[scenes.count - 1].lines = scenes[scenes.count - 1].lines.lowerBound..<i }
                var scene = Fountain.scene(line, id: scenes.count, lines: i..<lines.count)
                scene.shootingTime = Fountain.continuity.contains(scene.time) ? scenes.last?.shootingTime ?? "" : scene.time
                lines[i].sceneNumber = scene.number
                scenes.append(scene)
            case .character:
                let name = Fountain.characterName(line.text)
                if info[name] == nil { info[name] = CharacterInfo(name: name); order.append(name) }
                info[name]!.lines += 1
                if let id = scenes.last?.id {
                    if info[name]!.scenes.last != id { info[name]!.scenes.append(id) }
                    if !scenes[id].characters.contains(name) { scenes[id].characters.append(name) }
                }
            default: break
            }
        }
        characters = order.map { info[$0]! }
    }
}

enum Fountain {
    static let headingPattern = #"^(INT\.?/EXT|EXT\.?/INT|INT\.?/EST|EST\.?/INT|I/E|E/I|INT|EXT|EST)(\.|\s)"#

    static func isHeading(_ t: String) -> Bool {
        t.range(of: headingPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// All capitals, ignoring a trailing extension like (V.O.).
    static func isUppercase(_ t: String) -> Bool {
        let name = t.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return name.contains(where: \.isLetter) && name == name.uppercased()
    }

    static func isTransition(_ t: String) -> Bool {
        isUppercase(t) && (t.hasSuffix("TO:") || t.hasSuffix(" A:"))
    }

    /// MARCO for "MARCO (V.O.)".
    static func characterName(_ cue: String) -> String {
        let name = cue.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return name.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Times of day a heading can start or end with, longest first so "PRIMO MATTINO" wins over "MATTINO".
    static let timesOfDay: [String] = ([
        "GIORNO", "NOTTE", "ALBA", "TRAMONTO", "MATTINA", "MATTINO", "PRIMO MATTINO", "MEZZOGIORNO", "POMERIGGIO",
        "SERA", "SERATA", "CREPUSCOLO", "IMBRUNIRE", "MEZZANOTTE", "NOTTE FONDA",
        "DAY", "NIGHT", "DAWN", "DUSK", "MORNING", "AFTERNOON", "EVENING", "SUNSET", "SUNRISE", "LATE NIGHT",
    ] + continuity).sorted { $0.count > $1.count }

    /// Times of day that continue the previous scene.
    static let continuity: Set<String> = ["CONTINUOUS", "CONTINUOUS ACTION", "MOMENTS LATER", "LATER", "SAME", "SAME TIME",
                                          "CONTINUA", "CONTINUO", "POCO DOPO", "PIÙ TARDI", "STESSO MOMENTO"]

    /// Where the marks that force an element are in a raw line: `!` `~` for action, `.` for a heading,
    /// `@` and `^` around a cue, `>` for a transition, `>` `<` around centred text.
    static func typeMarks(_ raw: String, _ e: Element) -> [NSRange] {
        let ns = raw as NSString
        func blank(_ i: Int) -> Bool { ns.character(at: i) == 32 || ns.character(at: i) == 9 }
        var start = 0, end = ns.length
        while start < end, blank(start) { start += 1 }
        while end > start, blank(end - 1) { end -= 1 }
        guard end > start else { return [] }
        let first = ns.substring(with: NSRange(location: start, length: 1)), last = ns.substring(with: NSRange(location: end - 1, length: 1))
        let head = NSRange(location: start, length: 1), tail = NSRange(location: end - 1, length: 1)
        switch e {
        case .action where first == "!" || first == "~": return [head]
        case .sceneHeading where first == "." && !raw.hasPrefix(".."): return [head]
        case .character: return (first == "@" ? [head] : []) + (last == "^" && end - start > 1 ? [tail] : [])
        case .transition where first == ">": return [head]
        case .centered: return [head] + (last == "<" && end - start > 1 ? [tail] : [])
        default: return []
        }
    }

    /// Removes *italic*, **bold** and _underline_ marks.
    static func plain(_ s: String) -> String { emphasis(s).text }

    /// Splits Fountain emphasis marks from `s`: the plain text with its styled runs, the same runs as
    /// ranges of `s`, and where the marks are in `s`. A mark counts only when a closing one follows;
    /// a backslash keeps the next character as it is.
    static func emphasis(_ s: String) -> (text: String, runs: [StyledRun], sourceRuns: [StyledRun], marks: [NSRange]) {
        guard s.contains("*") || s.contains("_") || s.contains("\\") else { return (s, [], [], []) }
        let chars = Array(s)
        var out = "", outLength = 0, sourceLength = 0
        var runs: [StyledRun] = [], sourceRuns: [StyledRun] = [], marks: [NSRange] = []
        var open: [Emphasis: (out: Int, source: Int)] = [:]
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1])
                let u = String(chars[i + 1]).utf16.count
                outLength += u; sourceLength += 1 + u; i += 2; continue
            }
            if c == "*" || c == "_" {
                var n = 1
                if c == "*" { while i + n < chars.count, chars[i + n] == "*", n < 3 { n += 1 } }
                let token = String(repeating: c, count: n)
                let style: Emphasis = c == "_" ? .underline : n == 1 ? .italic : n == 2 ? .bold : [.bold, .italic]
                if let start = open.removeValue(forKey: style) {
                    runs.append(StyledRun(range: NSRange(location: start.out, length: outLength - start.out), style: style))
                    sourceRuns.append(StyledRun(range: NSRange(location: start.source, length: sourceLength - start.source), style: style))
                    marks.append(NSRange(location: sourceLength, length: n)); sourceLength += n; i += n; continue
                }
                if i + n < chars.count, !chars[i + n].isWhitespace, String(chars[(i + n)...]).contains(token) {
                    open[style] = (outLength, sourceLength + n)
                    marks.append(NSRange(location: sourceLength, length: n)); sourceLength += n; i += n; continue
                }
            }
            out.append(c)
            let u = String(c).utf16.count
            outLength += u; sourceLength += u; i += 1
        }
        return (out, runs, sourceRuns, marks)
    }

    /// The title page at the top of `source` and the script after it.
    static func splitTitlePage(_ source: String) -> (titlePage: String, body: String) {
        guard let last = parse(source).last(where: { $0.element == .titlePage }) else { return ("", source) }
        let ns = source as NSString
        var end = NSMaxRange(last.range)
        while end < ns.length, let u = Unicode.Scalar(ns.character(at: end)), CharacterSet.newlines.contains(u) { end += 1 }
        return (ns.substring(to: NSMaxRange(last.range)), ns.substring(from: end))
    }

    static func joinTitlePage(_ fields: [TitleField], _ body: String) -> String {
        let title = titlePageText(fields)
        return title.isEmpty ? body : title + "\n\n" + body
    }

    static func titleFields(_ titlePage: String) -> [TitleField] {
        var fields: [TitleField] = []
        for line in titlePage.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let colon = t.firstIndex(of: ":"), !(line.first?.isWhitespace ?? false) {
                fields.append(TitleField(key: String(t[..<colon]), value: t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            } else if !fields.isEmpty, !t.isEmpty {
                let last = fields.count - 1
                fields[last].value += fields[last].value.isEmpty ? t : "\n" + t
            }
        }
        return fields
    }

    /// Fountain text for the fields; empty values are left out, multi-line ones are indented below their key.
    static func titlePageText(_ fields: [TitleField]) -> String {
        fields.compactMap { f in
            let lines = f.value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.isEmpty { return nil }
            return lines.count == 1 ? "\(f.key): \(lines[0])" : "\(f.key):\n" + lines.map { "    " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// `activeLocation` is the insertion point while editing: its line counts as written even when still
    /// empty, so a name typed in capitals is laid out as a character as soon as Return starts its dialogue.
    static func parse(_ source: String, activeLocation: Int? = nil, titlePage: Bool = true) -> [Line] {
        var raw: [(text: String, range: NSRange)] = []
        let ns = source as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { s, range, _, _ in
            raw.append((s ?? "", range))
        }
        if ns.length > 0, CharacterSet.newlines.contains(Unicode.Scalar(ns.character(at: ns.length - 1)) ?? " ") {
            raw.append(("", NSRange(location: ns.length, length: 0)))   // the empty line after a final line break
        }
        let active = activeLocation.flatMap { loc in
            raw.firstIndex { $0.range.location <= loc && loc <= NSMaxRange($0.range) }
        }
        func blank(_ i: Int) -> Bool { i >= raw.count || (i != active && raw[i].text.allSatisfy(\.isWhitespace)) }

        var lines: [Line] = []
        var i = 0
        // Title page: "Key: value" lines at the very top, up to the first blank line.
        if titlePage, let first = raw.first?.text, first.range(of: #"^[A-Z][A-Za-z ]*:"#, options: .regularExpression) != nil,
           first != first.uppercased() {
            while !blank(i) {
                lines.append(Line(element: .titlePage, text: raw[i].text, range: raw[i].range))
                i += 1
            }
        }

        var inBoneyard = false
        while i < raw.count {
            defer { i += 1 }
            var t = raw[i].text.trimmingCharacters(in: .whitespaces)
            func add(_ e: Element, _ text: String? = nil, number: String? = nil) {
                let printed = text ?? t
                if e == .note {
                    lines.append(Line(element: e, text: printed, range: raw[i].range))
                } else {
                    let styled = emphasis(printed)
                    lines.append(Line(element: e, text: styled.text, range: raw[i].range, sceneNumber: number, runs: styled.runs))
                }
            }
            if inBoneyard || t.hasPrefix("/*") {
                inBoneyard = !t.contains("*/")
                add(.note); continue
            }
            if t.contains("[[") {
                let stripped = t.replacingOccurrences(of: #"\[\[.*?\]\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { add(.note); continue }
                t = stripped
            }
            let previous = lines.last?.element ?? .empty
            let afterBlank = previous == .empty
            let beforeBlank = blank(i + 1)

            if t.isEmpty, !(i == active && [.character, .parenthetical].contains(previous)) { add(.empty); continue }
            if t.count >= 3, t.allSatisfy({ $0 == "=" }) { add(.pageBreak); continue }
            if t.hasPrefix("#") { add(.section); continue }
            if t.hasPrefix("=") { add(.synopsis); continue }
            if t.hasPrefix("!") { add(.action, String(t.dropFirst())); continue }
            if t.hasPrefix("~") { add(.action, String(t.dropFirst())); continue }
            if t.hasPrefix(">"), t.hasSuffix("<") {
                add(.centered, String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)); continue
            }
            if t.hasPrefix(">") { add(.transition, String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); continue }
            if !afterBlank, [.character, .dialogue, .parenthetical].contains(previous) {
                add(t.hasPrefix("(") ? .parenthetical : .dialogue); continue
            }
            if afterBlank {
                if (t.hasPrefix(".") && !t.hasPrefix("..")) || isHeading(t) {
                    var heading = t.hasPrefix(".") ? String(t.dropFirst()) : t
                    var number: String?
                    if let r = heading.range(of: #"\s*#[^#]+#$"#, options: .regularExpression) {
                        number = heading[r].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                        heading.removeSubrange(r)
                    }
                    add(.sceneHeading, heading, number: number); continue
                }
                if beforeBlank, isTransition(t) { add(.transition); continue }
                if !beforeBlank, t.hasPrefix("@") || (isUppercase(t) && !t.hasSuffix(":")) {
                    var cue = t.hasPrefix("@") ? String(t.dropFirst()) : t
                    if cue.hasSuffix("^") { cue.removeLast() }   // dual dialogue mark, printed as normal dialogue
                    add(.character, cue.trimmingCharacters(in: .whitespaces)); continue
                }
            }
            add(.action)
        }
        return lines
    }

    static func scene(_ line: Line, id: Int, lines: Range<Int>) -> ScriptScene {
        let heading = line.text.replacingOccurrences(of: " – ", with: " - ")
        var setting = "", rest = heading
        if let r = heading.range(of: headingPattern, options: [.regularExpression, .caseInsensitive]) {
            setting = heading[r].trimmingCharacters(in: .whitespaces).uppercased()
            if !setting.hasSuffix(".") { setting += "." }
            rest = String(heading[r.upperBound...])
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).uppercased()
        let separators = CharacterSet(charactersIn: " -–/.,")
        var time = "", location = rest
        if let word = timesOfDay.first(where: { rest == $0 || rest.hasPrefix($0 + " ") || rest.hasPrefix($0 + "-") || rest.hasPrefix($0 + "/") }) {
            // Italian order: EST. NOTTE PARCHEGGIO, EST. NOTTE - PARCHEGGIO
            time = word
            location = String(rest.dropFirst(word.count)).trimmingCharacters(in: separators)
        } else if let r = rest.range(of: " - ", options: .backwards),
                  timesOfDay.contains(where: { rest[r.upperBound...].hasPrefix($0) }) {
            // EXT. PARKING LOT - NIGHT; but GRAFICA ANIMATA - MAPPA is all location
            time = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            location = String(rest[..<r.lowerBound])
        } else if let word = timesOfDay.first(where: { rest.hasSuffix(" " + $0) }) {
            // EST. PARCHEGGIO NOTTE
            time = word
            location = String(rest.dropLast(word.count)).trimmingCharacters(in: separators)
        }
        return ScriptScene(id: id, number: line.sceneNumber ?? "\(id + 1)", heading: heading, setting: setting,
                           location: location, time: time, offset: line.range.location, lines: lines)
    }

    /// Renames a character in its cues and, with `everywhere`, as a whole word in the rest of the script.
    /// Capitalized occurrences stay capitalized (MARCO → LUCA, Marco → Luca).
    static func renaming(_ old: String, to new: String, in source: String, everywhere: Bool) -> String {
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: old) + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return source }
        let upper = new.uppercased()
        let prose = new == upper ? new.capitalized : new
        let ns = source as NSString
        let result = NSMutableString(string: source)
        for line in parse(source).reversed() {
            let isCue = line.element == .character
            if isCue ? characterName(line.text) != old.uppercased() : (!everywhere || line.element == .titlePage) { continue }
            let matches = regex.matches(in: source, range: line.range)
            for m in (isCue ? Array(matches.prefix(1)) : matches).reversed() {
                let found = ns.substring(with: m.range)
                let shouted = found == found.uppercased() && found != found.lowercased()
                result.replaceCharacters(in: m.range, with: isCue || shouted ? upper : prose)
            }
        }
        return result as String
    }
}
