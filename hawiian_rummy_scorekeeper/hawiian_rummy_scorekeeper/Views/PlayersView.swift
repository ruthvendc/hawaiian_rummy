import SwiftUI
import SwiftData

struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @State private var newName = ""
    @State private var editingPlayer: PlayerProfile?
    @State private var playerToRemove: PlayerProfile?
    @State private var rename = ""
    @State private var showingSaveError = false
    @State private var showingOrderSaveError = false
    @State private var editMode: EditMode = .inactive
    @State private var orderedPlayerIDs: [UUID] = []
    @FocusState private var isNameFieldFocused: Bool

    private var activePlayers: [PlayerProfile] {
        PlayerProfile.orderedActivePlayers(players)
    }
    private var isEditingOrder: Bool { editMode.isEditing }
    private var displayedPlayers: [PlayerProfile] {
        guard isEditingOrder else { return activePlayers }
        return orderedPlayerIDs.compactMap { id in activePlayers.first { $0.id == id } }
    }
    private var trimmedNewName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDuplicateNewName: Bool {
        activePlayers.contains { player in
            player.name.compare(trimmedNewName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
    private var canAddPlayer: Bool { !trimmedNewName.isEmpty && !hasDuplicateNewName }

    var body: some View {
        NavigationStack {
            List {
                introSection
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
            .alert("Couldn't save player", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please try adding this player again.")
            }
            .alert("Couldn't save player order", isPresented: $showingOrderSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please try tapping Done again.")
            }
            .alert("Rename Player", isPresented: Binding(get: { editingPlayer != nil }, set: { if !$0 { editingPlayer = nil } })) {
                TextField("Name", text: $rename)
                Button("Cancel", role: .cancel) { editingPlayer = nil }
                Button("Save") {
                    editingPlayer?.name = rename.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? context.save()
                    editingPlayer = nil
                }
            }
            .alert("Remove this player?", isPresented: Binding(get: { playerToRemove != nil }, set: { if !$0 { playerToRemove = nil } })) {
                Button("Cancel", role: .cancel) { playerToRemove = nil }
                Button("Remove", role: .destructive) {
                    playerToRemove?.retiredAt = .now
                    try? context.save()
                    playerToRemove = nil
                }
            } message: {
                Text("They will no longer appear when starting a new game, but their existing scorecards will stay intact.")
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
                    Text("Add Player")
                        .foregroundStyle(canAddPlayer ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAddPlayer)
                .accessibilityHint("Saves this player and lets you add another name")
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
            .listRowSeparator(.hidden)
            if hasDuplicateNewName {
                Text("That player is already in your list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var savedPlayersSection: some View {
        Section {
            ForEach(displayedPlayers) { playerRow($0) }
                .onMove(perform: movePlayers)
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
        }
    }

    private func addPlayer() {
        guard canAddPlayer else { return }
        let player = PlayerProfile(name: trimmedNewName)
        context.insert(player)
        do {
            try context.save()
            if isEditingOrder { orderedPlayerIDs.append(player.id) }
            newName = ""
            isNameFieldFocused = true
        } catch {
            context.delete(player)
            showingSaveError = true
        }
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

    @ViewBuilder private func playerRow(_ player: PlayerProfile) -> some View {
        HStack {
            Text(player.name)
                .lineLimit(1)
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
