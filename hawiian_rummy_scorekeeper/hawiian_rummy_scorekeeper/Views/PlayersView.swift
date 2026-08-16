import SwiftUI
import SwiftData

struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @State private var newName = ""
    @State private var editingPlayer: PlayerProfile?
    @State private var playerToRemove: PlayerProfile?
    @State private var rename = ""
    @State private var lastAddedPlayerName: String?
    @State private var hasAddedPlayerThisVisit = false
    @FocusState private var isNameFieldFocused: Bool

    private var activePlayers: [PlayerProfile] { players.filter { !$0.isRetired } }
    private var trimmedNewName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDuplicateNewName: Bool {
        activePlayers.contains { player in
            player.name.compare(trimmedNewName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

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
                            .focused($isNameFieldFocused)
                            .onSubmit(addPlayer)
                            .accessibilityLabel("New player name")
                        Button(action: addPlayer) {
                            Text("Add Player")
                        }
                        .disabled(trimmedNewName.isEmpty || hasDuplicateNewName)
                        .accessibilityHint("Saves this player and lets you add another name")
                    }
                    if hasDuplicateNewName {
                        Label("That player is already in your list.", systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Duplicate player name. That player is already in your list.")
                    }
                    if let lastAddedPlayerName {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Added \(lastAddedPlayerName)", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.grammyPurple)
                            Text("Add another player or tap Done Adding Players.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    doneAddingButton
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

    private func addPlayer() {
        guard !trimmedNewName.isEmpty, !hasDuplicateNewName else { return }
        context.insert(PlayerProfile(name: trimmedNewName))
        try? context.save()
        lastAddedPlayerName = trimmedNewName
        hasAddedPlayerThisVisit = true
        newName = ""
        isNameFieldFocused = true
    }

    @ViewBuilder private var doneAddingButton: some View {
        let button = Button {
            isNameFieldFocused = false
            lastAddedPlayerName = nil
            hasAddedPlayerThisVisit = false
        } label: {
            Text("Done Adding Players")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityHint("Dismisses the keyboard so you can review your saved players")

        if hasAddedPlayerThisVisit {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
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
