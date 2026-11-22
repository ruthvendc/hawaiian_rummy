#if DEBUG
import Network
import SwiftData
import SwiftUI

struct GroupPlayersView: View {
    let group: GroupSummary
    let model: GroupsModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasConnection: Bool?
    @State private var loaded: GroupRosterContents?
    @State private var loadedSession: UUID?
    @State private var refreshID: UUID?
    @State private var isSaving = false
    @State private var loadIssue: String?
    @State private var actionIssue: String?
    @State private var addName = ""
    @State private var addID = UUID()
    @State private var renaming: GroupPlayerIdentity?
    @State private var renameName = ""
    @State private var retiring: GroupPlayerIdentity?
    @State private var showingRetired = false
    @State private var showingPersonalCopy = false

    private var saved: CachedGroupRoster? { model.cachedRoster(for: group) }
    private var canConnect: Bool { scenePhase == .active && hasConnection == true }
    private var live: GroupRosterContents? {
        guard canConnect, loadedSession == model.accountGeneration, saved != nil else { return nil }
        return loaded
    }
    private var canAdd: Bool { live?.access.canAdd == true && !isSaving }
    private var addConflict: String? { nameConflict(addName, excluding: addID) }
    private var refreshContext: RefreshContext {
        RefreshContext(canConnect: canConnect, session: model.accountGeneration)
    }

