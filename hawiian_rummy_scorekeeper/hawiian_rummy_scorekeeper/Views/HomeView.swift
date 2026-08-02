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
            .background {
                ZStack {
                    Color.softPurpleBackground
                    HomeCardBackground()
                }
            }
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

private struct HomeCardBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HomeDecorativeCard(suit: "suit.diamond.fill", tint: .warmGold)
                    .rotationEffect(.degrees(-18))
                    .position(x: 66, y: proxy.size.height * 0.67)
                HomeDecorativeCard(suit: "suit.spade.fill", tint: .grammyPurple)
                    .rotationEffect(.degrees(21))
                    .position(x: proxy.size.width - 56, y: proxy.size.height * 0.56)
                HomeDecorativeCard(suit: "suit.heart.fill", tint: .warmGold)
                    .rotationEffect(.degrees(15))
                    .position(x: 60, y: proxy.size.height * 0.89)
                HomeDecorativeCard(suit: "suit.club.fill", tint: .grammyPurple)
                    .rotationEffect(.degrees(-22))
                    .position(x: proxy.size.width - 60, y: proxy.size.height * 0.83)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HomeDecorativeCard: View {
    let suit: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(Color.grammyDecorativeSurface)
            .frame(width: 92, height: 126)
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.grammyLavender.opacity(0.42), lineWidth: 1)
            }
            .overlay {
                Image(systemName: suit)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(tint.opacity(0.48))
            }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }
}
