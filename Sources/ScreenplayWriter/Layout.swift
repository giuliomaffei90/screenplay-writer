import AppKit

/// Standard screenplay page: Courier 12 (10 characters per inch, 6 lines per inch),
/// 1.5" left margin, 1" top and bottom, page numbers top right from page 2.
nonisolated enum Paper: String, CaseIterable, Identifiable {
    case a4, a3, letter, legal
    var id: Self { self }
    var size: CGSize {
        switch self {
        case .a4: CGSize(width: 595, height: 842)
        case .a3: CGSize(width: 842, height: 1191)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        }
    }
    var linesPerPage: Int {
        let m = PageMargins.current
        return max(10, Int((size.height - m.top - m.bottom) / 12))
    }
    /// Where the 6-inch text column starts: centred on the page, or at the left margin from Settings.
    var leftMargin: Double {
        let m = PageMargins.current, free = size.width - 432
        return m.centered ? free / 2 : min(max(0, m.left), free)
    }
    var topMargin: Double { PageMargins.current.top }
    static var standard: Paper { Locale.current.measurementSystem == .us ? .letter : .a4 }

    var title: LocalizedStringResource {
        switch self {
        case .a4: "A4"
        case .a3: "A3"
        case .letter: "US Letter"
        case .legal: "US Legal"
        }
    }

    /// The value of the "Paper:" title page key that stores it in the script.
    var token: String { self == .a4 || self == .a3 ? rawValue.uppercased() : rawValue.capitalized }
}

/// The margins from Settings, in points. The text column itself is always 6 inches (60 characters),
/// as the screenplay format wants; the margins place it on the page and set how many lines fit.
nonisolated struct PageMargins: Equatable {
    var centered = true
    var left = 108.0, top = 72.0, bottom = 72.0
    /// 1.5" left, 1" top and bottom.
    static let standard = PageMargins(centered: false)

    static var current: PageMargins {
        let d = UserDefaults.standard
        return PageMargins(centered: d.object(forKey: "marginsCentered") as? Bool ?? true,
                           left: d.object(forKey: "marginLeft") as? Double ?? 108,
                           top: max(18, d.object(forKey: "marginTop") as? Double ?? 72),
                           bottom: max(18, d.object(forKey: "marginBottom") as? Double ?? 72))
    }
}

@MainActor extension Paper {
    static func of(_ fields: [TitleField]) -> Paper? {
        fields.last { $0.key.lowercased() == "paper" }.flatMap { Paper(rawValue: $0.value.lowercased()) }
    }

    static func of(_ lines: [Line]) -> Paper? {
        of(Fountain.titleFields(lines.filter { $0.element == .titlePage }.map(\.text).joined(separator: "\n")))
    }

    /// The script with its "Paper:" title page key set to this size.
    func setting(in text: String) -> String {
        let split = Fountain.splitTitlePage(text)
        var fields = Fountain.titleFields(split.titlePage)
        if let i = fields.firstIndex(where: { $0.key.lowercased() == "paper" }) {
            fields[i].value = token
        } else {
            fields.append(TitleField(key: "Paper", value: token))
        }
        return Fountain.joinTitlePage(fields, split.body)
    }
}

enum Align { case left, center, right }

/// One printed line; indent and width are in characters from the left margin.
struct PrintLine: Equatable {
    var text = ""
    var indent = 0
    var width = 60
    var align = Align.left
    var sceneNumber: String?
    /// UTF-16 offset in the source where this line starts; nil for lines the layout adds, like (MORE).
    var source: Int?
    var runs: [StyledRun] = []
    var isHeading = false
    /// Text the layout appends to a character cue, like " (CONT'D)"; already part of `text`.
    var suffix: String?
}

/// A line of the title page, at its row on the sheet.
struct PlacedLine: Equatable {
    var row: Int
    var line: PrintLine
}

struct Block {
    var element: Element
    var lines: [PrintLine]
    var space: Int          // blank lines before it
    var name = ""           // speaking character, for (CONT'D)
}

/// What the editor's sheets need to look like the PDF pages.
struct SheetLayout: Equatable {
    struct Suffix: Equatable { var location: Int; var text: String }
    /// Source offset where each sheet after the first starts.
    var breaks: [Int] = []
    /// Per sheet: ends with (MORE); starts with "NAME (CONT'D)"; cues that get " (CONT'D)" added.
    var more: [Bool] = [false]
    var continued: [String?] = [nil]
    var suffixes: [[Suffix]] = [[]]
}

