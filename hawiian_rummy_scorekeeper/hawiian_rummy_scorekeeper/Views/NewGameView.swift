import SwiftUI
import SwiftData

struct NewGameView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @State private var selectedIDs: [UUID] = []
    @State private var title = "Family Game"
    let onStart: (Game) -> Void

    private var availablePlayers: [PlayerProfile] { players.filter { !$0.isRetired } }
    private var selection: [PlayerProfile] {
        selectedIDs.compactMap { selectedID in
            availablePlayers.first { $0.id == selectedID }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") { TextField("Game name", text: $title) }
                Section("Players") {
                    Text("Tap players in the order you want to keep score. The roster stays fixed for this game.")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    if availablePlayers.isEmpty {
                        Text("Add players in the Players tab first.").foregroundStyle(.secondary)
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
