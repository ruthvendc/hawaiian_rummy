import SwiftUI
import SwiftData

struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var storedPlayers: [PlayerProfile]
    @Environment(\.personalDeletionTargets) private var deletionTargets
    @Environment(\.personalDeletionIssue) private var deletionIssue
    @State private var newName = ""
    @State private var editingPlayer: PlayerProfile?
    @State private var playerToRemove: PlayerProfile?
    @State private var rename = ""
    @State private var showingOrderSaveError = false
    @State private var playerIssue: String?
    @State private var restoreScope: RestorePlayersView.Scope?
    @State private var editMode: EditMode = .inactive
    @State private var orderedPlayerIDs: [UUID] = []
    @FocusState private var isNameFieldFocused: Bool

    private var players: [PlayerProfile] { storedPlayers.filter { !deletionTargets.players.contains($0.id) } }
    private var activePlayers: [PlayerProfile] {
        PlayerProfile.orderedActivePlayers(players)
    }
    private var isEditingOrder: Bool { editMode.isEditing }
    private var displayedPlayers: [PlayerProfile] {
        guard isEditingOrder else { return activePlayers }
        return orderedPlayerIDs.compactMap { id in activePlayers.first { $0.id == id } }
    }
    private var newNameStatus: PersonalPlayers.NameStatus { PersonalPlayers.nameStatus(for: newName, in: players) }
    private var canAddPlayer: Bool { newNameStatus == .available || newNameStatus == .retiredMatch }

    var body: some View {
        NavigationStack {
            List {
                introSection
                if let deletionIssue {
                    Text(deletionIssue).font(.footnote).foregroundStyle(.secondary)
                }
                addPlayerSection
                savedPlayersSection
            }
            .environment(\.editMode, $editMode)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, 6, for: .scrollContent)
            .listSectionSpacing(10)
            .background(Color.softPurpleBackground)
            .navigationTitle("Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .alert("Couldn't save player order", isPresented: $showingOrderSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please try tapping Done again.")
            }
            .alert("Couldn't save player", isPresented: Binding(
                get: { playerIssue != nil }, set: { if !$0 { playerIssue = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(playerIssue ?? "")
            }
            .alert("Rename Player", isPresented: Binding(get: { editingPlayer != nil }, set: { if !$0 { editingPlayer = nil } })) {
                TextField("Name", text: $rename)
                Button("Cancel", role: .cancel) { editingPlayer = nil }
                Button("Save") {
                    guard let player = editingPlayer else { return }
                    editingPlayer = nil
                    updatePlayer { try PersonalPlayers.rename(player, to: rename, in: context) }
                }
            }
            .alert("Remove this player?", isPresented: Binding(get: { playerToRemove != nil }, set: { if !$0 { playerToRemove = nil } })) {
                Button("Cancel", role: .cancel) { playerToRemove = nil }
                Button("Remove", role: .destructive) {
                    guard let player = playerToRemove else { return }
                    playerToRemove = nil
                    updatePlayer { try PersonalPlayers.retire(player, in: context) }
                }
            } message: {
                Text("They will no longer appear when starting a new game, but their existing scorecards will stay intact.")
            }
            .sheet(item: $restoreScope) { scope in
                RestorePlayersView(scope: scope) { _ in
                    if case .matching = scope { newName = "" }
                }
            }
        }
    }

    private var introSection: some View {
        Section {
            SectionIntroCard(
                title: "Players",
                subtitle: "\(activePlayers.count) saved \(activePlayers.count == 1 ? "player" : "players")",
                icon: "person.2.fill"
            )
            .listRowBackground(Color.clear)
        }
    }

    private var addPlayerSection: some View {
        Section("Add Player") {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Enter New Player Name", text: $newName)
                    .textInputAutocapitalization(.words)
                    .focused($isNameFieldFocused)
                    .onSubmit(addPlayer)
                    .accessibilityLabel("New player name")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button(action: addPlayer) {
                    Text(newNameStatus == .retiredMatch ? "Restore Player" : "Add Player")
                        .foregroundStyle(canAddPlayer ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAddPlayer)
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
            .listRowSeparator(.hidden)
            if newNameStatus == .activeMatch {
                Text("That player is already in your list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if newNameStatus == .retiredMatch {
                Text("A removed player already has this name. You can restore their profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var savedPlayersSection: some View {
        let conflicts = PersonalPlayers.conflictingNames(in: players)
        return Section {
            ForEach(displayedPlayers) { player in
                playerRow(player, hasNameConflict: conflicts.contains(PersonalPlayers.nameKey(player.name)))
            }
                .onMove(perform: movePlayers)
            if !isEditingOrder {
                Button("Restore Players", systemImage: "arrow.uturn.backward") {
                    isNameFieldFocused = false
                    restoreScope = .all
                }
                .frame(minHeight: 44)
            }
        } header: {
            HStack {
                Text("Saved Players")
                Spacer()
                Button(isEditingOrder ? "Done" : "Edit Order") {
                    if isEditingOrder {
                        savePlayerOrder()
                    } else {
                        orderedPlayerIDs = activePlayers.map(\.id)
                        isNameFieldFocused = false
                        editMode = .active
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.grammyPurple)
                .textCase(nil)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .disabled(activePlayers.count < 2 && !isEditingOrder)
            }
        } footer: {
            if !conflicts.isEmpty {
                Text("Some profiles share a name. Review their dates and game counts before renaming or restoring one.")
            }
        }
    }

    private func addPlayer() {
        guard newNameStatus != .empty else { return }
        do {
            let player = try PersonalPlayers.add(newName, in: context)
            if isEditingOrder { orderedPlayerIDs.append(player.id) }
            newName = ""
            isNameFieldFocused = true
        } catch PersonalPlayers.Issue.retiredName {
            isNameFieldFocused = false
            restoreScope = .matching(PersonalPlayers.nameKey(newName))
        } catch {
            showPlayerIssue(error)
        }
    }

    private func updatePlayer(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            showPlayerIssue(error)
        }
    }

    private func showPlayerIssue(_ error: Error) {
        playerIssue = (error as? PersonalPlayers.Issue)?.errorDescription ?? "Your change wasn’t saved. Please try again."
    }

    private func movePlayers(from source: IndexSet, to destination: Int) {
        guard isEditingOrder else { return }
        orderedPlayerIDs.move(fromOffsets: source, toOffset: destination)
    }

    private func savePlayerOrder() {
        let previousOrder = activePlayers.map { ($0, $0.displayOrder) }
        for (index, id) in orderedPlayerIDs.enumerated() {
            activePlayers.first { $0.id == id }?.displayOrder = index
        }
        do {
            try context.save()
            editMode = .inactive
        } catch {
            for (player, order) in previousOrder { player.displayOrder = order }
            showingOrderSaveError = true
        }
    }

    private func playerRow(_ player: PlayerProfile, hasNameConflict: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.name)
                if hasNameConflict { PlayerProfileHistoryLabel(player: player) }
            }
            Spacer(minLength: 8)
            if !isEditingOrder {
                Menu {
                    Button {
                        editingPlayer = player
                        rename = player.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        playerToRemove = player
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.grammyPurple)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Manage \(player.name)")
            }
        }
    }
}
