import SwiftUI
import SwiftData
#if DEBUG
import CloudKit
import Network

extension GroupsModel {
    static let shared = GroupsModel(containerIdentifier: hawiian_rummy_scorekeeperApp.cloudKitContainerID)
}
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var gameNight = GameNightCoordinator()
    @State private var isShowingWelcome = true
    #if DEBUG
    @State private var groups = GroupsModel.shared
    @State private var selectedTab = 0
    private var shouldPollInvitations: Bool {
        scenePhase == .active && selectedTab == 4 && groups.hasPollableInvitations
    }
    #endif

    var body: some View {
        Group {
            if isShowingWelcome {
                WelcomeView(isPresented: $isShowingWelcome)
            } else {
                #if DEBUG
                MainTabView(groups: groups, selectedTab: $selectedTab)
                #else
                MainTabView()
                #endif
            }
        }
        .tint(.grammyPurple)
        .environmentObject(gameNight)
        .onAppear {
            gameNight.setSceneActive(scenePhase == .active)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            gameNight.setSceneActive(phase == .active)
            #if DEBUG
            if phase == .active { Task { await groups.refresh() } }
            #endif
        }
        #if DEBUG
        .task {
            let monitor = NWPathMonitor()
            for await path in monitor {
                groups.updateDiscoveryPath(available: path.status == .satisfied)
                Task { await groups.refresh() }
            }
        }
        .task(id: shouldPollInvitations) {
            guard shouldPollInvitations else { return }
            var delay = 8
            while !Task.isCancelled && shouldPollInvitations {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard !Task.isCancelled && shouldPollInvitations else { return }
                await groups.pollPendingInvitations()
                delay = min(delay * 2, 60)
            }
        }
        .onChange(of: groups.invitationRoute, initial: true) {
            if groups.nativeInvitation != nil {
                isShowingWelcome = false
                selectedTab = 4
                if scenePhase == .active { Task { await groups.refresh() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task { await groups.accountDidChange() }
        }
        #endif
    }
}

private struct MainTabView: View {
    #if DEBUG
    let groups: GroupsModel
    @Binding var selectedTab: Int
    #else
    @State private var selectedTab = 0
    #endif

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            GamesView()
                .tabItem { Label("Games", systemImage: "rectangle.stack.fill") }
                .tag(1)
            PlayersView()
                .tabItem { Label("Players", systemImage: "person.2.fill") }
                .tag(2)
            LifetimeLeaderboardView()
                .tabItem { Label("Records", systemImage: "trophy.fill") }
                .tag(3)
            #if DEBUG
            GroupsView(model: groups)
                .tabItem { Label("Groups", systemImage: "person.3.fill") }
                .tag(4)
            #else
            NavigationStack { RulesView() }
                .tabItem { Label("Rules", systemImage: "book.closed.fill") }
                .tag(4)
            #endif
        }
        .toolbarBackground(Color.softPurpleBackground, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [PlayerProfile.self, Game.self, GameRound.self, RoundParticipant.self,
                              LevelResult.self, ScoreEntry.self, PersonalDeletionReceipt.self], inMemory: true)
}
