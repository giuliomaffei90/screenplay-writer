import AppKit
import SwiftUI

/// Styles that reproduce the printed page: Courier 12 on a 12-point line, same indents and widths,
/// black on the always-white sheet.
enum Style {
    static let font = NSFont(name: "Courier", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    static let lineHeight: CGFloat = 12
    static let elementKey = NSAttributedString.Key("ScreenplayElement")
    /// Characters laid out with no glyph: Fountain marks the sheet doesn't show.
    nonisolated static let hiddenKey = NSAttributedString.Key("ScreenplayHidden")

    static func font(_ style: Emphasis) -> NSFont {
        let name = switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): "Courier-BoldOblique"
        case (true, false): "Courier-Bold"
        case (false, true): "Courier-Oblique"
        case (false, false): "Courier"
        }
        return NSFont(name: name, size: 12) ?? font
    }

    static let attributes: [Element: [NSAttributedString.Key: Any]] = {
        var all: [Element: [NSAttributedString.Key: Any]] = [:]
        for e in [Element.titlePage, .sceneHeading, .action, .character, .parenthetical, .dialogue, .transition,
                  .centered, .pageBreak, .section, .synopsis, .note, .empty] {
            let f = Layout.format(e)
            let p = NSMutableParagraphStyle()
            p.firstLineHeadIndent = CGFloat(f.indent) * charWidth
            p.headIndent = p.firstLineHeadIndent
            p.tailIndent = CGFloat(f.indent + f.width) * charWidth
            p.alignment = switch f.align { case .left: .left; case .center: .center; case .right: .right }
            p.minimumLineHeight = lineHeight
            p.maximumLineHeight = lineHeight
            if e == .sceneHeading { p.paragraphSpacingBefore = lineHeight }   // the PDF leaves two blank lines
            let muted: Set<Element> = [.titlePage, .pageBreak, .section, .synopsis, .note]
            all[e] = [.font: font, .paragraphStyle: p, elementKey: e.rawValue,
                      .foregroundColor: muted.contains(e) ? NSColor.gray : NSColor.black]
        }
        return all
    }()

    /// Applies the styles of `lines` where they changed; returns the element of the line at `active`.
    @discardableResult
    static func restyle(_ storage: NSTextStorage, lines: [Line], active: Int?, boldHeadings: Bool) -> Element? {
        let length = storage.length
        let ns = storage.string as NSString
        storage.beginEditing()
        for line in lines {
            let range = NSRange(location: line.range.location, length: min(line.range.length + 1, length - line.range.location))
            guard range.length > 0 else { continue }
            // Emphasis, and the line being written, are redone each time; other lines only when their element changes.
            let raw = ns.substring(with: line.range)
            let emphasized = line.element != .note && (raw.contains("*") || raw.contains("_"))
            let isActive = active.map { NSLocationInRange($0, range) || $0 == NSMaxRange(line.range) } ?? false
            var effective = NSRange()
            let current = storage.attribute(elementKey, at: range.location, longestEffectiveRange: &effective, in: range) as? String
            if !emphasized, !isActive, current == line.element.rawValue, effective == range { continue }
            storage.setAttributes(attributes[line.element], range: range)
            if boldHeadings, line.element == .sceneHeading { storage.addAttribute(.font, value: font(.bold), range: range) }
            for mark in Fountain.typeMarks(raw, line.element) {
                storage.addAttribute(hiddenKey, value: true, range: NSRange(location: line.range.location + mark.location, length: mark.length))
            }
            guard emphasized else { continue }
            // Marks stay visible in grey; the text between them takes the style.
            let e = Fountain.emphasis(raw)
            for run in e.sourceRuns {
                let r = NSRange(location: line.range.location + run.range.location, length: run.range.length)
                // Nested marks, like _**this**_, add up.
                let style = e.sourceRuns.filter { NSIntersectionRange($0.range, run.range) == run.range }.reduce(Emphasis()) { $0.union($1.style) }
                storage.addAttribute(.font, value: font(style.subtracting(.underline)), range: r)
                if run.style.contains(.underline) { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r) }
            }
            // Emphasis marks show, in grey, only on the line being written, so they can still be edited.
            for mark in e.marks {
                let r = NSRange(location: line.range.location + mark.location, length: mark.length)
                if isActive { storage.addAttribute(.foregroundColor, value: NSColor.lightGray, range: r) } else { storage.addAttribute(hiddenKey, value: true, range: r) }
            }
        }
        storage.endEditing()
        guard let active else { return nil }
        return lines.last { $0.range.location <= active }?.element
    }
}

