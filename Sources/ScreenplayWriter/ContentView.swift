import SwiftUI

struct ContentView: View {
    @Binding var document: ScreenplayDocument
    var fileURL: URL?

    @State private var mode = Mode.script
    @State private var editor = EditorController()
    @State private var selectedScene: ScriptScene.ID?
    @State private var selectedCharacter: CharacterInfo.ID?
    @State private var showRename = false
    @State private var exporting = false
    @State private var pdf = PDFFile()
    @State private var exportError: String?
    @State private var creating = false
    @State private var showInspector = false
    @AppStorage("sceneNumbers") private var sceneNumbers = true
    @AppStorage("boldHeadings") private var boldHeadings = true
    @AppStorage("marginsCentered") private var marginsCentered = true
    @AppStorage("marginLeft") private var marginLeft = 108.0
    @AppStorage("marginTop") private var marginTop = 72.0
    @AppStorage("marginBottom") private var marginBottom = 72.0
    @AppStorage("groupByTime") private var groupByTime = false

    var body: some View {
        let script = Screenplay(document.text)
        let paper = Paper.of(script.lines) ?? .standard
        let pageCount = Layout.pages(script, paper: paper).count

        NavigationSplitView {
            SceneList(scenes: script.scenes, selection: $selectedScene)
                .onChange(of: selectedScene) { _, id in
                    guard let id, id < script.scenes.count else { return }
                    show(script.scenes[id])
                }
        } detail: {
            ZStack {
                scriptEditor(paper: paper)
                switch mode {
                case .script: EmptyView()
                case .characters:
                    CharactersView(script: script, cast: cast, member: member, selection: $selectedCharacter) { showRename = true }
                case .shooting:
                    ShootingView(script: script, paper: paper, groupByTime: groupByTime, show: show)
                }
            }
            // On the detail column, as Apple shows it: on the whole split view the toolbar items end up in the overflow menu.
            .toolbar { toolbar(script) }
            .inspector(isPresented: $showInspector) {
                ProjectSettingsView(field: field, paper: paperBinding(paper))
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .navigationSubtitle(String(localized: "\(script.scenes.count) scenes") + " · " + String(localized: "\(pageCount) pages"))
        .sheet(isPresented: $showRename) {
            RenameSheet(names: script.characters.map(\.name),
                        initial: selectedCharacter ?? script.characters.first?.name ?? "") { old, new, everywhere in
                editor.replaceAll(with: Fountain.renaming(old, to: new, in: Fountain.splitTitlePage(document.text).body, everywhere: everywhere),
                                  actionName: String(localized: "Rename Character"))
                renameCast(old.uppercased(), to: new.uppercased())
                selectedCharacter = new.uppercased()
            }
        }
        .fileExporter(isPresented: $exporting, document: pdf, contentType: .pdf,
                      defaultFilename: fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Screenplay")) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn’t Export the PDF", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $creating) {
            NewScreenplaySheet(title: field(["Title"]), author: field(["Author", "Authors"]), paper: paperBinding(paper))
        }
        .onAppear {
            if document.isNew { document.isNew = false; creating = true }
        }
        .focusedSceneValue(\.windowActions, actions(script, paper: paper))
        .frame(minWidth: 760, minHeight: 480)
        .background(FillScreenOnOpen())
    }

    @ToolbarContentBuilder
    private func toolbar(_ script: Screenplay) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Switch between the script, its characters and the shooting plan")
        }
        if mode == .script {
            ToolbarItem { ElementButtons(editor: editor) }
            ToolbarGap()
        }
        if mode == .characters {
            ToolbarItem {
                Button("Rename…") { showRename = true }
                    .disabled(script.characters.isEmpty)
                    .help("Rename a character everywhere in the script")
            }
            ToolbarGap()
        }
        if mode == .shooting {
            ToolbarItem {
                Picker("Group By", selection: $groupByTime) {
                    Text("Location").tag(false)
                    Text("Location and Time").tag(true)
                }
                .help("Group the scenes to shoot together")
            }
            ToolbarGap()
        }
        ToolbarItem {
            Button("Export PDF…", action: exportPDF)
                .prominentButton()
                .help("Export the script as a PDF in standard screenplay format")
        }
        ToolbarGap()
        ToolbarItem {
            Button { showInspector.toggle() } label: { Label("Project Settings", systemImage: "info.circle") }
                .help("Show or hide the title page and paper settings")
        }
    }

