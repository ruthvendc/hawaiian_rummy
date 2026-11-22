import SwiftUI
import SwiftData

struct NewGameView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \PlayerProfile.name) private var storedPlayers: [PlayerProfile]
    @Environment(\.personalDeletionTargets) private var deletionTargets
    @Query(sort: \Game.createdAt, order: .reverse) private var games: [Game]
    @State private var selectedIDs: [UUID] = []
    @State private var newPlayerName = ""
    @State private var customTitle: String?
    @State private var playerIssue: String?
    @State private var restoreScope: RestorePlayersView.Scope?
    @State private var showingGameSaveError = false
    @FocusState private var isNameFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var selectionBadgeSize: CGFloat = 34
    let onStart: (Game) -> Void
    #if DEBUG
    var onStartGroup: (GroupGameRoute) -> Void = { _ in }
    @State private var scope = Scope.personal
    @State private var groupSetup = GroupGameSetup(groups: .shared)

    private enum Scope { case personal, group }
    #endif

    private var players: [PlayerProfile] { storedPlayers.filter { !deletionTargets.players.contains($0.id) } }
    private var availablePlayers: [PlayerProfile] { PlayerProfile.orderedActivePlayers(players) }
    private var newNameStatus: PersonalPlayers.NameStatus {
        PersonalPlayers.nameStatus(for: newPlayerName, in: players)
    }
    private var canAddPlayer: Bool { newNameStatus == .available || newNameStatus == .retiredMatch }
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
                #if DEBUG
                Section("Game Type") {
                    Picker("Game Type", selection: $scope) {
                        Text("Personal Game").tag(Scope.personal)
                        Text("Group Game").tag(Scope.group)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!groupSetup.canEditSelection)
                }
                if scope == .group {
                    GroupGameSetupFields(setup: groupSetup)
                } else {
                    personalSections
                }
                #else
                personalSections
                #endif
            }
            .scrollContentBackground(.hidden)
            .listSectionSpacing(10)
            .background(Color.softPurpleBackground)
            .navigationTitle("New Game")
            .alert("Couldn't save player", isPresented: Binding(
                get: { playerIssue != nil }, set: { if !$0 { playerIssue = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(playerIssue ?? "")
            }
            .alert("Couldn't start game", isPresented: $showingGameSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("The game wasn't saved. Please try again.")
            }
            .sheet(item: $restoreScope) { scope in
                RestorePlayersView(scope: scope) { player in
                    if !selectedIDs.contains(player.id) { selectedIDs.append(player.id) }
                    newPlayerName = ""
                }
            }
            #if DEBUG
            .interactiveDismissDisabled(groupSetup.isSaving)
            .onChange(of: groupSetup.groups.account) { previous, _ in
                if previous != nil { groupSetup.accountChanged() }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isStartingGroup)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: startGame) {
                        Text("Start Game")
                            .foregroundStyle(canStart ? Color.accentColor : Color.primary)
                    }
                    .disabled(!canStart)
                }
            }
        }
    }

    @ViewBuilder
    private var personalSections: some View {
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
        Section {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Enter New Player Name", text: $newPlayerName)
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
                .accessibilityHint(newNameStatus == .retiredMatch
                    ? "Opens the matching removed profiles"
                    : "Saves and selects this player for the game")
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
            .listRowSeparator(.hidden)
            if newNameStatus == .activeMatch {
                Text("That player is already in your list. Select them above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if newNameStatus == .retiredMatch {
                Text("A removed player already has this name. You can restore their profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Add Player")
        } footer: {
            Text("You need at least two players to start.")
        }
    }

    private var canStart: Bool {
        #if DEBUG
        if scope == .group { return groupSetup.canStart }
        #endif
        return selection.count >= 2
    }

    private var isStartingGroup: Bool {
        #if DEBUG
        return groupSetup.isSaving
        #else
        return false
        #endif
    }

    private func startGame() {
        #if DEBUG
        if scope == .group {
            Task {
                if let game = await groupSetup.start() { onStartGroup(game) }
            }
            return
        }
        #endif
        let trimmedTitle = (customTitle ?? suggestedTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let game = Game(title: trimmedTitle.isEmpty ? suggestedTitle : trimmedTitle, players: selection)
        context.insert(game)
        _ = GameRules.createRound(in: game)
        do {
            try context.save()
            onStart(game)
        } catch {
            context.rollback()
            showingGameSaveError = true
        }
    }

    private func addPlayer() {
        guard newNameStatus != .empty else { return }
        do {
            let player = try PersonalPlayers.add(newPlayerName, in: context)
            selectedIDs.append(player.id)
            newPlayerName = ""
            isNameFieldFocused = true
        } catch PersonalPlayers.Issue.retiredName {
            isNameFieldFocused = false
            restoreScope = .matching(PersonalPlayers.nameKey(newPlayerName))
        } catch {
            playerIssue = (error as? PersonalPlayers.Issue)?.errorDescription ?? "Your change wasn’t saved. Please try again."
        }
    }
}
