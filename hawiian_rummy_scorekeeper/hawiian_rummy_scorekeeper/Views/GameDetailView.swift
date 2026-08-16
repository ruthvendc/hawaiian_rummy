import SwiftUI
import SwiftData

struct GameDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gameNight = GameNightCoordinator()
    @State private var scoreLevel = 1
    @State private var showingScoreEntry = false
    @State private var showEndConfirmation = false
    @State private var showingRename = false
    @State private var renamedTitle = ""
    let game: Game

    /// The latest round remains the active dashboard until the family starts another
    /// round or ends the game. A completed round therefore still needs its decision UI.
    private var currentRound: GameRound? { game.sortedRounds.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if game.isComplete {
                    GameFinalView(game: game)
                } else if let round = currentRound {
                    activeContent(round)
                }
            }
            .padding()
        }
        .background(Color.softPurpleBackground)
        .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename") {
                    renamedTitle = game.title
                    showingRename = true
                }
            }
        }
        .sheet(isPresented: $showingScoreEntry) {
            if let currentRound { ScoreEntryView(round: currentRound, levelNumber: scoreLevel) }
        }
        .alert("Rename Game", isPresented: $showingRename) {
            TextField("Game name", text: $renamedTitle)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let title = renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                game.title = title
                try? context.save()
            }
            .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("End this game?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
            Button("End Game", role: .destructive) {
                game.completedAt = .now
                gameNight.deactivate()
                try? context.save()
            }
        } message: { Text("Saved scores, including any levels entered in the current round, will count in the final standings.") }
        .onChange(of: scenePhase) { _, phase in if phase != .active { gameNight.deactivate() } }
        .onDisappear { gameNight.deactivate() }
    }

    @ViewBuilder private func activeContent(_ round: GameRound) -> some View {
        Toggle(isOn: $gameNight.isEnabled) {
            Label("Keep Screen On", systemImage: "display")
                .font(.headline)
        }
        .accessibilityHint("Prevents your phone from locking while this game is active.")
        .padding()
        .background(Color.grammyLavender.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        if round.isComplete {
            RoundCompletionView(game: game, round: round, endGame: { showEndConfirmation = true })
        } else {
            let nextLevel = round.levels.count + 1
            let definition = LevelDefinition.definition(for: nextLevel)
            LevelMissionCard(roundNumber: round.number, handNumber: nextLevel, definition: definition)
            if nextLevel == 7 {
                Text("“This separates the wheat from the chaff”")
                    .font(.headline.italic()).padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.warmGold.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
            }
            Button { scoreLevel = nextLevel; showingScoreEntry = true } label: { Label("Enter Scores", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            standingsCard(round)
            if let previous = round.levels.map(\.levelNumber).max() {
                Button("Edit Previous Level") { scoreLevel = previous; showingScoreEntry = true }
                    .frame(maxWidth: .infinity).buttonStyle(.bordered)
            }
            Button("End Game", role: .destructive) { showEndConfirmation = true }
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
                .padding(.top, 20)
        }
    }

    private func standingsCard(_ round: GameRound) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Round").font(.headline)
            Text("Round scores start at zero. Lower is better.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(GameRules.standings(for: round)) { standing in
                HStack {
                    Text("\(standing.rank). \(standing.participant.displayName)")
                    Spacer()
                    if standing.isLeader { LeaderBadge() }
                    Text("\(standing.total)").font(.title3.monospacedDigit().bold())
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LevelMissionCard: View {
    let roundNumber: Int
    let handNumber: Int
    let definition: LevelDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ROUND \(roundNumber) · HAND \(handNumber)")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(Color.grammyPurple)
                Spacer()
                Image(systemName: "suit.spade.fill")
                    .foregroundStyle(Color.grammyPurple.opacity(0.7))
            }
            Divider().overlay(Color.grammyPurple.opacity(0.25))
            Text("Objective")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(definition.goal)
                .font(.title.bold())
                .foregroundStyle(.primary)
            Label("\(definition.cards) Cards", systemImage: "rectangle.on.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.grammyPurple)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.grammyLavender.opacity(0.65), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.grammySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.grammyPurple.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Round \(roundNumber), hand \(handNumber). Objective: \(definition.goal). \(definition.cards) cards.")
    }
}

private struct RoundCompletionView: View {
    @Environment(\.modelContext) private var context
    let game: Game
    let round: GameRound
    let endGame: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Round \(round.number) complete!").font(.title.bold())
            Text("The round is in the books. Would you like to keep playing?").foregroundStyle(.secondary)
            Button { _ = GameRules.createRound(in: game); try? context.save() } label: {
                Label("Play Another Round", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button("End Game", role: .destructive, action: endGame)
                .frame(maxWidth: .infinity).buttonStyle(.bordered)
            RoundResultsView(round: round)
            OverallStandingsView(game: game, title: "Overall Through Round \(round.number)")
        }
    }
}