    var body: some View {
        List {
            Section {
                SectionIntroCard(title: group.name, subtitle: "Group players", icon: "person.2.fill")
                    .listRowBackground(Color.clear)
            }
            if live?.access.canAdd == true || !addName.isEmpty { addSection }
            statusSection
            if let saved {
                Section("Active Players") {
                    let active = saved.players.filter { !$0.isRetired }
                    if active.isEmpty { Text("No active players").foregroundStyle(.secondary) }
                    ForEach(active) { playerRow($0) }
                }
                let retired = saved.players.filter(\.isRetired)
                if !retired.isEmpty {
                    Section {
                        DisclosureGroup("Retired Players", isExpanded: $showingRetired) {
                            ForEach(retired) { playerRow($0) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.top, 6, for: .scrollContent)
        .listSectionSpacing(10)
        .background(Color.softPurpleBackground)
        .navigationTitle("Players")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { if !isSaving { await reload() } }
        .task {
            let monitor = NWPathMonitor()
            for await path in monitor {
                hasConnection = path.status == .satisfied
            }
        }
        .task(id: refreshContext) {
            await reload()
        }
        .sheet(item: $renaming) { original in
            renameForm(original)
        }
        .sheet(isPresented: $showingPersonalCopy, onDismiss: { actionIssue = nil }) {
            GroupPersonalPlayerCopyView(
                canCopy: canAdd, isSaving: isSaving, issue: actionIssue,
                conflict: { name, id in nameConflict(name, excluding: id) },
                copy: { draft in
                    await perform(.add(draft)) { showingPersonalCopy = false }
                }
            )
        }
        .alert("Retire player?", isPresented: Binding(
            get: { retiring != nil },
            set: { if !$0 { retiring = nil } }
        ), presenting: retiring) { player in
            Button("Retire", role: .destructive) {
                Task { await perform(.setRetired(player, true)) }
            }
            .disabled(live?.access.role != .owner || isSaving)
            Button("Cancel", role: .cancel) {}
        } message: { player in
            Text("\(player.displayName) will move to Retired Players. Their name stays reserved.")
        }
    }

    private var addSection: some View {
        Section("Add Player") {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Enter New Player Name", text: $addName)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("New group player name")
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit(addPlayer)
                Button(action: addPlayer) {
                    Text("Add Player").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(PlayerName.trimmed(addName).isEmpty || addConflict != nil)
            }
            .disabled(!canAdd)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
            if let addConflict { statusText(addConflict) }
            Button("Copy a Personal Player", systemImage: "person.crop.circle.badge.plus") {
                actionIssue = nil
                showingPersonalCopy = true
            }
            .disabled(!canAdd)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isSaving || refreshID != nil || hasConnection != true || loadIssue != nil ||
            model.cacheIssue != nil || (actionIssue != nil && renaming == nil) {
            Section {
                if isSaving { ProgressView("Saving player…") }
                else if refreshID != nil || hasConnection == nil { ProgressView("Loading players…") }
                if hasConnection == false || loadIssue != nil {
                    if saved != nil {
                        statusText("Showing saved players. Connect to iCloud and refresh to edit.")
                    } else if hasConnection == false {
                        statusText("Connect to iCloud and refresh to load players.")
                    }
                    if hasConnection != false, let loadIssue { statusText(loadIssue) }
                    Button("Refresh Players") { Task { await reload() } }
                        .disabled(!canConnect || isSaving || refreshID != nil)
                }
                if let actionIssue, renaming == nil { statusText(actionIssue) }
                if let cacheIssue = model.cacheIssue { statusText(cacheIssue) }
            }
        }
    }

    private func playerRow(_ row: CachedGroupRoster.Player) -> some View {
        let player = live?.players.first { $0.id == row.id }
        let canRename = player.map { live?.access.canRename($0) == true } ?? false
        let isOwner = live?.access.role == .owner
        return HStack(spacing: 8) {
            Text(row.displayName)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let player, canRename || isOwner {
                Menu {
                    if canRename {
                        Button("Rename", systemImage: "pencil") {
                            actionIssue = nil
                            renameName = player.displayName
                            renaming = player
                        }
                    }
                    if isOwner {
                        if row.isRetired {
                            Button("Restore", systemImage: "arrow.uturn.backward") {
                                Task { await perform(.setRetired(player, false)) }
                            }
                        } else {
                            Button("Retire", systemImage: "archivebox", role: .destructive) {
                                retiring = player
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Manage \(row.displayName)")
                .disabled(isSaving)
            }
        }
    }

    private func renameForm(_ original: GroupPlayerIdentity) -> some View {
        let current = live?.players.first { $0.id == original.id }
        let canRename = current.map { live?.access.canRename($0) == true } ?? false
        let conflict = nameConflict(renameName, excluding: original.id)
        return NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $renameName)
                        .textInputAutocapitalization(.words)
                        .disabled(isSaving)
                } footer: {
                    if let current, current.displayName != original.displayName {
                        Text("Current name: \(current.displayName)")
                    }
                }
                if let conflict { statusText(conflict) }
                if let actionIssue { statusText(actionIssue) }
                if isSaving { ProgressView("Saving player…") }
                else if live == nil { statusText("Connect to iCloud and refresh to save your change.") }
                else if current == nil { statusText("This group player is no longer available.") }
                else if !canRename { statusText("You don’t have permission to rename this player.") }
                if live == nil && canConnect && !isSaving && refreshID == nil {
                    Button("Refresh Players") { Task { await reload() } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("Rename Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        renaming = nil
                        actionIssue = nil
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let current else { return }
                        Task {
                            await perform(.rename(current, renameName)) { renaming = nil }
                        }
                    }
                    .disabled(!canRename || isSaving || conflict != nil ||
                              PlayerName.trimmed(renameName).isEmpty ||
                              PlayerName.trimmed(renameName) == current?.displayName)
                }
            }
        }
        .interactiveDismissDisabled(isSaving || renameName != original.displayName)
    }

    private func statusText(_ message: String) -> some View {
        Text(message).font(.footnote).foregroundStyle(.secondary)
    }

    private func nameConflict(_ name: String, excluding id: UUID) -> String? {
        let key = PlayerName.comparisonKey(name)
        guard !key.isEmpty, let match = saved?.players.first(where: {
            $0.id != id && PlayerName.comparisonKey($0.displayName) == key
        }) else { return nil }
        return match.isRetired
            ? "A retired player in this group already has that name."
            : "An active player in this group already has that name."
    }

    private func addPlayer() {
        guard canAdd, addConflict == nil, !PlayerName.trimmed(addName).isEmpty else { return }
        let draft = GroupPlayerDraft(id: addID, displayName: addName)
        Task {
            await perform(.add(draft)) {
                addName = ""
                addID = UUID()
            }
        }
    }

    private func reload() async {
        guard !Task.isCancelled else { return }
        loaded = nil
        let request = UUID()
        refreshID = nil
        guard canConnect else { return }
        let session = model.accountGeneration
        refreshID = request
        loadIssue = nil
        defer { if refreshID == request { refreshID = nil } }
        do {
            let contents = try await model.loadRoster(for: group)
            guard refreshID == request, canConnect, session == model.accountGeneration, !Task.isCancelled else { return }
            loaded = contents
            loadedSession = session
            // A refresh can confirm an add whose response was lost.
            if let savedDraft = contents.players.first(where: { $0.id == addID }) {
                if PlayerName.trimmed(addName) == savedDraft.displayName {
                    addName = ""
                    actionIssue = nil
                } else {
                    actionIssue = "Your earlier player was saved as \(savedDraft.displayName)."
                }
                addID = UUID()
            }
        } catch is CancellationError {
            return
        } catch {
            guard refreshID == request, session == model.accountGeneration, !Task.isCancelled else { return }
            loadIssue = GroupsModel.message(for: error)
        }
    }

    private func perform(_ change: GroupRosterChange, onSave: () -> Void = {}) async {
        guard live != nil, !isSaving else { return }
        let session = model.accountGeneration
        isSaving = true
        actionIssue = nil
        defer { isSaving = false }
        do {
            try await model.changeRoster(change, in: group, session: session)
            guard session == model.accountGeneration else { return }
            onSave()
        } catch {
            guard session == model.accountGeneration else { return }
            actionIssue = GroupsModel.message(for: error)
        }
        await reload()
    }

    private struct RefreshContext: Equatable {
        let canConnect: Bool
        let session: UUID
    }
}

private struct GroupPersonalPlayerCopyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.personalDeletionTargets) private var deletionTargets
    @Query(sort: \PlayerProfile.name) private var storedPlayers: [PlayerProfile]
    @State private var selectedID: UUID?
    @State private var draft: GroupPlayerDraft?

    let canCopy: Bool
    let isSaving: Bool
    let issue: String?
    let conflict: (String, UUID) -> String?
    let copy: (GroupPlayerDraft) async -> Void

    private var players: [PlayerProfile] { storedPlayers.filter { !deletionTargets.players.contains($0.id) } }
    private var duplicate: String? { draft.flatMap { conflict($0.displayName, $0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if players.isEmpty {
                        Text("No personal players").foregroundStyle(.secondary)
                    } else {
                        ForEach(PlayerProfile.orderedActivePlayers(players)) { player in
                            personalPlayerRow(player)
                        }
                    }
                } footer: {
                    Text("Copies the name to this group. The personal player and their scores stay in your personal history.")
                }
                let retiredPlayers = players.filter(\.isRetired)
                if !retiredPlayers.isEmpty {
                    Section {
                        DisclosureGroup("Retired Personal Players") {
                            ForEach(retiredPlayers) { player in personalPlayerRow(player) }
                        }
                    }
                }
                if isSaving { ProgressView("Copying player…") }
                if let duplicate { Text(duplicate).foregroundStyle(.secondary) }
                else if let issue { Text(issue).foregroundStyle(.secondary) }
                if !canCopy && !isSaving {
                    Text("Connect to iCloud to copy a player.").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("Copy Personal Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy") {
                        guard let draft else { return }
                        Task { await copy(draft) }
                    }
                    .disabled(!canCopy || isSaving || draft == nil || duplicate != nil ||
                              !players.contains(where: { $0.id == selectedID }))
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func personalPlayerRow(_ player: PlayerProfile) -> some View {
        Button {
            guard selectedID != player.id else { return }
            selectedID = player.id
            draft = GroupPlayerDraft(id: UUID(), displayName: player.name)
        } label: {
            HStack {
                Text(player.name).foregroundStyle(.primary)
                Spacer()
                if selectedID == player.id { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(selectedID == player.id ? .isSelected : [])
        .disabled(isSaving)
    }
}
#endif
