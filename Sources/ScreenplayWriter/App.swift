import SwiftUI
import UniformTypeIdentifiers

@main
struct ScreenplayWriterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: ScreenplayDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            ScreenplayCommands()
        }
        Settings { SettingsView() }
    }
}

/// One copy of the app at a time: a second launch brings the running one forward and quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        guard let running = others.first else { return }
        running.activate()
        exit(0)
    }
}

extension UTType {
    nonisolated static let fountain = UTType(importedAs: "com.quote-unquote.fountain", conformingTo: .plainText)
    /// The app's own files: Fountain text with the .script extension.
    nonisolated static let screenplay = UTType(exportedAs: "com.giuliomaffei.screenplay", conformingTo: .plainText)
}

/// A screenplay saved as Fountain plain text, readable by Highland, Slugline, Fade In and others.
nonisolated struct ScreenplayDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.screenplay, .fountain, .plainText]
    /// Everything is saved as .script; a .fountain or text file asks where to save it the first time.
    static let writableContentTypes: [UTType] = [.screenplay]
    var text: String
    /// Just created, not opened: the window asks for the paper size.
    var isNew = false

    init() {
        isNew = true
        text = """
        Title: \(String(localized: "Untitled"))
        Credit: \(String(localized: "Written by"))
        Author: \(NSFullUserName())
        Draft date: \(Date.now.formatted(date: .long, time: .omitted))

        FADE IN:


        """
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

nonisolated struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum Mode: String, CaseIterable, Identifiable {
    case script, characters, shooting
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .script: "Script"
        case .characters: "Characters"
        case .shooting: "Shooting"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(Mode.allCases.firstIndex(of: self)! + 1)")) }
}

extension Element {
    /// The elements the Screenplay menu can turn a line into, with Final Draft's shortcuts.
    static let formattable: [Element] = [.sceneHeading, .action, .character, .parenthetical, .transition]
    var symbol: String {
        switch self {
        case .sceneHeading: "movieclapper"
        case .character: "person"
        case .parenthetical: "parentheses"
        case .transition: "arrow.right.to.line"
        default: "text.alignleft"
        }
    }
    var title: LocalizedStringResource {
        switch self {
        case .sceneHeading: "Scene Heading"
        case .character: "Character"
        case .parenthetical: "Parenthetical"
        case .transition: "Transition"
        default: "Action"
        }
    }
}

/// What the focused window offers to the menu bar; nil means the command is disabled.
struct WindowActions {
    var mode: Binding<Mode>
    var paper: Binding<Paper>
    var exportPDF: () -> Void
    var renameCharacter: (() -> Void)?
    var format: ((Element) -> Void)?
    var emphasize: ((String) -> Void)?
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

struct ScreenplayCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    var body: some Commands {
        // ⇧⌘S is Save As, as people expect, rather than macOS's Duplicate (moved to ⌥⇧⌘S).
        CommandGroup(replacing: .saveItem) {
            Button("Save") { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) }
                .keyboardShortcut("s")
            Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Duplicate") { NSApp.sendAction(#selector(NSDocument.duplicate(_:)), to: nil, from: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
            Button("Rename…") { NSApp.sendAction(#selector(NSDocument.rename(_:)), to: nil, from: nil) }
            Button("Move To…") { NSApp.sendAction(#selector(NSDocument.move(_:)), to: nil, from: nil) }
            Button("Revert to Saved") { NSApp.sendAction(#selector(NSDocument.revertToSaved(_:)), to: nil, from: nil) }
        }
        CommandGroup(after: .importExport) {
            Button("Export PDF…") { actions?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(before: .toolbar) {
            ForEach(Mode.allCases) { mode in
                Button(String(localized: mode.title)) { actions?.mode.wrappedValue = mode }
                    .keyboardShortcut(mode.shortcut, modifiers: [.command, .control])
                    .disabled(actions == nil)
            }
            Divider()
        }
        CommandMenu("Screenplay") {
            ForEach(Element.formattable, id: \.self) { e in
                Button(String(localized: e.title)) { actions?.format?(e) }
                    .keyboardShortcut(KeyEquivalent(Character("\(Element.formattable.firstIndex(of: e)! + 1)")), modifiers: .command)
                    .disabled(actions?.format == nil)
            }
            Divider()
            Button("Bold") { actions?.emphasize?("**") }.keyboardShortcut("b").disabled(actions?.emphasize == nil)
            Button("Italic") { actions?.emphasize?("*") }.keyboardShortcut("i").disabled(actions?.emphasize == nil)
            Button("Underline") { actions?.emphasize?("_") }.keyboardShortcut("u").disabled(actions?.emphasize == nil)
            Divider()
            Picker("Paper Size", selection: Binding(get: { actions?.paper.wrappedValue ?? .standard },
                                                     set: { actions?.paper.wrappedValue = $0 })) {
                ForEach(Paper.allCases) { Text($0.title).tag($0) }
            }
            .disabled(actions == nil)
            Divider()
            Button("Rename Character…") { actions?.renameCharacter?() }
                .disabled(actions?.renameCharacter == nil)
        }
    }
}

/// A margin edited in centimetres, or in inches where the system uses them; stored in points.
struct MarginField: View {
    let title: LocalizedStringKey
    @Binding var points: Double
    private static let metric = Locale.current.measurementSystem != .us
    private static let pointsPerUnit = metric ? 72 / 2.54 : 72.0

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { points / Self.pointsPerUnit }, set: { points = max(0, $0) * Self.pointsPerUnit }),
                          format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text(Self.metric ? "cm" : "in").foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("sceneNumbers") private var sceneNumbers = true
    @AppStorage("boldHeadings") private var boldHeadings = true
    @AppStorage("marginsCentered") private var marginsCentered = true
    @AppStorage("marginLeft") private var marginLeft = 108.0
    @AppStorage("marginTop") private var marginTop = 72.0
    @AppStorage("marginBottom") private var marginBottom = 72.0

    var body: some View {
        Form {
            Section("Page Format") {
                Toggle("Print scene numbers", isOn: $sceneNumbers)
                Toggle("Scene headings in bold", isOn: $boldHeadings)
            }
            Section {
                Toggle("Center the text on the page", isOn: $marginsCentered)
                if !marginsCentered { MarginField(title: "Left", points: $marginLeft) }
                MarginField(title: "Top", points: $marginTop)
                MarginField(title: "Bottom", points: $marginBottom)
                Button("Use Standard Format Margins") {
                    let m = PageMargins.standard
                    (marginsCentered, marginLeft, marginTop, marginBottom) = (m.centered, m.left, m.top, m.bottom)
                }
            } header: {
                Text("Margins")
            } footer: {
                Text("The text column stays 6 inches wide, as the screenplay format requires. The standard format has a 1.5 inch left margin for binding and 1 inch at the top and bottom.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
    }
}
