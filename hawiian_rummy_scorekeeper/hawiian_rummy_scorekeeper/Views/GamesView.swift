import SwiftUI
import SwiftData

struct GamesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Game.createdAt, order: .reverse) private var games: [Game]
    @State private var gameToDelete: Game?

    private var completedCount: Int { games.filter(\.isComplete).count }
    private var activeCount: Int { games.count - completedCount }

    private func summary(for game: Game) -> String {
        let playerCount = game.players.count
        let playersLabel = "\(playerCount) \(playerCount == 1 ? "player" : "players")"
        guard let completedAt = game.completedAt else { return "\(playersLabel) · In progress" }

        let totalMinutes = max(0, Int(completedAt.timeIntervalSince(game.createdAt) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let duration: String
        if hours > 0 {
            duration = "\(hours) \(hours == 1 ? "hr" : "hrs") \(minutes) \(minutes == 1 ? "min" : "mins")"
        } else if totalMinutes > 0 {
            duration = "\(totalMinutes) \(totalMinutes == 1 ? "min" : "mins")"
        } else {
            duration = "Less than 1 min"
        }
        return "\(playersLabel) · Completed · \(duration)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SectionIntroCard(
                        title: "Game History",
                        subtitle: "\(completedCount) completed · \(activeCount) in progress",
                        icon: "rectangle.stack.fill"
                    )
                    .listRowBackground(Color.clear)
                }
                if games.isEmpty {
                    ContentUnavailableView("No games yet", systemImage: "rectangle.stack", description: Text("Start a game from Home when your table is ready."))
                }
                ForEach(games) { game in
                    NavigationLink(value: game) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.title).font(.headline)
                            Text(summary(for: game))
                                .foregroundStyle(.secondary)
                            if game.title == "Family Game" {
                                Text(game.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { gameToDelete = game }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 6, for: .scrollContent)
            .listSectionSpacing(10)
            .background(Color.softPurpleBackground)
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: Game.self) { GameDetailView(game: $0) }
            .alert("Delete this game?", isPresented: Binding(get: { gameToDelete != nil }, set: { if !$0 { gameToDelete = nil } })) {
                Button("Cancel", role: .cancel) { gameToDelete = nil }
                Button("Delete Game", role: .destructive) {
                    if let gameToDelete {
                        context.delete(gameToDelete)
                        try? context.save()
                    }
                    gameToDelete = nil
                }
            } message: {
                Text("This permanently removes the game, its rounds, and its scores. Lifetime rankings will update automatically.")
            }
        }
    }
}