/// Lets the window and its menus reach the text.
@Observable
final class EditorController {
    @ObservationIgnored weak var pages: PagesView?
    /// The element of the line being written, shown by the toolbar's element buttons.
    var current: Element?

    var textView: NSTextView? { pages?.activeTextView }

    func reveal(_ offset: Int) {
        DispatchQueue.main.async { [weak self] in self?.pages?.reveal(offset) }
    }

    /// Replaces the whole script through the text view, so Undo works as for typing.
    func replaceAll(with text: String, actionName: String) {
        guard let tv = textView else { return }
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        let selection = tv.selectedRange()
        guard tv.shouldChangeText(in: all, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: all, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        tv.undoManager?.setActionName(actionName)
    }

    /// Wraps the selection in Fountain emphasis marks (`**` bold, `*` italic, `_` underline), or unwraps it.
    func emphasize(_ mark: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString, sel = tv.selectedRange(), m = (mark as NSString).length
        let inner = ns.substring(with: sel)
        let wrapped = sel.location >= m && NSMaxRange(sel) + m <= ns.length
            && ns.substring(with: NSRange(location: sel.location - m, length: m)) == mark
            && ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == mark
        let range = wrapped ? NSRange(location: sel.location - m, length: sel.length + 2 * m) : sel
        let text = wrapped ? inner : mark + inner + mark
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: text)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: wrapped ? range.location : sel.location + m, length: sel.length))
    }

    /// Turns the line with the insertion point into the given element, adding the Fountain marks it needs.
    func format(_ e: Element) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var range = ns.lineRange(for: NSRange(location: tv.selectedRange().location, length: 0))
        if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        var t = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        if let f = t.first, "@>!~".contains(f) || (f == "." && !t.hasPrefix("..")) { t.removeFirst() }
        if t.hasSuffix("<") { t.removeLast() }
        if e != .parenthetical, t.hasPrefix("("), t.hasSuffix(")") { t = String(t.dropFirst().dropLast()) }
        switch e {
        case .sceneHeading:
            t = t.uppercased()
            if let r = t.range(of: Fountain.headingPattern, options: [.regularExpression, .caseInsensitive]) {
                // Again on a heading: INT. → EXT. → INT./EXT. → INT.
                let current = t[r]
                let next = current.contains("/") ? "INT." : current.hasPrefix("I") ? String(localized: "EXT.") : String(localized: "INT./EXT.")
                t = next + " " + t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            } else {
                t = "INT. " + t
            }
        case .character: t = t.uppercased()
        case .transition: t = t.uppercased(); if !Fountain.isTransition(t) { t = ">" + t }
        case .parenthetical: if !t.hasPrefix("(") { t = "(" + t + ")" }
        default: if Fountain.isHeading(t) || Fountain.isUppercase(t) { t = "!" + t }
        }
        var cursor = (t as NSString).length - (e == .parenthetical ? 1 : 0)
        if e == .character {
            // Like Final Draft, go on to the dialogue: a new line under the name, keeping a blank line before what follows.
            let after = NSMaxRange(range) + 1
            let nextLine = after <= ns.length ? ns.substring(with: ns.lineRange(for: NSRange(location: min(after, ns.length), length: 0))) : ""
            if after > ns.length || nextLine.allSatisfy(\.isWhitespace) { t += "\n"; cursor += 1 }
        }
        if e != .parenthetical, range.location > 0 {
            let before = ns.lineRange(for: NSRange(location: range.location - 1, length: 0))
            if !ns.substring(with: before).allSatisfy(\.isWhitespace) { t = "\n" + t; cursor += 1 }
        }
        guard tv.shouldChangeText(in: range, replacementString: t) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: t)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + cursor, length: 0))
        tv.undoManager?.setActionName(String(localized: e.title))
    }
}