    /// The editor holds only the script; the title page lives in the project settings.
    private func scriptEditor(paper: Paper) -> some View {
        let body = Binding(get: { Fountain.splitTitlePage(document.text).body },
                           set: { document.text = Fountain.joinTitlePage(Fountain.titleFields(Fountain.splitTitlePage(document.text).titlePage), $0) })
        let fields = Fountain.titleFields(Fountain.splitTitlePage(document.text).titlePage)
        // Reading the settings here redraws the sheets when they change; the layout reads PageMargins.current.
        _ = (marginsCentered, marginLeft, marginTop, marginBottom)
        let margins = PageMargins.current
        return PagedEditor(text: body, paper: paper, margins: margins, boldHeadings: boldHeadings, titleRows: Layout.titlePage(fields, linesPerPage: paper.linesPerPage),
                           onTitleClick: { showInspector = true }, controller: editor, isActive: mode == .script)
    }

    /// A title page value; `keys` lists the spellings it can have in the file, the first one is used for new values.
    private func field(_ keys: [String]) -> Binding<String> {
        let matches = { (f: TitleField) in keys.contains { $0.lowercased() == f.key.lowercased() } }
        return Binding(get: { Fountain.titleFields(Fountain.splitTitlePage(document.text).titlePage).first(where: matches)?.value ?? "" },
                       set: { value in
                           let split = Fountain.splitTitlePage(document.text)
                           var fields = Fountain.titleFields(split.titlePage)
                           if let i = fields.firstIndex(where: matches) { fields[i].value = value } else { fields.append(TitleField(key: keys[0], value: value)) }
                           document.text = Fountain.joinTitlePage(fields, split.body)
                       })
    }

    private var cast: [CastMember] { CastMember.list(Fountain.titleFields(Fountain.splitTitlePage(document.text).titlePage)) }

    private func setCast(_ members: [CastMember]) {
        let split = Fountain.splitTitlePage(document.text)
        document.text = Fountain.joinTitlePage(CastMember.setting(members, in: Fountain.titleFields(split.titlePage)), split.body)
    }

    /// The cast details of one character, saved in the title page as they're typed.
    private func member(_ name: String) -> Binding<CastMember> {
        Binding(get: { cast.first { $0.name == name } ?? CastMember(name: name) },
                set: { new in
                    var members = cast
                    if let i = members.firstIndex(where: { $0.name == name }) { members[i] = new } else { members.append(new) }
                    setCast(members)
                })
    }

    /// The details follow the character to its new name; when merging into one that has details, those win.
    private func renameCast(_ old: String, to new: String) {
        var members = cast
        guard let i = members.firstIndex(where: { $0.name == old }) else { return }
        if members.contains(where: { $0.name == new }) { members.remove(at: i) } else { members[i].name = new }
        setCast(members)
    }

    private func paperBinding(_ paper: Paper) -> Binding<Paper> {
        Binding(get: { paper }, set: { document.text = $0.setting(in: document.text) })
    }

    private func actions(_ script: Screenplay, paper: Paper) -> WindowActions {
        let editor = editor
        return WindowActions(mode: $mode, paper: paperBinding(paper), exportPDF: exportPDF,
                             renameCharacter: script.characters.isEmpty ? nil : { showRename = true },
                             format: mode == .script ? { editor.format($0) } : nil,
                             emphasize: mode == .script ? { editor.emphasize($0) } : nil)
    }

    private func show(_ scene: ScriptScene) {
        mode = .script
        let full = (document.text as NSString).length, body = (Fountain.splitTitlePage(document.text).body as NSString).length
        editor.reveal(scene.offset - (full - body))
    }

