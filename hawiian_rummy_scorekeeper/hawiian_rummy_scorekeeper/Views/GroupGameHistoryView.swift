#if DEBUG
import Network
import SwiftUI

struct GroupGameHistoryView: View {
    let group: GroupSummary
    let model: GroupsModel

    var body: some View {
        GroupGameReadScreen(group: group, model: model, title: "Games") {
            try await model.withSharedGroup(group) { repository, account in
                let games = try await repository.gameHistory(for: group, account: account)
                let names = games.isEmpty ? [:] : await repository.gameScorekeeperNames(for: group, account: account)
                return (games: games, scorekeepers: names)
            }
        } content: { history in
            if history.games.isEmpty {
                ContentUnavailableView("No Group Games", systemImage: "rectangle.stack",
                                       description: Text("Choose Group Game in New Game to start one."))
            } else {
                Section("Group Games") {
                    ForEach(history.games) { game in
                        NavigationLink {
                            GroupGameDetailView(route: GroupGameRoute(group: group, gameID: game.id), model: model)
                        } label: {
                            GroupGameSummary(header: game, scorekeeper: history.scorekeepers[game.scorekeeperKey])
                        }
                    }
                }
            }
        }
    }
}

struct GroupGameSummary: View {
    let header: GroupGameHeader
    let scorekeeper: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = header.createdAt {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
            } else {
                Text("Group Game").font(.headline)
            }
            Text(header.participants.map(\.displayName).formatted(.list(type: .and)))
            Text("Scorekeeper: \(scorekeeper ?? "Name unavailable")")
                .font(.subheadline).foregroundStyle(.secondary)
            Label(header.status.title, systemImage: header.status.icon)
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct GroupGameHandScores: View {
    let hand: GroupGameHand
    let participants: [GroupGameParticipant]

    var body: some View {
        DisclosureGroup("Hand \(hand.number)") {
            ForEach(participants, id: \.playerID) { player in
                if let score = hand.scores.first(where: { $0.playerID == player.playerID }) {
                    LabeledContent(player.displayName, value: String(score.points))
                }
            }
        }
    }
}

/// Keeps a readback in memory for the displayed account and group.
private struct GroupGameReadScreen<Value, Content: View>: View {
    let group: GroupSummary
    let model: GroupsModel
    let title: String
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewingAccount: String?
    @State private var hasPath: Bool?
    @State private var loaded: Value?
    @State private var issue: String?
    @State private var request: UUID?

    private var canView: Bool {
        viewingAccount != nil && viewingAccount == model.account && model.containsGroup(group)
    }
    private var canLoad: Bool { canView && hasPath == true && scenePhase == .active }

    init(
        group: GroupSummary, model: GroupsModel, title: String, load: @escaping () async throws -> Value,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.group = group
        self.model = model
        self.title = title
        self.load = load
        self.content = content
        _viewingAccount = State(initialValue: model.account)
    }

    var body: some View {
        List {
            if !canView {
                ContentUnavailableView("Group Unavailable", systemImage: "person.3")
            } else {
                Section {
                    SectionIntroCard(title: group.name, subtitle: "Group games",
                                     icon: "rectangle.stack")
                        .listRowBackground(Color.clear)
                }
                if request != nil || hasPath == nil {
                    ProgressView("Loading games…")
                }
                if hasPath == false {
                    Text(loaded == nil ? "Connect to iCloud to load group games." : "Offline. Showing the last loaded games.")
                        .foregroundStyle(.secondary)
                } else if let issue {
                    Text(issue).foregroundStyle(.secondary)
                    if loaded != nil { Text("Showing the last loaded games.").foregroundStyle(.secondary) }
                    Button("Refresh") { Task { await reload() } }.disabled(request != nil)
                }
                if let loaded { content(loaded) }
            }
        }
        .background(Color.softPurpleBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task {
            let monitor = NWPathMonitor()
            for await path in monitor { hasPath = path.status == .satisfied }
        }
        .task(id: LoadKey(available: canLoad, session: model.accountGeneration)) {
            await reload()
        }
        .onChange(of: canView) { _, visible in
            if !visible {
                loaded = nil
                issue = nil
                request = nil
            }
        }
    }

    private func reload() async {
        guard canLoad, !Task.isCancelled else { return }
        let current = UUID()
        let session = model.accountGeneration
        request = current
        issue = nil
        defer { if request == current { request = nil } }
        do {
            let value = try await load()
            guard request == current, canLoad, model.accountGeneration == session, !Task.isCancelled else { return }
            loaded = value
        } catch is CancellationError {
            return
        } catch {
            guard request == current, canView, model.accountGeneration == session, !Task.isCancelled else { return }
            if (error as? GroupGameError) == .gameNotFound { loaded = nil }
            issue = GroupsModel.message(for: error)
        }
    }

    private struct LoadKey: Equatable {
        let available: Bool
        let session: UUID
    }
}
#endif
