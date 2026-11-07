import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gameNight = GameNightCoordinator()
    @State private var isShowingWelcome = true

    var body: some View {
        Group {
            if isShowingWelcome {
                WelcomeView(isPresented: $isShowingWelcome)
            } else {
                MainTabView()
            }
        }
        .tint(.grammyPurple)
        .environmentObject(gameNight)
        .onAppear {
            gameNight.setSceneActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            gameNight.setSceneActive(phase == .active)
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            GamesView()
                .tabItem { Label("Games", systemImage: "rectangle.stack.fill") }
            PlayersView()
                .tabItem { Label("Players", systemImage: "person.2.fill") }
            LifetimeLeaderboardView()
                .tabItem { Label("Records", systemImage: "trophy.fill") }
            RulesView()
                .tabItem { Label("Rules", systemImage: "book.closed.fill") }
        }
        .toolbarBackground(Color.softPurpleBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [PlayerProfile.self, Game.self, GameRound.self, RoundParticipant.self, LevelResult.self, ScoreEntry.self], inMemory: true)
}
