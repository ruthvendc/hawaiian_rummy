import SwiftUI
import SwiftData

struct NewGameView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @State private var selectedIDs = Set<UUID>()
    @State private var title = "Family Game"
    let onStart: (Game) -> Void

    private var availablePlayers: [PlayerProfile] { players.filter { !$0.isRetired } }
    private var selection: [PlayerProfile] { availablePlayers.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") { TextField("Game name", text: $title) }
                Section("Players") {
                    Text("Choose at least two players. The roster stays fixed for this game.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    if availablePlayers.isEmpty {
                        Text("Add players in the Players tab first.").foregroundStyle(.secondary)
                    }
                    ForEach(availablePlayers) { player in
                        Toggle(player.name, isOn: Binding(
                            get: { selectedIDs.contains(player.id) },
                            set: { selected in
                                if selected {
                                    selectedIDs.insert(player.id)
                                } else {
                                    selectedIDs.remove(player.id)
                                }
                            }
                        ))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("New Game")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let game = Game(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Family Game" : title, players: selection)
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
}