/// One sheet's text area. It refuses lines from `breakAt` on, so the rest flows to the next sheet
/// exactly where the PDF starts a new page.
nonisolated final class PageContainer: NSTextContainer {
    var breakAt = Int.max
    /// Room left at the top for a "NAME (CONT'D)" line the layout adds.
    var topOffset: CGFloat = 0
    override var isSimpleRectangularTextContainer: Bool { false }
    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        if characterIndex >= breakAt { return .zero }
        var proposed = proposedRect
        if proposed.minY < topOffset { proposed.origin.y = topOffset }
        return super.lineFragmentRect(forProposedRect: proposed, at: characterIndex,
                                      writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

/// A white sheet of paper, also in Dark Mode, with its page number and the lines the layout adds:
/// (MORE) at the bottom, "NAME (CONT'D)" at the top, and (CONT'D) after a cue.
class SheetView: NSView {
    var number = 0 { didSet { if number != oldValue { needsDisplay = true } } }
    var paper = Paper.a4

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)   // light selection, cursor and spelling marks on the white sheet
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// The printed title page, built from the project settings; clicking it opens them.
final class TitleSheetView: SheetView {
    var rows: [PlacedLine] = [] { didSet { if rows != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) { for r in rows { Layout.draw(r.line, row: r.row, paper: paper) } }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class PageView: SheetView {
    let textView: NSTextView
    var container: PageContainer { textView.textContainer as! PageContainer }
    var more = false
    var continued: String?
    var suffixes: [SheetLayout.Suffix] = []
    static let added = NSColor(white: 0.4, alpha: 1)

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        addSubview(textView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Layout.drawPageNumber(number, paper: paper)
        guard let lm = textView.layoutManager else { return }
        let glyphs = lm.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        let origin = textView.frame.origin, cueX = origin.x + 22 * Style.charWidth
        func drawAdded(_ text: String, x: CGFloat, lineTop: CGFloat) {
            Layout.attributed(text, color: Self.added).draw(at: NSPoint(x: x, y: origin.y + lineTop))
        }
        if let continued { drawAdded(continued, x: cueX, lineTop: 0) }
        if more {
            drawAdded(String(localized: "(MORE)"), x: cueX, lineTop: lm.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY)
        }
        let text = textView.string as NSString
        for suffix in suffixes where suffix.location < text.length {
            var end = NSMaxRange(text.lineRange(for: NSRange(location: suffix.location, length: 0)))
            while end > suffix.location, let u = Unicode.Scalar(text.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { end -= 1 }
            let last = lm.glyphIndexForCharacter(at: max(suffix.location, end - 1))
            guard NSLocationInRange(last, glyphs) else { continue }
            let line = lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            drawAdded(suffix.text, x: origin.x + line.minX + lm.location(forGlyphAt: last).x + Style.charWidth, lineTop: line.minY)
        }
    }
}

/// The sheets, stacked down the scroll view; all their text views share one layout manager,
/// so text, selection and undo flow from sheet to sheet.
final class PagesView: NSView, NSLayoutManagerDelegate {
    let layoutManager: NSLayoutManager
    weak var textDelegate: NSTextViewDelegate?
    private(set) var pages: [PageView] = []
    private var sheets = SheetLayout()
    let titleSheet = TitleSheetView()
    var titleRows: [PlacedLine] = [] {
        didSet {
            titleSheet.rows = titleRows
            if titleRows.isEmpty != oldValue.isEmpty { layoutPages() }
        }
    }
    var paper: Paper { didSet { if paper != oldValue { rebuild() } } }
    var margins = PageMargins.current { didSet { if margins != oldValue { rebuild() } } }
    static let gap: CGFloat = 24

    init(layoutManager: NSLayoutManager, paper: Paper, textDelegate: NSTextViewDelegate) {
        self.layoutManager = layoutManager
        self.paper = paper
        self.textDelegate = textDelegate
        super.init(frame: .zero)
        layoutManager.delegate = self
        addSubview(titleSheet)
        addPage()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    var activeTextView: NSTextView? {
        if let tv = window?.firstResponder as? NSTextView, pages.contains(where: { $0.textView === tv }) { return tv }
        return pages.first?.textView
    }

    private func addPage() {
        let size = NSSize(width: 60 * Style.charWidth, height: CGFloat(paper.linesPerPage + 4) * Style.lineHeight)
        let container = PageContainer(size: size)   // 4 spare lines in the bottom margin for small differences
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(origin: NSPoint(x: paper.leftMargin, y: paper.topMargin), size: size), textContainer: container)
        tv.delegate = textDelegate
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.focusRingType = .none
        tv.typingAttributes = Style.attributes[.action]!
        pages.append(PageView(textView: tv))
        addSubview(pages[pages.count - 1])
        layoutPages()
    }

    private func removeLastPage() {
        let wasActive = window?.firstResponder === pages.last?.textView
        layoutManager.removeTextContainer(at: pages.count - 1)
        pages.removeLast().removeFromSuperview()
        layoutPages()
        if wasActive { window?.makeFirstResponder(pages.last?.textView) }
    }

    private func rebuild() {
        let selection = activeTextView?.selectedRange()
        while pages.count > 1 { removeLastPage() }
        layoutManager.removeTextContainer(at: 0)
        pages.removeLast().removeFromSuperview()
        addPage()
        update(sheets)
        if let selection { pages[0].textView.setSelectedRange(selection) }
    }

    private func layoutPages() {
        let size = paper.size
        let sheets: [SheetView] = (titleRows.isEmpty ? [] : [titleSheet]) + pages
        titleSheet.isHidden = titleRows.isEmpty
        for (i, sheet) in sheets.enumerated() {
            sheet.paper = paper
            sheet.needsDisplay = true
            sheet.frame = NSRect(x: Self.gap, y: Self.gap + CGFloat(i) * (size.height + Self.gap), width: size.width, height: size.height)
        }
        setFrameSize(NSSize(width: size.width + 2 * Self.gap, height: Self.gap + CGFloat(sheets.count) * (size.height + Self.gap)))
        for (i, page) in pages.enumerated() { page.number = i + 1 }
    }

    func update(_ sheets: SheetLayout) {
        self.sheets = sheets
        let breaks = sheets.breaks
        while pages.count < breaks.count + 1 { addPage() }
        var firstChanged: NSTextContainer?
        for (i, page) in pages.enumerated() {
            let b = i < breaks.count ? breaks[i] : .max
            let offset: CGFloat = i < sheets.continued.count && sheets.continued[i] != nil ? Style.lineHeight : 0
            if page.container.breakAt != b || page.container.topOffset != offset {
                page.container.breakAt = b
                page.container.topOffset = offset
                if firstChanged == nil { firstChanged = page.container }
            }
            page.more = i < sheets.more.count && sheets.more[i]
            page.continued = i < sheets.continued.count ? sheets.continued[i] : nil
            page.suffixes = i < sheets.suffixes.count ? sheets.suffixes[i] : []
            page.needsDisplay = true
        }
        // ponytail: lays the text out again from the first moved break; debounce if very long scripts lag.
        if let firstChanged { layoutManager.textContainerChangedGeometry(firstChanged) }
    }

    /// Hidden marks get no glyph, so they take no room and the line lays out as printed.
    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                   properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                                   characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                                   forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage, glyphRange.length > 0 else { return 0 }
        let chars = NSRange(location: charIndexes[0], length: charIndexes[glyphRange.length - 1] - charIndexes[0] + 1)
        var any = false
        storage.enumerateAttribute(Style.hiddenKey, in: chars) { value, _, stop in if value != nil { any = true; stop.pointee = true } }
        guard any else { return 0 }
        let hidden = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { hidden.deallocate() }
        for i in 0..<glyphRange.length {
            hidden[i] = storage.attribute(Style.hiddenKey, at: charIndexes[i], effectiveRange: nil) != nil ? .null : props[i]
        }
        layoutManager.setGlyphs(glyphs, properties: hidden, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        // Text left over after the last sheet needs one more; sheets left empty at the end go.
        DispatchQueue.main.async { [weak self] in self?.fitPages() }
    }

    private func fitPages() {
        guard let last = pages.last else { return }
        let total = layoutManager.numberOfGlyphs
        if NSMaxRange(layoutManager.glyphRange(for: last.container)) < total { addPage(); return }
        while pages.count > max(1, sheets.breaks.count + 1), layoutManager.glyphRange(for: pages[pages.count - 1].container).length == 0 {
            removeLastPage()
        }
    }

    func reveal(_ offset: Int) {
        let length = layoutManager.textStorage?.length ?? 0
        let location = min(offset, length)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, location + 1)))
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil),
              let page = pages.first(where: { $0.container === container }) else { return }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        window?.makeFirstResponder(page.textView)
        page.textView.setSelectedRange(NSRange(location: location, length: 0))
        let y = page.textView.convert(line.origin, to: self).y
        scroll(NSPoint(x: visibleRect.minX, y: max(0, y - 72)))
    }
}

/// Keeps the sheets centred when the window is wider than them.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView, r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        return r
    }
}

