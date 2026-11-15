#if DEBUG
import SwiftUI

struct GroupMemberLabel: View {
    let name: String
    let role: String?
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        Group {
            if let role {
                if textSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) {
                        nameLabel
                        Text(role).font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        nameLabel
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(role).foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            } else {
                nameLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(role.map { "\(name), \($0)" } ?? name)
    }

    private var nameLabel: some View {
        Text(name).fixedSize(horizontal: false, vertical: true)
    }
}

struct EditGroupDisplayNameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var savedDraft: String?
    @State private var isSaving = false
    @State private var showingDraftChoices = false
    @State private var draftIssue: String?
    let group: GroupSummary
    let model: GroupsModel
    let account: String
    let currentName: String
    let onSave: () async -> Void

    init(
        group: GroupSummary, model: GroupsModel, account: String,
        currentName: String, draft: String?, onSave: @escaping () async -> Void
    ) {
        self.group = group
        self.model = model
        self.account = account
        self.currentName = currentName
        self.onSave = onSave
        _name = State(initialValue: draft ?? currentName)
        _savedDraft = State(initialValue: draft)
    }

    private var trimmedName: String { GroupMemberDisplayName.trimmed(name) }
    private var isValid: Bool { trimmedName.isEmpty || GroupMemberDisplayName.visibleName(trimmedName) != nil }
    private var hasUnsavedChanges: Bool { name != (savedDraft ?? currentName) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name)
                        .textContentType(.nickname)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    if !name.isEmpty {
                        Button("Clear Display Name") { name = "" }
                    }
                } footer: {
                    Text("Visible to members of this group. Leave it blank to clear your name.")
                }
                if !isValid {
                    Text("Use one line of up to \(GroupMemberDisplayName.maximumLength) characters.")
                        .foregroundStyle(.secondary)
                }
                if savedDraft != nil {
                    Section {
                        Text("Your draft is saved on this iPhone. Tap Save when you’re ready to try again.")
                            .foregroundStyle(.secondary)
                        Button("Discard Draft", role: .destructive) { showingDraftChoices = true }
                    }
                }
                if let draftIssue { Text(draftIssue).foregroundStyle(.secondary) }
                GroupActionStatus(model: model)
            }
            .disabled(isSaving)
            .navigationTitle("My Display Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if hasUnsavedChanges { showingDraftChoices = true }
                        else { dismiss() }
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || model.isWorking || model.isRefreshing || !isValid ||
                                  (trimmedName == currentName && savedDraft == nil))
                }
            }
            .interactiveDismissDisabled(isSaving || hasUnsavedChanges)
            .confirmationDialog("Keep this display-name draft?", isPresented: $showingDraftChoices, titleVisibility: .visible) {
                Button("Keep Draft on This iPhone") {
                    if persistDraft() { dismiss() }
                }
                Button("Discard Draft", role: .destructive) {
                    if model.keepMemberNameDraft(nil, in: group, account: account) { dismiss() }
                    else { draftIssue = "The draft couldn’t be removed from this iPhone." }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @discardableResult
    private func persistDraft() -> Bool {
        let stored = model.keepMemberNameDraft(name, in: group, account: account)
        if stored {
            savedDraft = name
            draftIssue = nil
        } else {
            draftIssue = "This iPhone couldn’t save the draft. Keep this screen open to retain your changes."
        }
        return stored
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        model.actionIssue = nil
        persistDraft()
        if await model.saveMyDisplayName(trimmedName, in: group, account: account) {
            await onSave()
            dismiss()
        }
    }
}
#endif
