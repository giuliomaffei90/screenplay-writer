import AppKit
import SwiftUI
import Testing
@testable import ScreenplayWriter

/// Builds the paged editor off screen; returns its sheets and the breaks they should follow.
func pagedEditor(_ source: String, paper: Paper) -> (PagesView, [Int]) {
    let c = PagedEditor.Coordinator(text: .constant(source), paper: paper, controller: EditorController())
    c.storage.setAttributedString(NSAttributedString(string: source))
    let pages = PagesView(layoutManager: c.layoutManager, paper: paper, textDelegate: c)
    c.pages = pages
    c.refresh(publish: false)
    pages.layoutManager.ensureLayout(for: pages.pages.last!.container)
    return (pages, Layout.sheets(Screenplay(source, titlePage: false), paper: paper).breaks)
}

@Test func sheetsStartWhereThePDFPagesStart() {
    let scene = "INT. CASA DI MARCO - NOTTE\n\nMarco entra e si guarda intorno, poi si siede sul divano senza dire una parola.\n\nMARCO\n(sottovoce)\nNessuno mi ha visto arrivare, e forse è meglio così.\n\n"
    let source = String(repeating: scene, count: 30)
    let (view, breaks) = pagedEditor(source, paper: .a4)
    #expect(breaks.count >= 4 && view.pages.count == breaks.count + 1)
    for (i, page) in view.pages.enumerated().dropFirst() {
        let glyphs = view.layoutManager.glyphRange(for: page.container)
        #expect(view.layoutManager.characterIndexForGlyph(at: glyphs.location) == breaks[i - 1])
    }
}

@Test func sheetsHideFountainMarks() {
    let source = "!SOVRIMPRESSIONE: MILANO, 1983\n\n>FINE ATTO PRIMO<\n\n@McCLANE\nCiao.\n\nIl caffè è **bollente**.\n\nFine."
    #expect(Fountain.typeMarks("!SUPER", .action) == [NSRange(location: 0, length: 1)])
    #expect(Fountain.typeMarks(" >FINE< ", .centered) == [NSRange(location: 1, length: 1), NSRange(location: 6, length: 1)])
    let (view, _) = pagedEditor(source, paper: .a4)   // the insertion point is at the start, on the first line
    let lm = view.layoutManager, ns = source as NSString
    func hidden(_ s: String, _ offset: Int = 0) -> Bool {
        lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: ns.range(of: s).location + offset)) == .null
    }
    #expect(hidden("!") && hidden(">") && hidden("<") && hidden("@") && hidden("**b") && !hidden("Fine"))
}
