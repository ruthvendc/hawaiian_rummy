import SwiftUI
import SwiftData

struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @State private var newName = ""
    @State private var editingPlayer: PlayerProfile?
    @State private var playerToRemove: PlayerProfile?
    @State private var rename = ""

    private var activePlayers: [PlayerProfile] { players.filter { !$0.isRetired } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SectionIntroCard(
                        title: "Players",
                        subtitle: "\(activePlayers.count) saved \(activePlayers.count == 1 ? "player" : "players")",
                        icon: "person.2.fill"
                    )
                    .listRowBackground(Color.clear)
                }
                Section("Add Player") {
                    HStack {
                        TextField("Name", text: $newName)
                            .textInputAutocapitalization(.words)
                        Button("Add") {
                            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            context.insert(PlayerProfile(name: name))
                            try? context.save()
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Saved Players") {
                    ForEach(activePlayers) { playerRow($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 6, for: .scrollContent)
            .listSectionSpacing(10)
            .background(Color.softPurpleBackground)
            .navigationTitle("Players")
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    @ViewBuilder private func playerRow(_ player: PlayerProfile) -> some View {
        HStack {
            Text(player.name)
            Spacer()
            Button("Rename") { editingPlayer = player; rename = player.name }
                .buttonStyle(.borderless)
            Button("Remove", role: .destructive) { playerToRemove = player }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(player.name)")
        }
    }
}