    private func exportPDF() {
        let script = Screenplay(document.text)
        pdf = PDFFile(data: Layout.pdf(script, paper: Paper.of(script.lines) ?? .standard,
                                       sceneNumbers: sceneNumbers, boldHeadings: boldHeadings))
        exporting = true
    }
}

/// The Screenplay menu's elements as toolbar buttons; the one of the line being written stays pressed.
struct ElementButtons: View {
    let editor: EditorController

    var body: some View {
        ControlGroup {
            ForEach(Array(Element.formattable.enumerated()), id: \.element) { n, e in
                Toggle(isOn: Binding(get: { editor.current == e }, set: { _ in editor.format(e) })) {
                    Label { Text(e.title) } icon: { Image(systemName: e.symbol) }
                }
                .toggleStyle(.button)
                .help(String(localized: e.title) + " (⌘\(n + 1))")
            }
        }
    }
}

/// Opens the window as large as the screen allows, without going full screen.
struct FillScreenOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Filler() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Filler: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window else { return }
            done = true
            DispatchQueue.main.async {
                if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true) }
            }
        }
    }
}

/// Asked once, when a new screenplay is created.
struct NewScreenplaySheet: View {
    @Binding var title: String
    @Binding var author: String
    @Binding var paper: Paper
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)
                TextField("Author", text: $author)
                Picker("Paper size", selection: $paper) {
                    ForEach(Paper.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("New Screenplay")
            } footer: {
                Text("The sheets in the editor and the exported PDF use this paper size. You can change all of this later in Project Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Create") { dismiss() } }
        }
        .interactiveDismissDisabled()
    }
}

/// The project's title page and paper, kept in the file as the Fountain title page.
struct ProjectSettingsView: View {
    let field: ([String]) -> Binding<String>
    @Binding var paper: Paper

