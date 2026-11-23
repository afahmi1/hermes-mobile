import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Editing screens for a project workspace: bot assignment, instructions, text files, and the
// catalog-reference page. Text is always shown literally (never rendered as markdown); every Save
// is explicit and a 409 never overwrites anything silently.

// MARK: bot assignment

struct BotAssignmentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceAssignmentModel

    var body: some View {
        List {
            switch model.phase {
            case .idle, .loading:
                HStack { ProgressView(); Text("Loading bots…").foregroundStyle(.secondary) }
            case .failed(let f):
                Section {
                    Text(f.message).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.load() } }
                }
            case .loaded:
                loaded
            }
        }
        .navigationTitle("Assigned bots")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .onDisappear { model.discard() }
        .toolbar {
            if model.isEditable {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.discard(); dismiss() }
                        .accessibilityIdentifier("assign.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("assign.save")
                        .accessibilityHint("Saves which bots can work in this project")
                }
            }
        }
    }

    @ViewBuilder private var loaded: some View {
        if !model.isEditable {
            Section {
                ForEach(model.assignment?.assigned ?? [], id: \.self) { id in
                    Label(app.botName(id), systemImage: "person.crop.circle")
                }
                if (model.assignment?.assigned ?? []).isEmpty { Text("No bots assigned").foregroundStyle(.secondary) }
            } footer: { Text("Bot access for this project is set on the Mac.") }
        } else {
            Section {
                if model.eligible.isEmpty {
                    Text("No bots are eligible yet. Eligible bots are set on the Mac.").foregroundStyle(.secondary)
                }
                ForEach(model.eligible, id: \.self) { id in
                    let on = model.selection.contains(id)
                    Button { model.toggle(id) } label: {
                        HStack {
                            Text(app.botName(id)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Color.accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("assign.\(id)")
                    .accessibilityLabel(app.botName(id))
                    .accessibilityValue(on ? "Assigned" : "Not assigned")
                    .accessibilityHint("Double tap to \(on ? "remove from" : "assign to") this project")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            } header: { Text("Eligible bots") } footer: {
                Text("Choose which bots can work in this project, then tap Save.")
            }
        }
        if !model.inactive.isEmpty {
            Section {
                ForEach(model.inactive, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.botName(id))
                        Text("Not available on the Mac right now").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: { Text("Not available") } footer: {
                Text("These stay assigned and come back if the bot is available again.")
            }
        }
        if let note = model.hiddenChatsNote {
            Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        if let m = model.message {
            Section { Text(m).font(.footnote).foregroundStyle(m == "Saved." ? Color.secondary : Color.orange)
                .accessibilityIdentifier("assign.message") }
        }
    }
}

// MARK: byte counter

private struct ByteCounter: View {
    let bytes: Int
    let limit: Int
    var body: some View {
        Text("\(bytes) / \(limit) bytes")
            .font(.caption.monospacedDigit())
            .foregroundStyle(bytes > limit ? .red : .secondary)
            .accessibilityLabel("\(bytes) of \(limit) bytes used")
    }
}

private struct ConflictBanner: View {
    let text: String
    var reload: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            if let reload { Button("Reload latest", action: reload).font(.footnote.weight(.semibold)) }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

// MARK: instructions

struct InstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceProjectModel

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 10) {
            if model.instructionsConflict {
                ConflictBanner(text: "The instructions changed on the Mac or another device. Your draft is kept; nothing was overwritten.") {
                    Task { await model.reloadLatestInstructions() }
                }
            }
            if model.instructionsEditing {
                TextEditor(text: $m.instructionsDraft)
                    .font(.body)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                    .accessibilityIdentifier("instr.editor")
                    .accessibilityLabel("Project instructions")
                    .accessibilityHint("Edit the instructions, then tap Save")
                ByteCounter(bytes: model.instructionBytes, limit: WorkspaceLimits.instructionBytes)
            } else {
                ScrollView {
                    Group {
                        if model.detail.instructions.isEmpty {
                            Text("No instructions yet. Tap Edit to add some.").foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: model.detail.instructions).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Project instructions")
                Text("Saved on your Mac. Sent to a bot only when you switch project context on for a message.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.instructionsEditing)
        .toolbar {
            if model.instructionsEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelEditInstructions() }.accessibilityIdentifier("instr.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.saveInstructions() } }
                        .disabled(!model.canSaveInstructions).accessibilityIdentifier("instr.save")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { model.beginEditInstructions() }.accessibilityIdentifier("instr.edit")
                }
            }
        }
    }
}

// MARK: workspace text file

struct WorkspaceFileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor: WorkspaceFileEditorModel
    @State private var confirmDelete = false
    let onChanged: () -> Void

    init(file: WorkspaceFile, project: String, onChanged: @escaping () -> Void) {
        _editor = State(initialValue: WorkspaceFileEditorModel(client: .live(project: project), mode: .existing(file)))
        self.onChanged = onChanged
    }

    var body: some View {
        @Bindable var e = editor
        Group {
            switch editor.phase {
            case .idle, .loading:
                ProgressView("Loading file…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let f):
                ContentUnavailableView {
                    Label("File unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(f.message) } actions: {
                    Button("Try again") { Task { await editor.load() } }.buttonStyle(.borderedProminent)
                }
            case .loaded:
                VStack(alignment: .leading, spacing: 10) {
                    if let c = editor.conflict {
                        ConflictBanner(text: c == .stale
                                       ? "This file changed on the Mac or another device. Your draft is kept; nothing was overwritten."
                                       : WorkspacesFailure.duplicate.message,
                                       reload: c == .stale ? { Task { await editor.reloadLatest() } } : nil)
                    }
                    if let p = editor.problem, editor.isEditing { Text(p).font(.footnote).foregroundStyle(.red) }
                    if editor.isEditing {
                        TextEditor(text: $e.draft)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                            .accessibilityIdentifier("file.editor")
                            .accessibilityLabel("Contents of \(editor.name)")
                            .accessibilityHint("Edit the text, then tap Save")
                        ByteCounter(bytes: editor.bytes, limit: WorkspaceLimits.fileBytes)
                    } else {
                        ScrollView {
                            Text(verbatim: editor.draft)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("file.text")
                        }
                        .accessibilityLabel("Contents of \(editor.name)")
                        Button("Delete file", role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("file.delete")
                    }
                }
                .padding()
            }
        }
        .navigationTitle(editor.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editor.isEditing)
        .task { if editor.phase == .idle { await editor.load() } }
        .toolbar {
            if editor.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editor.cancel() }.accessibilityIdentifier("file.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await editor.save() { onChanged() } } }
                        .disabled(!editor.canSave).accessibilityIdentifier("file.save")
                }
            } else if editor.phase == .loaded {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editor.beginEdit() }.accessibilityIdentifier("file.edit")
                }
            }
        }
        .confirmationDialog("Delete \(editor.name) from this workspace?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { if await editor.delete() { onChanged(); dismiss() } } }
        }
        .alert("Workspace", isPresented: Binding(get: { editor.notice != nil }, set: { if !$0 { editor.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(editor.notice ?? "") }
    }
}

// MARK: new text file

struct NewFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editor: WorkspaceFileEditorModel
    let onSaved: () -> Void

    init(project: String, existingCount: Int, prefillName: String = "", onSaved: @escaping () -> Void) {
        _editor = State(initialValue: WorkspaceFileEditorModel(client: .live(project: project), mode: .new,
                                                              existingCount: existingCount, name: prefillName))
        self.onSaved = onSaved
    }

    var body: some View {
        @Bindable var e = editor
        NavigationStack {
            Form {
                Section {
                    TextField("Name, for example notes.md", text: $e.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("newfile.name")
                } header: { Text("File name") } footer: {
                    Text("Ends in .md, .txt, .csv or .json. Up to 4 files, 8192 bytes each.")
                }
                Section {
                    TextEditor(text: $e.draft)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 200)
                        .accessibilityIdentifier("newfile.editor")
                        .accessibilityLabel("File contents")
                    ByteCounter(bytes: editor.bytes, limit: WorkspaceLimits.fileBytes)
                } header: { Text("Contents") } footer: {
                    if let p = editor.problem { Text(p).foregroundStyle(.red) }
                    else if let c = editor.conflict, c == .duplicate { Text(WorkspacesFailure.duplicate.message).foregroundStyle(.red) }
                    else if let c = editor.conflict, c == .stale { Text(WorkspacesFailure.conflict.message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New text file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("newfile.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await editor.save() { onSaved(); dismiss() } } }
                        .disabled(!editor.canSave).accessibilityIdentifier("newfile.save")
                }
            }
            .alert("Workspace", isPresented: Binding(get: { editor.notice != nil }, set: { if !$0 { editor.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(editor.notice ?? "") }
        }
        .interactiveDismissDisabled(!editor.draft.isEmpty)
    }
}

// MARK: catalog reference

/// A catalog "related file" is only metadata about a file on the Mac. This page says so plainly.
struct ReferenceDetailView: View {
    let reference: DisplayReference
    /// Non-nil when this project has a workspace.
    let workspaceProject: String?
    @State private var copied = false
    @State private var addingCopy = false
    @State private var added = false

    private var basename: String { (reference.path as NSString).lastPathComponent }
    private var typeSupported: Bool {
        WorkspaceLimits.supportedExtensions.contains((basename as NSString).pathExtension.lowercased())
    }

    var body: some View {
        List {
            Section {
                Text("A reference to a file on your Mac. Hermes Mobile doesn't open, copy or change the original. You can start a separate Workspace file with the same name and type or import its text yourself; edits there never reach the Mac file.")
            }
            Section {
                LabeledContent("Root", value: reference.rootName)
                LabeledContent("Kind", value: reference.kind == .vault ? "Vault" : reference.kind == .repo ? "Repo" : "Folder")
                LabeledContent("Path") { Text(reference.path).font(.body.monospaced()).textSelection(.enabled) }
                    .accessibilityElement(children: .combine)
            }
            Section {
                Button {
                    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: reference.copyText]],
                                                 options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy path", systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("ref.copy")
                    .accessibilityHint("Copies the root name and path")
                if let project = workspaceProject {
                    if typeSupported {
                        Button { addingCopy = true } label: { Label("New Workspace file named \(basename)", systemImage: "square.and.pencil") }
                            .accessibilityIdentifier("ref.addcopy")
                            .accessibilityHint("Starts an empty Workspace file with this name. It doesn't copy or change the file on your Mac.")
                            .sheet(isPresented: $addingCopy) {
                                NewFileSheet(project: project, existingCount: 0, prefillName: basename) { added = true }
                            }
                    } else {
                        Text("This type can't be added to a Workspace. Only .md, .txt, .csv and .json text files can.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if added { Text("Added to the Workspace. It's a separate copy; the original on your Mac is unchanged.") }
                else if workspaceProject != nil && typeSupported {
                    Text("The copy starts empty: type or paste its text. It isn't read from your Mac.")
                }
            }
        }
        .navigationTitle(basename)
        .navigationBarTitleDisplayMode(.inline)
    }
}
