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
    @ScaledMetric(relativeTo: .body) private var selectionBadgeSize: CGFloat = 34
    let onStart: (Game) -> Void

    private var availablePlayers: [PlayerProfile] { PlayerProfile.orderedActivePlayers(players) }
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
                    Text("Optional: Tap to rename this game.")
                }
                Section("Select Players") {
                    Text("Select players in scoring order.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    if availablePlayers.isEmpty {
                        Text("Players you add below will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availablePlayers) { player in
                        let position = selectedIDs.firstIndex(of: player.id)
                        HStack {
                            ZStack {
                                if let position {
                                    Circle()
                                        .fill(Color.grammyLavender)
                                    Text("\(position + 1)")
                                        .font(.subheadline.weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(Color.grammyPurple)
                                        .accessibilityLabel("Score entry position \(position + 1)")
                                }
                            }
                            .frame(width: selectionBadgeSize, height: selectionBadgeSize)
                            Text(player.name)
                            Spacer()
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
                            .foregroundStyle(canAddPlayer ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAddPlayer)
                    .listRowSeparator(.hidden)
                    if hasDuplicateNewName {
                        Text("That player is already in your list. Select them above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .listSectionSpacing(10)
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
                    Button {
                        let trimmedTitle = (customTitle ?? suggestedTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                        let game = Game(title: trimmedTitle.isEmpty ? suggestedTitle : trimmedTitle, players: selection)
                        context.insert(game)
                        _ = GameRules.createRound(in: game)
                        try? context.save()
                        onStart(game)
                    } label: {
                        Text("Start Game")
                            .foregroundStyle(selection.count < 2 ? Color.primary : Color.accentColor)
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