enum Layout {
    static func format(_ e: Element) -> (indent: Int, width: Int, align: Align) {
        switch e {
        case .character: (22, 38, .left)
        case .dialogue: (10, 35, .left)
        case .parenthetical: (16, 23, .left)
        case .transition: (0, 60, .right)
        case .centered: (0, 60, .center)
        default: (0, 60, .left)
        }
    }

    static func wrap(_ text: String, _ width: Int) -> [String] { wrapWithOffsets(text, width).map(\.text) }

    /// Word wrap; each line comes with the UTF-16 offset in `text` where it starts.
    static func wrapWithOffsets(_ text: String, _ width: Int) -> [(text: String, offset: Int)] {
        var out: [(String, Int)] = [], line = "", start = 0
        for word in text.split(separator: " ") {
            var w = String(word), at = text.utf16.distance(from: text.startIndex, to: word.startIndex)
            while w.count > width {
                if !line.isEmpty { out.append((line, start)); line = "" }
                let head = String(w.prefix(width))
                out.append((head, at)); at += head.utf16.count; w = String(w.dropFirst(width))
            }
            if line.isEmpty { line = w; start = at } else if line.count + 1 + w.count <= width { line += " " + w } else { out.append((line, start)); line = w; start = at }
        }
        if !line.isEmpty || out.isEmpty { out.append((line, start)) }
        return out
    }

    static func printed(_ text: String, _ e: Element, from line: Line) -> [PrintLine] {
        let f = format(e)
        // ponytail: offsets after the first wrapped line assume removed marks were at the start of the line.
        let base = line.range.location + max(0, line.range.length - text.utf16.count)
        return wrapWithOffsets(text, f.width).map { w in
            PrintLine(text: w.text, indent: f.indent, width: f.width, align: f.align,
                      source: w.offset == 0 ? line.range.location : base + w.offset,
                      runs: slice(line.runs, offset: w.offset, length: w.text.utf16.count))
        }
    }

    /// The part of `runs` inside one wrapped line, relative to its start.
    static func slice(_ runs: [StyledRun], offset: Int, length: Int) -> [StyledRun] {
        runs.compactMap { run in
            let r = NSIntersectionRange(run.range, NSRange(location: offset, length: length))
            return r.length > 0 ? StyledRun(range: NSRange(location: r.location - offset, length: r.length), style: run.style) : nil
        }
    }

    static func blocks(_ lines: some Collection<Line>) -> [Block] {
        let contd = String(localized: "(CONT'D)")
        var out: [Block] = []
        var previous = Element.empty
        var lastSpeaker: String?   // in this scene, with no one else speaking since
        for line in lines {
            defer { previous = line.element }
            let e = line.element
            switch e {
            case .sceneHeading:
                var heading = printed(line.text.uppercased(), e, from: line)
                heading[0].sceneNumber = line.sceneNumber
                for i in heading.indices { heading[i].isHeading = true }
                out.append(Block(element: e, lines: heading, space: 2))
                lastSpeaker = nil
            case .action where previous == .action && out.last?.element == .action:
                out[out.count - 1].lines += printed(line.text, e, from: line)
            case .action, .centered, .transition:
                out.append(Block(element: e, lines: printed(e == .transition ? line.text.uppercased() : line.text, e, from: line), space: 1))
                if e == .transition { lastSpeaker = nil }
            case .character:
                // The same character speaking again after some action gets (CONT'D), as Final Draft does.
                let name = Fountain.characterName(line.text)
                var cue = line.text.uppercased(), suffix: String?
                if name == lastSpeaker, !cue.contains("CONT") { suffix = " " + contd; cue += suffix! }
                var printedCue = printed(cue, e, from: line)
                printedCue[0].suffix = suffix
                out.append(Block(element: e, lines: printedCue, space: 1, name: name))
                lastSpeaker = name
            case .dialogue, .parenthetical:
                if out.last?.element == .character {
                    out[out.count - 1].lines += printed(line.text, e, from: line)
                } else {
                    out.append(Block(element: .action, lines: printed(line.text, .action, from: line), space: 1))
                }
            case .pageBreak:
                out.append(Block(element: e, lines: [], space: 0))
            default: break
            }
        }
        return out
    }

