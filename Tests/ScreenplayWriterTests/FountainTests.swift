import Foundation
import Testing
@testable import ScreenplayWriter

private let sample = """
Title: La prova
Author: Giulio

EST. PIAZZA DEL DUOMO - GIORNO

Marco attraversa la piazza.

MARCO (V.O.)
(sottovoce)
Ciao, Giulia.

GIULIA
Marco! Sei tornato.

STACCO A:

INT. CASA DI MARCO - CUCINA - NOTTE #7#

MARCO
Nessuno mi ha visto.

INT. CASA DI MARCO - NOTTE

GIULIA
Dormi?
"""

@Test func parsesElements() {
    let script = Screenplay(sample)
    let kinds = script.lines.filter { $0.element != .empty }.map(\.element)
    #expect(kinds == [.titlePage, .titlePage, .sceneHeading, .action, .character, .parenthetical, .dialogue,
                      .character, .dialogue, .transition, .sceneHeading, .character, .dialogue,
                      .sceneHeading, .character, .dialogue])
    #expect(script.scenes.map(\.number) == ["1", "7", "3"])
    #expect(script.scenes[0].setting == "EST." && script.scenes[0].location == "PIAZZA DEL DUOMO" && script.scenes[0].time == "GIORNO")
    #expect(script.scenes[1].mainLocation == "CASA DI MARCO" && script.scenes[1].location == "CASA DI MARCO - CUCINA")
    #expect(script.characters.map(\.name) == ["MARCO", "GIULIA"])
    #expect(script.characters[0].scenes == [0, 1] && script.characters[1].lines == 2)
}

@Test func renamesCharacter() {
    let renamed = Fountain.renaming("Marco", to: "Luca", in: sample, everywhere: true)
    #expect(renamed.contains("LUCA (V.O.)") && renamed.contains("Luca attraversa") && renamed.contains("CASA DI LUCA"))
    #expect(!renamed.contains("Marco") && !renamed.contains("MARCO"))
    let cuesOnly = Fountain.renaming("MARCO", to: "luca", in: sample, everywhere: false)
    #expect(cuesOnly.contains("LUCA (V.O.)") && cuesOnly.contains("Marco attraversa"))
}

@Test func splitsDialogueAcrossPages() {
    let speech = (1...30).map { "Battuta numero \($0) che occupa una riga." }.joined(separator: " ")
    let script = Screenplay("INT. STANZA - GIORNO\n\n" + String(repeating: "Azione.\n\n", count: 20) + "MARCO\n" + speech)
    let pages = Layout.paginate(Layout.blocks(script.lines), linesPerPage: 54)
    #expect(pages.count == 2)
    #expect(pages[0].count <= 54 && pages[0].last?.text == "(MORE)")
    #expect(pages[1].first?.text == "MARCO (CONT'D)")
    #expect(Layout.eighthsText(11) == "1 3/8" && Layout.eighthsText(3) == "3/8" && Layout.eighthsText(16) == "2")
    #expect(!Layout.pdf(script, paper: .a4, sceneNumbers: true).isEmpty)
}

@Test func laysOutTheLineBeingWritten() {
    let source = "Azione.\n\nMARCO\n"
    #expect(Fountain.parse(source).map(\.element) == [.action, .empty, .action, .empty])
    #expect(Fountain.parse(source, activeLocation: (source as NSString).length).map(\.element) == [.action, .empty, .character, .dialogue])
    #expect(Fountain.parse("\nFADE IN:\nTesto").map(\.element) == [.empty, .action, .action])
}

@Test func storesPaperInTheTitlePage() {
    let a3 = Paper.a3.setting(in: sample)
    #expect(a3.contains("Author: Giulio\nPaper: A3\n") && Paper.of(Screenplay(a3).lines) == .a3)
    let letter = Paper.letter.setting(in: a3)
    #expect(Paper.of(Screenplay(letter).lines) == .letter && !letter.contains("A3"))
    #expect(Paper.legal.setting(in: "INT. BAR - NOTTE\n").hasPrefix("Paper: Legal\n\nINT. BAR"))
    #expect(Layout.titlePage(Screenplay("Paper: A4\n\nINT. BAR - NOTTE").lines, linesPerPage: 58).isEmpty)
}

@Test func editorSheetsMatchThePDFPages() {
    let speech = (1...30).map { "Battuta numero \($0) che occupa una riga." }.joined(separator: " ")
    let source = "INT. STANZA - GIORNO\n\n" + String(repeating: "Azione.\n\n", count: 20) + "MARCO\n" + speech
    let script = Screenplay(source, titlePage: false)
    let pages = Layout.pages(script, paper: .letter)
    let sheets = Layout.sheets(script, paper: .letter)
    #expect(sheets.breaks.count == 1 && sheets.more == [true, false] && sheets.continued == [nil, "MARCO (CONT'D)"])
    #expect((source as NSString).substring(from: sheets.breaks[0]).hasPrefix(pages[1][1].text))
}

