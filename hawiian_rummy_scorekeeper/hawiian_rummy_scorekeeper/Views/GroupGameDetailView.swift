#if DEBUG
import Network
import SwiftUI

struct GroupGameDetailView: View {
    let route: GroupGameRoute
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPath: Bool?
    @State private var scoring: GroupGameScoring
    @State private var showingScoreEntry = false
    @State private var reassigning: GroupGameHeader?
    @State private var confirmation: Confirmation?
    @State private var confirming = false

    init(route: GroupGameRoute, model: GroupsModel) {
        self.route = route
        _scoring = State(initialValue: GroupGameScoring(route: route, groups: model))
    }

    var body: some View {
        List {
            if scoring.canView {
                Section {
                    SectionIntroCard(title: route.group.name, subtitle: "Shared scores", icon: "rectangle.stack")
                        .listRowBackground(Color.clear)
                }
                GroupGameConnectionStatus(scoring: scoring, checkingConnection: hasPath == nil)
                if scoring.draft != nil {
                    Button("Resume Score Entry") { showingScoreEntry = true }
                }
                if scoring.isDeleted {
                    ContentUnavailableView("Game Permanently Deleted", systemImage: "trash")
                } else if let detail = scoring.detail {
                    gameContent(detail)
                }
            } else {
                ContentUnavailableView("Group Unavailable", systemImage: "person.3",
                                       description: Text("Verify your iCloud account and group access to see saved scores."))
            }
        }
        .background(Color.softPurpleBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle("Group Game")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await scoring.refresh() }
        .toolbar {
            if scoring.canView {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await scoring.refresh() } }
                        .disabled(!scoring.online || scoring.isBusy)
                }
            }
        }
        .task {
            let monitor = NWPathMonitor()
            for await path in monitor { hasPath = path.status == .satisfied }
        }
        .onChange(of: hasPath == true && scenePhase == .active, initial: true) { _, online in
            scoring.online = online
            if scenePhase == .active { Task { await scoring.refresh() } }
        }
        .task(id: scoring.canView) {
            if scoring.canView { await scoring.refresh() } else { scoring.discardInaccessibleGame() }
        }
        .onChange(of: scoring.draft != nil) { _, hasDraft in showingScoreEntry = hasDraft }
        .sheet(isPresented: $showingScoreEntry, onDismiss: {
            if let draft = scoring.draft, draft.values == draft.originalValues { scoring.closeDraft() }
        }) {
            GroupGameScoreEntryView(scoring: scoring)
        }
        .sheet(item: $reassigning) { header in
            GroupGameScorekeeperPicker(scoring: scoring, header: header)
        }
        .confirmationDialog(confirmation?.title ?? "", isPresented: $confirming,
                            titleVisibility: .visible, presenting: confirmation) { confirmation in
            Button(confirmation.button, role: .destructive) {
                Task {
                    switch confirmation {
                    case .end(let version): await scoring.complete(from: version)
                    case .cancel(let version): await scoring.cancel(from: version)
                    case .delete(let version): await scoring.delete(from: version)
                    }
                }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private func manageGame(_ header: GroupGameHeader) -> some View {
        Menu {
            if header.status == .inProgress {
                Button("Reassign Scorekeeper", systemImage: "person.2") { reassigning = header }
                Button("Cancel Game", systemImage: "xmark.circle", role: .destructive) {
                    confirmation = .cancel(header.version)
                    confirming = true
                }
            }
            Button("Permanently Delete", systemImage: "trash", role: .destructive) {
                confirmation = .delete(header.version)
                confirming = true
            }
        } label: {
            Label("Manage Game", systemImage: "ellipsis.circle")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!scoring.canManage)
    }

    private enum Confirmation {
        case end(GroupGameScoring.EditVersion)
        case cancel(GroupGameVersion)
        case delete(GroupGameVersion)

        var title: String {
            switch self {
            case .end: "End this game?"
            case .cancel: "Cancel this game?"
            case .delete: "Permanently delete this game?"
            }
        }

        var button: String {
            switch self {
            case .end: "End Game"
            case .cancel: "Cancel Game"
            case .delete: "Permanently Delete"
            }
        }

        var message: String {
            switch self {
            case .end: "All saved scores, including any hands entered in the current round, will count in the final standings."
            case .cancel: "Saved scores will stay in group history. This game can’t be resumed or completed."
            case .delete: "This removes the game and all its scores for everyone in the group. This action can’t be undone."
            }
        }
    }

    @ViewBuilder private func gameContent(_ detail: GroupGameScoring.Detail) -> some View {
        let game = detail.game
        Section {
            GroupGameSummary(header: game.header, scorekeeper: detail.scorekeeperName)
            if game.header.status == .inProgress && !detail.canScore {
                Label("Read only · Assigned scorekeeper can edit", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            if let header = scoring.managementHeader {
                manageGame(header)
            }
        }
        if game.header.status == .inProgress, let round = game.rounds.last {
            currentRound(round)
        }
        Section {
            GroupGameStandings(rows: game.standings())
        } header: {
            switch game.header.status {
            case .inProgress: Text("Overall Standings")
            case .completed: Text("Final Standings")
            case .cancelled: Text("Standings at Cancellation")
            }
        } footer: {
            if game.header.status != .cancelled { Text("Lowest total across all rounds wins.") }
        }
        ForEach(game.rounds) { round in
            Section("Round \(round.id.number) Scores") {
                if round.hands.isEmpty {
                    Text("No scores entered").foregroundStyle(.secondary)
                } else {
                    GroupGameStandings(rows: game.standings(round: round))
                    ForEach(round.hands, id: \.number) { hand in
                        GroupGameHandScores(hand: hand, participants: game.header.participants)
                        if scoring.canStartChange && (round.id != game.rounds.last?.id || hand.number != round.hands.last?.number) {
                            Button("Edit Hand \(hand.number)") {
                                scoring.beginScores(round: round.id.number, hand: hand.number)
                            }
                            .accessibilityLabel("Edit round \(round.id.number), hand \(hand.number)")
                        }
                    }
                }
            }
        }
    }

    private func currentRound(_ round: GroupGameRound) -> some View {
        let next = LevelDefinition.all.dropFirst(round.hands.count).first
        return Section("Current Round") {
            if let next {
                LevelMissionCard(roundNumber: round.id.number, handNumber: next.number, definition: next)
                    .listRowBackground(Color.clear)
                if scoring.canStartChange {
                    Button("Enter Scores", systemImage: "square.and.pencil") {
                        scoring.beginScores(round: round.id.number, hand: next.number)
                    }
                }
            } else {
                Text("Round \(round.id.number) complete").font(.headline)
                if scoring.canStartChange, let version = scoring.editVersion {
                    Button("Play Another Round", systemImage: "arrow.clockwise") {
                        Task { await scoring.advance(from: version) }
                    }
                }
            }
            if scoring.canStartChange, let version = scoring.editVersion {
                if let previous = round.hands.last {
                    Button("Edit Previous Hand") {
                        scoring.beginScores(round: round.id.number, hand: previous.number)
                    }
                }
                Button("End Game", role: .destructive) {
                    confirmation = .end(version)
                    confirming = true
                }
            }
        }
    }
}

private struct GroupGameScorekeeperPicker: View {
    let scoring: GroupGameScoring
    let header: GroupGameHeader
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [GroupGameScorekeeperCandidate] = []
    @State private var selectedKey: String?
    @State private var issue: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current Scorekeeper", value: scoring.detail?.scorekeeperName ?? "Name unavailable")
                }
                Section("Assign To") {
                    if isLoading {
                        ProgressView("Loading members…")
                    } else if let issue {
                        Text(issue).foregroundStyle(.secondary)
                        Button("Refresh Members") { Task { await load() } }
                    } else if candidates.isEmpty {
                        Text("No other eligible members.").foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                selectedKey = candidate.id
                            } label: {
                                HStack {
                                    Text(candidate.name)
                                    Spacer()
                                    if selectedKey == candidate.id {
                                        Image(systemName: "checkmark").accessibilityHidden(true)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selectedKey == candidate.id ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle("Reassign Scorekeeper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reassign") {
                        guard let selectedKey else { return }
                        dismiss()
                        Task { await scoring.reassignScorekeeper(selectedKey, from: header.version) }
                    }
                    .disabled(!scoring.canManage || isLoading || selectedKey == nil)
                }
            }
        }
        .task { await load() }
        .onChange(of: scoring.canView) { _, canView in if !canView { dismiss() } }
    }

    private func load() async {
        isLoading = true
        issue = nil
        selectedKey = nil
        defer { isLoading = false }
        do {
            candidates = try await scoring.scorekeeperCandidates().filter { $0.id != header.scorekeeperKey }
        } catch is CancellationError {
            return
        } catch {
            issue = GroupsModel.message(for: error)
        }
    }
}

private struct GroupGameStandings: View {
    let rows: [(player: GroupGameParticipant, total: Int128, rank: Int)]

    var body: some View {
        ForEach(rows, id: \.player.playerID) { player, total, rank in
            LabeledContent {
                Text(String(total)).monospacedDigit().bold()
            } label: {
                Text("\(rank). \(player.displayName)")
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct GroupGameConnectionStatus: View {
    let scoring: GroupGameScoring
    let checkingConnection: Bool

    var body: some View {
        if scoring.isSubmitting {
            ProgressView("Saving change…")
        } else if scoring.isRefreshing || checkingConnection {
            ProgressView("Loading scores…")
        } else if let issue = scoring.loadIssue {
            Text(issue).foregroundStyle(.secondary)
        } else if !scoring.online {
            Text(scoring.detail == nil ? "Connect to iCloud to load scores." : "Offline")
                .foregroundStyle(.secondary)
        }
        if let status = scoring.syncStatus { Text(status).foregroundStyle(.secondary) }
        if !scoring.isBusy && scoring.awaitingReadback {
            Text("Change saved. Refresh to see the latest scores.").foregroundStyle(.secondary)
        }
        if let issue = scoring.changeIssue { Text(issue).foregroundStyle(.secondary) }
        if scoring.pending != nil && !scoring.isSubmitting {
            Button("Retry Change") { Task { await scoring.retry() } }.disabled(!scoring.canRetry)
        }
    }
}

private struct GroupGameScoreEntryView: View {
    let scoring: GroupGameScoring
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            if let draft = scoring.draft {
                Form {
                    Section {
                        Text("Round \(draft.round) · Hand \(draft.hand)").font(.headline)
                        Text(LevelDefinition.definition(for: draft.hand).goal)
                    }
                    GroupGameConnectionStatus(scoring: scoring, checkingConnection: false)
                    if scoring.online && !scoring.hasLiveSnapshot && !scoring.isBusy {
                        Button("Refresh Scores") { Task { await scoring.refresh() } }
                    }
                    if scoring.draftNeedsReview {
                        reviewSection(draft)
                    }
                    if scoring.detail?.canScore == false {
                        Text("This game is now read only.").foregroundStyle(.secondary)
                    }
                    Section("Your Scores") {
                        ForEach(draft.participants, id: \.playerID) { player in
                            PlayerScoreField(name: player.displayName, score: Binding(
                                get: { scoring.draft?.values[player.playerID] ?? "" },
                                set: { scoring.updateScore(for: player.playerID, value: $0) }
                            ))
                        }
                    }
                    .disabled(scoring.isSubmitting || scoring.detail?.canScore != true)
                }
                .scrollContentBackground(.hidden)
                .background(Color.softPurpleBackground)
                .navigationTitle(draft.isCorrection ? "Edit Scores" : "Enter Scores")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if draft.values == draft.originalValues {
                                scoring.closeDraft()
                            } else {
                                confirmingDiscard = true
                            }
                        }
                        .disabled(scoring.isSubmitting)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await scoring.saveDraft() } }.disabled(!scoring.canSaveDraft)
                    }
                }
                .confirmationDialog("Discard your score entries?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { scoring.closeDraft() }
                }
                .interactiveDismissDisabled(draft.values != draft.originalValues)
            }
        }
    }

    private func reviewSection(_ draft: GroupGameScoring.Draft) -> some View {
        Section("Latest Saved Scores") {
            if let saved = scoring.savedDraftHand {
                ForEach(draft.participants, id: \.playerID) { player in
                    if let score = saved.scores.first(where: { $0.playerID == player.playerID }) {
                        LabeledContent(player.displayName, value: String(score.points))
                    }
                }
            } else {
                Text("No saved scores for this hand.").foregroundStyle(.secondary)
            }
            if scoring.canReviewDraft {
                Button("Keep My Entries") { scoring.reviewDraft() }
            }
        }
    }
}
#endif