    var body: some View {
        Form {
            Section("Title Page") {
                TextField("Title", text: field(["Title"]))
                TextField("Credit", text: field(["Credit"]), prompt: Text("Written by"))
                TextField("Author", text: field(["Author", "Authors"]))
                TextField("Source", text: field(["Source"]), prompt: Text("Based on…"))
                TextField("Draft date", text: field(["Draft date"]))
                TextField("Contact", text: field(["Contact"]), axis: .vertical).lineLimit(2...6)
                TextField("Notes", text: field(["Notes", "Copyright"]), axis: .vertical).lineLimit(1...4)
            }
            Section("Page") {
                Picker("Paper size", selection: $paper) {
                    ForEach(Paper.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SceneList: View {
    let scenes: [ScriptScene]
    @Binding var selection: ScriptScene.ID?

    var body: some View {
        List(scenes, selection: $selection) { scene in
            HStack(alignment: .firstTextBaseline) {
                Text(scene.number).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
                VStack(alignment: .leading) {
                    Text(scene.location.isEmpty ? scene.heading : scene.location).lineLimit(1)
                    Text([scene.setting, scene.time].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if scenes.isEmpty {
                ContentUnavailableView("No Scenes", systemImage: "film",
                                       description: Text("Start a line with INT. or EXT. to add a scene."))
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
    }
}

struct CharactersView: View {
    let script: Screenplay
    let cast: [CastMember]
    let member: (String) -> Binding<CastMember>
    @Binding var selection: CharacterInfo.ID?
    var rename: () -> Void
    @State private var sortOrder = [KeyPathComparator(\CharacterInfo.lines, order: .reverse)]

    var body: some View {
        if script.characters.isEmpty {
            ContentUnavailableView("No Characters", systemImage: "person.2",
                                   description: Text("Characters appear when you write a name in capitals above a line of dialogue."))
        } else {
            HStack(spacing: 0) {
                table
                Divider()
                Group {
                    if let selection, script.characters.contains(where: { $0.name == selection }) {
                        CastDetails(member: member(selection))
                    } else {
                        ContentUnavailableView("No Character Selected", systemImage: "person.crop.rectangle",
                                               description: Text("Select a character to add the actor who plays it and their contacts."))
                    }
                }
                .frame(width: 300)
            }
        }
    }

    private var table: some View {
        Table(script.characters.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
            TableColumn("Actor") { c in Text(cast.first { $0.name == c.name }?.actor ?? "") }
                .width(min: 100, ideal: 160)
            TableColumn("Lines", value: \.lines) { Text($0.lines, format: .number).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("Scenes", value: \.sceneCount) { Text($0.sceneCount, format: .number).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("First Scene", value: \.firstScene) { c in
                Text(c.firstScene < script.scenes.count ? script.scenes[c.firstScene].number : "—").monospacedDigit()
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: CharacterInfo.ID.self) { ids in
            Button("Rename…") { selection = ids.first; rename() }.disabled(ids.isEmpty)
        } primaryAction: { ids in
            selection = ids.first; rename()
        }
    }
}

/// The actor and contacts of the selected character.
struct CastDetails: View {
    @Binding var member: CastMember

    var body: some View {
        Form {
            Section {
                TextField("Actor", text: $member.actor)
                TextField("Phone", text: $member.phone)
                TextField("Email", text: $member.email)
                TextField("Notes", text: $member.notes, axis: .vertical).lineLimit(2...6)
            } header: {
                Text(member.name)
            } footer: {
                Text("Saved in the screenplay file, never printed.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShootingView: View {
    let script: Screenplay
    let paper: Paper
    let groupByTime: Bool
    var show: (ScriptScene) -> Void

    var body: some View {
        if script.scenes.isEmpty {
            ContentUnavailableView("No Scenes", systemImage: "film",
                                   description: Text("Scenes are grouped here by location as you write them."))
        } else {
            let eighths = script.scenes.map { Layout.eighths($0, in: script, paper: paper) }
            let groups = Dictionary(grouping: script.scenes) { s in
                groupByTime && !s.shootingTime.isEmpty ? "\(s.mainLocation) · \(s.shootingTime)" : s.mainLocation
            }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

            List {
                ForEach(groups, id: \.key) { group in
                    let scenes = group.value.sorted { ($0.location, $0.time, $0.id) < ($1.location, $1.time, $1.id) }
                    let total = scenes.reduce(0) { $0 + eighths[$1.id] }
                    // The location is a row, not a section header: pinned headers sat under the toolbar
                    // and looked part of it.
                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.key.isEmpty ? String(localized: "No Location") : group.key).font(.headline)
                            Spacer()
                            Text(String(localized: "\(scenes.count) scenes") + " · " + String(localized: "\(Layout.eighthsText(total)) pp."))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.top, 10)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(scenes) { scene in row(scene, eighths: eighths[scene.id]) }
                    }
                }
            }
        }
    }

    private func row(_ scene: ScriptScene, eighths: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(scene.number).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            Text(scene.setting).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text([scene.location, scene.time].filter { !$0.isEmpty }.joined(separator: " · "))
                if !scene.characters.isEmpty {
                    Text(scene.characters.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Layout.eighthsText(eighths)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { show(scene) }
        .contextMenu { Button("Show in Script") { show(scene) } }
        .help("Double-click to show the scene in the script")
    }
}

struct RenameSheet: View {
    let names: [String]
    var onRename: (_ old: String, _ new: String, _ everywhere: Bool) -> Void
    @State private var old: String
    @State private var new = ""
    @State private var everywhere = true
    @Environment(\.dismiss) private var dismiss

    init(names: [String], initial: String, onRename: @escaping (String, String, Bool) -> Void) {
        self.names = names
        self.onRename = onRename
        _old = State(initialValue: initial)
    }

    private var trimmed: String { new.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                Picker("Character", selection: $old) {
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                TextField("New name", text: $new, prompt: Text(old.capitalized))
                Toggle("Also replace the name in action and dialogue", isOn: $everywhere)
            } header: {
                Text("Rename Character")
            } footer: {
                Text("If another character already has the new name, the two are merged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") { onRename(old, trimmed, everywhere); dismiss() }
                    .disabled(trimmed.isEmpty || trimmed.uppercased() == old.uppercased())
            }
        }
    }
}