@Test func followsTheFormatRules() {
    // The same character speaking again after action in a scene gets (CONT'D); a new scene resets it.
    let script = Screenplay("INT. BAR - NOTTE\n\nALDO\nIl solito?\n\nAldo versa.\n\nALDO\nEcco.\n\nEXT. STRADA - CONTINUOUS\n\nALDO\nCiao.")
    let cues = Layout.blocks(script.lines).filter { $0.element == .character }.map { $0.lines[0] }
    #expect(cues.map(\.text) == ["ALDO", "ALDO (CONT'D)", "ALDO"] && cues[1].suffix == " (CONT'D)")
    #expect(script.scenes[1].time == "CONTINUOUS" && script.scenes[1].shootingTime == "NOTTE")

    let e = Fountain.emphasis("_**FINE ATTO PRIMO**_ e *poi*")
    #expect(e.text == "FINE ATTO PRIMO e poi")
    #expect(e.runs.contains(StyledRun(range: NSRange(location: 0, length: 15), style: .underline)))
    #expect(e.runs.contains(StyledRun(range: NSRange(location: 0, length: 15), style: .bold)))
    #expect(e.runs.contains(StyledRun(range: NSRange(location: 18, length: 3), style: .italic)))
    #expect(e.marks.count == 6 && Fountain.emphasis("2 * 3 = 6").text == "2 * 3 = 6")
}

@Test func titlePageLivesApartFromTheScript() {
    let split = Fountain.splitTitlePage(sample)
    #expect(split.body.hasPrefix("EST. PIAZZA") && !split.titlePage.hasSuffix("\n"))
    var fields = Fountain.titleFields(split.titlePage)
    #expect(fields == [TitleField(key: "Title", value: "La prova"), TitleField(key: "Author", value: "Giulio")])
    fields.append(TitleField(key: "Contact", value: "Via Roma 1\nMilano"))
    let joined = Fountain.joinTitlePage(fields, split.body)
    #expect(joined.contains("Contact:\n    Via Roma 1\n    Milano\n\nEST. PIAZZA"))
    #expect(Fountain.titleFields(Fountain.splitTitlePage(joined).titlePage) == fields)
}

@Test func readsTimeOfDayInEitherOrder() {
    let script = Screenplay("""
    EST. NOTTE PARCHEGGIO

    Pioggia.

    INT. NOTTE - CASA DI MARCO - CUCINA

    Buio.

    EXT. PARKING LOT - NIGHT

    Rain.

    INT. PRIMO MATTINO BAR

    Caffè.

    EST. PIAZZA GIORNO

    Sole.

    .GRAFICA ANIMATA - MAPPA DEL MONDO

    Luci.
    """)
    #expect(script.scenes.map(\.location) == ["PARCHEGGIO", "CASA DI MARCO - CUCINA", "PARKING LOT", "BAR", "PIAZZA", "GRAFICA ANIMATA - MAPPA DEL MONDO"])
    #expect(script.scenes.map(\.time) == ["NOTTE", "NOTTE", "NIGHT", "PRIMO MATTINO", "GIORNO", ""])
    #expect(script.scenes[1].mainLocation == "CASA DI MARCO")
}

@Test func keepsTheCastInTheTitlePage() {
    let members = [CastMember(name: "MARCO", actor: "Mario Rossi", phone: "+39 333 1234567", email: "mario@example.com"),
                   CastMember(name: "GIULIA", actor: "Anna Bianchi"), CastMember(name: "ALDO")]
    let fields = CastMember.setting(members, in: Fountain.titleFields(Fountain.splitTitlePage(sample).titlePage))
    let text = Fountain.joinTitlePage(fields, Fountain.splitTitlePage(sample).body)
    #expect(text.contains("Cast:\n    MARCO | Mario Rossi | +39 333 1234567 | mario@example.com\n    GIULIA | Anna Bianchi\n\n"))
    #expect(CastMember.list(Fountain.titleFields(Fountain.splitTitlePage(text).titlePage)) == Array(members.prefix(2)))
    #expect(!Layout.titlePage(Screenplay(text).lines, linesPerPage: 58).contains { $0.line.text.contains("Mario") })
}

@Test func centersTheTextUnlessSetOtherwise() {
    #expect(Paper.a4.leftMargin == (595 - 432) / 2 && Paper.letter.leftMargin == 90 && Paper.a4.linesPerPage == 58)
    // Not changed here: the settings are global and the other tests run alongside.
    #expect(PageMargins.standard == PageMargins(centered: false, left: 108, top: 72, bottom: 72))
}