struct PagedEditor: NSViewRepresentable {
    @Binding var text: String
    let paper: Paper
    var margins: PageMargins
    var boldHeadings: Bool
    /// The title page sheet, drawn from the project settings; the text holds only the script.
    var titleRows: [PlacedLine]
    var onTitleClick: () -> Void
    let controller: EditorController
    var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, paper: paper, controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        c.storage.setAttributedString(NSAttributedString(string: text, attributes: Style.attributes[.action]))
        let pages = PagesView(layoutManager: c.layoutManager, paper: paper, textDelegate: c)
        c.pages = pages
        controller.pages = pages
        pages.titleRows = titleRows
        pages.titleSheet.onClick = onTitleClick

        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = pages
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 3
        scroll.backgroundColor = .underPageBackgroundColor
        c.refresh(publish: false)
        DispatchQueue.main.async { pages.window?.makeFirstResponder(pages.pages.first?.textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.text = $text
        controller.pages = c.pages
        c.pages?.titleRows = titleRows
        c.pages?.titleSheet.onClick = onTitleClick
        // Hidden while another view is showing, but kept alive so its undo history survives.
        scroll.isHidden = !isActive
        if c.boldHeadings != boldHeadings {
            c.boldHeadings = boldHeadings
            c.storage.removeAttribute(Style.elementKey, range: NSRange(location: 0, length: c.storage.length))   // restyle every line
            c.refresh(publish: false)
        }
        if c.pages?.margins != margins {
            c.pages?.margins = margins
            c.refresh(publish: false)
        }
        if c.paper != paper || c.storage.string != text {
            c.paper = paper
            c.pages?.paper = paper
            if c.storage.string != text { c.storage.replaceCharacters(in: NSRange(location: 0, length: c.storage.length), with: text) }
            c.refresh(publish: false)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var paper: Paper
        var boldHeadings = true
        let controller: EditorController
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        weak var pages: PagesView?
        private var lastRefresh: (length: Int, line: NSRange)?
        private var capitalizing = false

        init(text: Binding<String>, paper: Paper, controller: EditorController) {
            self.text = text
            self.paper = paper
            self.controller = controller
            storage.addLayoutManager(layoutManager)
        }

        /// Restyles the text, as written so far, and moves the sheet breaks to match the PDF.
        func refresh(publish: Bool) {
            guard let pages, let tv = pages.activeTextView else { return }
            let selection = tv.selectedRange()
            let active = selection.length == 0 ? selection.location : nil
            let script = Screenplay(storage.string, activeLocation: active, titlePage: false)
            let element = Style.restyle(storage, lines: script.lines, active: active, boldHeadings: boldHeadings)
            // Text typed next, and an empty last line, take the layout of the line being written.
            if let element { tv.typingAttributes = Style.attributes[element] ?? tv.typingAttributes }
            pages.update(Layout.sheets(script, paper: paper))
            lastRefresh = (storage.length, (storage.string as NSString).lineRange(for: NSRange(location: min(selection.location, storage.length), length: 0)))
            if publish, controller.current != element { controller.current = element }
        }

        /// Scene headings, character cues and transitions are written in capitals, whatever is typed.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
            guard !capitalizing, let s, s.contains(where: \.isLowercase), !s.contains(where: \.isNewline), !tv.hasMarkedText() else { return true }
            let ns = storage.string as NSString
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            var lineEnd = NSMaxRange(line)
            if lineEnd > line.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
            guard NSMaxRange(range) <= lineEnd else { return true }
            let before = ns.substring(with: NSRange(location: line.location, length: range.location - line.location))
            let after = ns.substring(with: NSRange(location: NSMaxRange(range), length: lineEnd - NSMaxRange(range)))
            let typed = (before + s + after).trimmingCharacters(in: .whitespaces)
            let afterBlank = line.location == 0
                || ns.substring(with: ns.lineRange(for: NSRange(location: line.location - 1, length: 0))).allSatisfy(\.isWhitespace)
            let heading = afterBlank && (Fountain.isHeading(typed) || (typed.hasPrefix(".") && !typed.hasPrefix("..") && typed.count > 1))
            let transition = typed.hasPrefix(">") && !typed.hasSuffix("<")
            guard heading || transition || controller.current == .character || controller.current == .transition else { return true }
            // A heading also gets what was typed before it became one: "int." turns into "INT.".
            let fixBefore = heading && before.contains(where: \.isLowercase)
            capitalizing = true
            tv.insertText(fixBefore ? (before + s).uppercased() : s.uppercased(),
                          replacementRange: fixBefore ? NSRange(location: line.location, length: NSMaxRange(range) - line.location) : range)
            capitalizing = false
            return false
        }

        func textDidChange(_ notification: Notification) {
            text.wrappedValue = storage.string
            refresh(publish: true)
        }

        /// Leaving a line can change its layout (a name with no dialogue under it is action again).
        func textViewDidChangeSelection(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.pages?.activeTextView else { return }
                let line = (self.storage.string as NSString).lineRange(for: NSRange(location: min(tv.selectedRange().location, self.storage.length), length: 0))
                if let last = self.lastRefresh, last.length == self.storage.length, last.line == line { return }
                self.refresh(publish: true)
            }
        }
    }
}