    /// Splits blocks into pages: headings keep their first lines with them, action breaks between
    /// lines, dialogue breaks with (MORE) and repeats the name with (CONT'D).
    static func paginate(_ blocks: [Block], linesPerPage: Int) -> [[PrintLine]] {
        let more = String(localized: "(MORE)"), contd = String(localized: "(CONT'D)")
        var pages: [[PrintLine]] = [[]]
        var todo = Array(blocks.reversed())
        while var block = todo.popLast() {
            let used = pages[pages.count - 1].count
            if block.element == .pageBreak { if used > 0 { pages.append([]) }; continue }
            let space = used == 0 ? 0 : block.space
            var needed = space + block.lines.count
            if block.element == .sceneHeading, let next = todo.last, next.element != .sceneHeading, next.element != .pageBreak {
                needed += next.space + min(2, next.lines.count)
            }
            if used + needed <= linesPerPage {
                pages[pages.count - 1] += Array(repeating: PrintLine(), count: space) + block.lines
                continue
            }
            let room = linesPerPage - used - space
            var head: [PrintLine] = [], rest: [PrintLine] = []
            if block.element == .action, room >= 2, block.lines.count > room {
                head = Array(block.lines[..<room]); rest = Array(block.lines[room...])
            } else if block.element == .character, room >= 3, block.lines.count >= room {
                let k = room - 1
                head = Array(block.lines[..<k]) + [PrintLine(text: more, indent: 22, width: 38)]
                rest = [PrintLine(text: "\(block.name) \(contd)", indent: 22, width: 38)] + block.lines[k...]
            }
            if head.isEmpty {
                // ponytail: a block taller than a whole page that can't be split simply overflows it.
                if used == 0 { pages[pages.count - 1] += block.lines; continue }
                pages.append([]); todo.append(block); continue
            }
            pages[pages.count - 1] += Array(repeating: PrintLine(), count: space) + head
            block.lines = rest; block.space = 0
            todo.append(block)
            pages.append([])
        }
        if pages.count > 1, pages.last?.isEmpty == true { pages.removeLast() }
        return pages
    }

    static func pages(_ script: Screenplay, paper: Paper) -> [[PrintLine]] {
        paginate(blocks(script.lines), linesPerPage: paper.linesPerPage)
    }

    /// The PDF pages as the editor shows them: where each sheet starts, and the lines the layout adds.
    static func sheets(_ script: Screenplay, paper: Paper) -> SheetLayout {
        let all = pages(script, paper: paper)
        // A page made only of added lines can't be placed in the text; it stays with the page before.
        let pages = [all[0]] + all.dropFirst().filter { $0.contains { $0.source != nil } }
        var sheets = SheetLayout()
        sheets.breaks = pages.dropFirst().map { $0.first { $0.source != nil }!.source! }
        sheets.more = pages.map { $0.last.map { $0.source == nil && !$0.text.isEmpty } ?? false }
        sheets.continued = pages.map { $0.first.flatMap { $0.source == nil && !$0.text.isEmpty ? $0.text : nil } }
        sheets.suffixes = pages.map { $0.compactMap { l in l.suffix.map { SheetLayout.Suffix(location: l.source!, text: $0) } } }
        return sheets
    }

    /// Length of a scene in eighths of a page, the unit of a shooting schedule.
    static func eighths(_ scene: ScriptScene, in script: Screenplay, paper: Paper) -> Int {
        let count = blocks(script.lines[scene.lines]).enumerated().reduce(0) { sum, b in
            sum + (b.offset == 0 ? 0 : b.element.space) + b.element.lines.count
        }
        return max(1, Int((Double(count * 8) / Double(paper.linesPerPage)).rounded(.up)))
    }

    static func eighthsText(_ e: Int) -> String {
        switch (e / 8, e % 8) {
        case (let p, 0): "\(p)"
        case (0, let r): "\(r)/8"
        case (let p, let r): "\(p) \(r)/8"
        }
    }

    static func titlePage(_ lines: [Line], linesPerPage: Int) -> [PlacedLine] {
        titlePage(Fountain.titleFields(lines.filter { $0.element == .titlePage }.map(\.text).joined(separator: "\n")), linesPerPage: linesPerPage)
    }

