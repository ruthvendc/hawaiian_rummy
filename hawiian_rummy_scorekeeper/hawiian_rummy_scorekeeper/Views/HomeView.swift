import SwiftUI
import SwiftData

struct HomeView: View {
    @Query(sort: \Game.createdAt, order: .reverse) private var games: [Game]
    @State private var showingNewGame = false
    @State private var gameToOpen: Game?

    private var activeGame: Game? { games.first { !$0.isComplete } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Hawaiian Rummy Scorekeeper")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    if let game = activeGame {
                        NavigationLink(value: game) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Game in progress", systemImage: "play.circle.fill")
                                    .font(.headline)
                                Text(game.title).font(.title3.bold())
                                Text("Round \(game.rounds.count) · \(game.players.count) players")
                                    .foregroundStyle(.secondary)
                                Text("Resume Game")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.grammyLavender.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                    } else {
                        ContentUnavailableView("Ready to Play?", systemImage: "suit.club.fill")
                    }
                    Button { showingNewGame = true } label: {
                        Label("Start a New Game", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
            .background(Color.softPurpleBackground)
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: Game.self) { GameDetailView(game: $0) }
            .navigationDestination(item: $gameToOpen) { GameDetailView(game: $0) }
            .sheet(isPresented: $showingNewGame) {
                NewGameView { game in
                    showingNewGame = false
                    gameToOpen = game
                }
            }
        }
    }
}
