import SwiftUI
import SwiftData

struct GamesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Game.createdAt, order: .reverse) private var games: [Game]
    @State private var gameToDelete: Game?

    private var completedCount: Int { games.filter(\.isComplete).count }
    private var activeCount: Int { games.count - completedCount }

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
                            Text(game.isComplete ? "Completed · \(game.rounds.count) rounds" : "In progress · Round \(game.rounds.count)")
                                .foregroundStyle(.secondary)
                            Text(game.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
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