    /// Title page rows: title, credit, author and source centred a third of the way down,
    /// contact and notes bottom left, draft date bottom right.
    static func titlePage(_ titleFields: [TitleField], linesPerPage: Int) -> [PlacedLine] {
        var fields: [String: [String]] = [:]
        for f in titleFields where !f.value.isEmpty {
            fields[f.key.lowercased(), default: []] += f.value.components(separatedBy: .newlines)
        }
        func styled(_ v: String, width: Int, align: Align) -> [PrintLine] {
            let e = Fountain.emphasis(v)
            return wrapWithOffsets(e.text, width).map {
                PrintLine(text: $0.text, width: width, align: align, runs: slice(e.runs, offset: $0.offset, length: $0.text.utf16.count))
            }
        }
        var out: [PlacedLine] = []
        var row = linesPerPage / 3
        for k in ["title", "credit", "author", "authors", "source"] {
            guard let values = fields[k], !values.isEmpty else { continue }
            for v in values {
                for l in styled(v, width: 60, align: .center) { out.append(PlacedLine(row: row, line: l)); row += 1 }
            }
            row += 1
        }
        let bottom = ["contact", "copyright", "notes"].flatMap { fields[$0] ?? [] }.flatMap { styled($0, width: 35, align: .left) }
        for (n, l) in bottom.enumerated() { out.append(PlacedLine(row: linesPerPage - bottom.count + n, line: l)) }
        if let date = fields["draft date"], !date.isEmpty {
            out.append(PlacedLine(row: linesPerPage - 1, line: PrintLine(text: date.joined(separator: " "), align: .right)))
        }
        return out
    }

    static let charWidth = 7.2, lineHeight = 12.0

    static func attributed(_ text: String, runs: [StyledRun] = [], color: NSColor = .black) -> NSAttributedString {
        // A 12-point line, as in the editor, so drawn and typed text share the baseline.
        let s = NSMutableAttributedString(string: text, attributes: [.font: Style.font, .foregroundColor: color,
                                                                      .paragraphStyle: Style.attributes[.action]![.paragraphStyle]!])
        for run in runs where NSMaxRange(run.range) <= s.length {
            s.addAttribute(.font, value: Style.font(run.style), range: run.range)
            if run.style.contains(.underline) { s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run.range) }
        }
        return s
    }

    /// Draws a printed line on a sheet in the current, flipped graphics context.
    static func draw(_ l: PrintLine, row: Int, paper: Paper, sceneNumbers: Bool = false, boldHeadings: Bool = false) {
        let margin = paper.leftMargin
        let pad = switch l.align {
        case .left: 0
        case .center: (l.width - l.text.count) / 2
        case .right: l.width - l.text.count
        }
        let y = paper.topMargin + Double(row) * lineHeight
        let runs = boldHeadings && l.isHeading ? l.runs + [StyledRun(range: NSRange(location: 0, length: l.text.utf16.count), style: .bold)] : l.runs
        attributed(l.text, runs: runs).draw(at: CGPoint(x: margin + Double(l.indent + max(0, pad)) * charWidth, y: y))
        if sceneNumbers, let n = l.sceneNumber {
            attributed(n).draw(at: CGPoint(x: margin - Double(n.count + 3) * charWidth, y: y))
            attributed(n).draw(at: CGPoint(x: margin + 62 * charWidth, y: y))
        }
    }

    static func drawPageNumber(_ n: Int, paper: Paper) {
        guard n >= 2 else { return }
        let s = "\(n)."
        attributed(s).draw(at: CGPoint(x: paper.leftMargin + Double(60 - s.count) * charWidth, y: paper.topMargin / 2))
    }

    static func pdf(_ script: Screenplay, paper: Paper, sceneNumbers: Bool, boldHeadings: Bool = false) -> Data {
        let size = paper.size
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        func page(_ body: () -> Void) {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            body()
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        let title = titlePage(script.lines, linesPerPage: paper.linesPerPage)
        if !title.isEmpty { page { for t in title { draw(t.line, row: t.row, paper: paper) } } }
        for (i, lines) in pages(script, paper: paper).enumerated() {
            page {
                drawPageNumber(i + 1, paper: paper)
                for (row, l) in lines.enumerated() { draw(l, row: row, paper: paper, sceneNumbers: sceneNumbers, boldHeadings: boldHeadings) }
            }
        }
        ctx.closePDF()
        return data as Data
    }
}
