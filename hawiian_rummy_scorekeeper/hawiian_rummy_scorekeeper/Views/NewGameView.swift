import SwiftUI
import SwiftData

struct NewGameView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @Query(sort: \Game.createdAt, order: .reverse) private var games: [Game]
    @State private var selectedIDs: [UUID] = []
    @State private var newPlayerName = ""
    @State private var customTitle: String?
    @State private var showingSaveError = false
    @FocusState private var isNameFieldFocused: Bool
    let onStart: (Game) -> Void

    private var availablePlayers: [PlayerProfile] { players.filter { !$0.isRetired } }
    private var trimmedNewPlayerName: String { newPlayerName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDuplicateNewName: Bool {
        availablePlayers.contains {
            $0.name.compare(trimmedNewPlayerName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
    private var canAddPlayer: Bool { !trimmedNewPlayerName.isEmpty && !hasDuplicateNewName }
    private var suggestedTitle: String {
        Game.nextDefaultTitle(for: .now, existingTitles: games.map(\.title))
    }
    private var titleBinding: Binding<String> {
        Binding(get: { customTitle ?? suggestedTitle }, set: { customTitle = $0 })
    }
    private var selection: [PlayerProfile] {
        selectedIDs.compactMap { selectedID in
            availablePlayers.first { $0.id == selectedID }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Game name", text: titleBinding)
                        .accessibilityLabel("Game name")
                } header: {
                    Text("Game")
                } footer: {
                    Text("The date is the default name. Tap above to give this game a different name.")
                }
                Section("Add New Players") {
                    Text("You need at least two players to start.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    TextField("Enter New Player Name", text: $newPlayerName)
                        .textInputAutocapitalization(.words)
                        .focused($isNameFieldFocused)
                        .onSubmit(addPlayer)
                        .accessibilityLabel("New player name")
                    Button(action: addPlayer) {
                        Text("Add Player")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAddPlayer)
                    .opacity(canAddPlayer ? 1 : 0.6)
                    .listRowSeparator(.hidden)
                    if hasDuplicateNewName {
                        Text("That player is already in your list. Select them below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Select Players") {
                    Text("Tap players in the order you want to keep score.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    if availablePlayers.isEmpty {
                        Text("Players you add above will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availablePlayers) { player in
                        HStack {
                            Text(player.name)
                            Spacer()
                            if let position = selectedIDs.firstIndex(of: player.id) {
                                Text("\(position + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.grammyPurple)
                                    .frame(width: 24, height: 24)
                                    .background(Color.grammyLavender, in: Circle())
                                    .accessibilityLabel("Score entry position \(position + 1)")
                            }
                            Toggle("Select \(player.name)", isOn: Binding(
                                get: { selectedIDs.contains(player.id) },
                            set: { selected in
                                if selected {
                                    selectedIDs.append(player.id)
                                } else {
                                    selectedIDs.removeAll { $0 == player.id }
                                }
                            }
                            ))
                            .labelsHidden()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("New Game")
            .alert("Couldn't save player", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please try adding this player again.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Game") {
                        let trimmedTitle = (customTitle ?? suggestedTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                        let game = Game(title: trimmedTitle.isEmpty ? suggestedTitle : trimmedTitle, players: selection)
                        context.insert(game)
                        _ = GameRules.createRound(in: game)
                        try? context.save()
                        onStart(game)
                    }
                    .disabled(selection.count < 2)
                }
            }
        }
    }

    private func addPlayer() {
        guard canAddPlayer else { return }
        let player = PlayerProfile(name: trimmedNewPlayerName)
        context.insert(player)
        do {
            try context.save()
            selectedIDs.append(player.id)
            newPlayerName = ""
            isNameFieldFocused = true
        } catch {
            context.delete(player)
            showingSaveError = true
        }
    }
}
