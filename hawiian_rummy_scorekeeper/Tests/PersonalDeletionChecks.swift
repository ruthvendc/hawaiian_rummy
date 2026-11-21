import Foundation
import SwiftData

@main
@MainActor
struct PersonalDeletionChecks {
    private struct Failure: Error { let message: String }
    private var nextRoundDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func main() throws {
        var checks = Self()
        try checks.migrateAndDeleteWithoutGames()
        try checks.individualDeletion()
        try checks.bulkDeletionAndRecords()
        try checks.changedConfirmationAndFailedSave()
        try checks.syncRecovery()
    }

    private func schema(withReceipts: Bool = true) -> Schema {
        let models: [any PersistentModel.Type] = [
            PlayerProfile.self, Game.self, GameRound.self, RoundParticipant.self, LevelResult.self, ScoreEntry.self
        ]
        return Schema(withReceipts ? models + [PersonalDeletionReceipt.self] : models)
    }

    private func makeStore() throws -> ModelContainer {
        try ModelContainer(for: schema(), configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private mutating func migrateAndDeleteWithoutGames() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "personal.store")
        let retiredID: UUID
        let activeID: UUID
        let partnerID: UUID
        let keepID: UUID
        do {
            let old = try ModelContainer(for: schema(withReceipts: false),
                                         configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            retiredID = player("Retired", retired: true, in: old.mainContext).id
            let active = player("Active", in: old.mainContext)
            let partner = player("Partner", in: old.mainContext)
            activeID = active.id
            partnerID = partner.id
            keepID = game("Existing game", players: [active, partner], scores: [[4, 2]], in: old.mainContext).id
            try old.mainContext.save()
        }
        let store = try ModelContainer(for: schema(), configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        try check(try fetch(PlayerProfile.self, in: store).count == 3 &&
                  fetch(Game.self, in: store).first?.id == keepID &&
                  fetch(ScoreEntry.self, in: store).map(\.score).sorted() == [2, 4],
                  "Add receipts to an existing store without resetting player or score data")
        let plan = try PersonalHistoryDeletion.prepare(players: [retiredID], in: store)
        try check(plan.targets.games.isEmpty, "Preview a single retired player with no games")
        try deleted(PersonalHistoryDeletion.deletePlayers(confirmed: plan, in: store))
        try check(try Set(fetch(PlayerProfile.self, in: store).map(\.id)) == [activeID, partnerID] &&
                  fetch(Game.self, in: store).first?.id == keepID,
                  "Delete one retired profile and preserve the active UUIDs and unrelated game")
        try expect("Reject permanent deletion of an active player") {
            _ = try PersonalHistoryDeletion.prepare(players: [activeID], in: store)
        } matches: { if case PersonalHistoryDeletion.Issue.selectionChanged = $0 { true } else { false } }
    }

    private mutating func individualDeletion() throws {
        let store = try makeStore()
        let context = store.mainContext
        let retired = player("Removed", retired: true, in: context)
        let friend = player("Friend", in: context)
        let friendID = friend.id
        let first = game("First", players: [retired, friend], scores: [[2, 4]], in: context)
        // Leave the retired player linked only through the round roster in the second game.
        let second = game("Round roster only", players: [friend, retired], scores: [[3, 2]], in: context)
        second.players = [friend]
        try context.save()
        let plan = try PersonalHistoryDeletion.prepare(players: [retired.id], in: store)
        try check(plan.targets.games == [first.id, second.id], "Find every complete game through both roster relationships")
        try deleted(PersonalHistoryDeletion.deletePlayers(confirmed: plan, in: store))
        try check(try fetch(PlayerProfile.self, in: store).map(\.id) == [friendID], "Individual deletion preserves the other player")
        try checkCounts(in: store, games: 0, rounds: 0, participants: 0, levels: 0, scores: 0)
    }

    private mutating func bulkDeletionAndRecords() throws {
        let store = try makeStore()
        let context = store.mainContext
        let david = player("David", in: context)
        let wendy = player("Wendy", in: context)
        let first = player("First Removed", retired: true, in: context)
        let second = player("Second Removed", retired: true, in: context)
        let activeIDs: Set<UUID> = [david.id, wendy.id]
        let keepScores = (0..<9).map { $0.isMultiple(of: 2) ? [8, 3] : [3, 8] }
        let keep = game("Keep", players: [david, wendy], scores: keepScores, in: context)
        let shared = game("Shared", players: [david, wendy, first, second], scores: [[0, 30, 45, 50], [0, 30, 45, 50]], in: context)
        let other = game("Other", players: [david, wendy, first], scores: [[1, 30, 45]], in: context)
        let keepID = keep.id
        try context.save()

        let before = try records(in: store)
        try check(before.completedGameCount == 3 && before.completedRoundCount == 12 &&
                  before.gameWinCounts[david.id] == 2 && before.gameWinCounts[wendy.id] == 1 &&
                  before.roundWinsRecord == RecordResult(holders: ["David"], detail: "7 round wins") &&
                  before.bestAverageRecord.holders == ["David"] &&
                  before.bestSingleRoundRecord.holders == ["David"] &&
                  before.mostRoundsRecord.holders == ["David", "Wendy"] &&
                  before.longestStreakRecord == RecordResult(holders: ["David"], detail: "3 rounds in a row") &&
                  before.levelSevenRecord == RecordResult(holders: ["David"], detail: "0 points"),
                  "Establish baseline for every Records category and the ten-round threshold")
        let plan = try PersonalHistoryDeletion.prepare(players: [first.id, second.id], in: store)
        try check(plan.targets.players.count == 2 && plan.targets.games == [shared.id, other.id],
                  "Bulk preview counts each shared game once")
        try check(try fetch(Game.self, in: store).count == 3 && fetch(PersonalDeletionReceipt.self, in: store).isEmpty,
                  "Preparing or cancelling a confirmation changes no stored data")
        try deleted(PersonalHistoryDeletion.deletePlayers(confirmed: plan, in: store))
        try check(try Set(fetch(PlayerProfile.self, in: store).map(\.id)) == activeIDs &&
                  fetch(Game.self, in: store).map(\.id) == [keepID],
                  "Preserve remaining player UUIDs and the unrelated game")
        try checkCounts(in: store, games: 1, rounds: 9, participants: 18, levels: 9, scores: 18)

        let after = try records(in: store)
        let davidRow = after.rows.first { $0.player.name == "David" }
        let wendyRow = after.rows.first { $0.player.name == "Wendy" }
        try check(after.completedGameCount == 1 && after.completedRoundCount == 9 &&
                  davidRow?.rounds == 9 && davidRow?.roundWins == 4 && davidRow?.total == 52 &&
                  davidRow?.average == 52.0 / 9.0 && davidRow?.bestRound == 3 &&
                  wendyRow?.rounds == 9 && wendyRow?.roundWins == 5 && wendyRow?.total == 47 &&
                  wendyRow?.average == 47.0 / 9.0 && wendyRow?.bestRound == 3,
                  "Recalculate cumulative rounds, wins, totals, averages and best rounds for remaining players")
        try check(after.gameWinsRecord == RecordResult(holders: ["Wendy"], detail: "1 game wins") &&
                  after.roundWinsRecord == RecordResult(holders: ["Wendy"], detail: "5 round wins") &&
                  after.bestAverageRecord == RecordResult(detail: "No one qualifies yet") &&
                  after.bestSingleRoundRecord == RecordResult(holders: ["David", "Wendy"], detail: "3 points") &&
                  after.mostRoundsRecord == RecordResult(holders: ["David", "Wendy"], detail: "9 rounds") &&
                  after.longestStreakRecord == RecordResult(holders: ["David", "Wendy"], detail: "1 rounds in a row") &&
                  after.levelSevenRecord == RecordResult(holders: ["David", "Wendy"], detail: "3 points"),
                  "Recalculate every displayed record, including changed leaders, ties and eligibility")

        try PersonalHistoryDeletion.deleteGame(id: keepID, in: store)
        try checkCounts(in: store, games: 0, rounds: 0, participants: 0, levels: 0, scores: 0)
        let empty = try records(in: store)
        try check(empty.rows.isEmpty && empty.gameWinCounts.isEmpty &&
                  empty.levelSevenRecord == RecordResult(detail: "No Level 7 scores yet") &&
                  Set(empty.players.map(\.id)) == activeIDs,
                  "Ordinary game deletion uses the same cascade and refreshes Records without deleting profiles")
    }

    private mutating func changedConfirmationAndFailedSave() throws {
        let store = try makeStore()
        let context = store.mainContext
        let first = player("First", retired: true, in: context)
        let second = player("Second", retired: true, in: context)
        let unfinished = game("In Progress", players: [first, second], scores: [[2, 4]], complete: false, in: context)
        try context.save()
        try expect("Unfinished game names affected players and blocks the entire bulk selection") {
            _ = try PersonalHistoryDeletion.prepare(players: [first.id, second.id], in: store)
        } matches: {
            if case PersonalHistoryDeletion.Issue.unfinished(let labels) = $0 {
                return labels.count == 1 && labels[0].contains("In Progress") && labels[0].contains("First, Second")
            }
            return false
        }
        unfinished.completedAt = .now
        try context.save()
        let plan = try PersonalHistoryDeletion.prepare(players: [first.id, second.id], in: store)
        try PersonalHistoryDeletion.deleteGame(id: unfinished.id, in: store)
        let replacement = game("Replacement", players: [first, second], scores: [[3, 4]], in: context)
        try context.save()
        let result = try PersonalHistoryDeletion.deletePlayers(confirmed: plan, in: store)
        guard case .reviewAgain(let changed) = result else { throw Failure(message: "Expected a refreshed confirmation") }
        try check(changed.targets.games == [replacement.id] && changed.targets.games.count == plan.targets.games.count,
                  "Require a new confirmation when the exact games change but the count matches")
        try expect("Surface an interrupted save") {
            _ = try PersonalHistoryDeletion.deletePlayers(confirmed: changed, in: store) { _ in
                throw Failure(message: "Simulated save failure")
            }
        } matches: { ($0 as? Failure)?.message == "Simulated save failure" }
        try check(try fetch(PlayerProfile.self, in: store).count == 2 &&
                  fetch(Game.self, in: store).count == 1 && fetch(PersonalDeletionReceipt.self, in: store).count == 1,
                  "Roll back the entire failed deletion, including its receipt")
        try checkCounts(in: store, games: 1, rounds: 1, participants: 2, levels: 1, scores: 2)
    }

    private mutating func syncRecovery() throws {
        let store = try makeStore()
        let context = store.mainContext
        let retired = player("Retired", retired: true, in: context)
        let active = player("Active", in: context)
        let oldID = game("Confirmed", players: [retired, active], scores: [[1, 2]], in: context).id
        let retiredID = retired.id
        let activeID = active.id
        try context.save()
        let plan = try PersonalHistoryDeletion.prepare(players: [retired.id], in: store)
        // Deliver the receipt before the mirrored deletes, while a stale device holds a new related game.
        let late = game("Newly Synced", players: [retired, active], scores: [[3, 4]], in: context)
        let lateID = late.id
        context.insert(try PersonalDeletionReceipt(plan.targets))
        try context.save()
        let importedTargets = try PersonalHistoryDeletion.visibleTargets(in: store)
        try check(importedTargets == plan.targets,
                  "A fresh store read supplies imported deletion IDs while the visible query may still be stale")
        try expect("A newly discovered game is surfaced for review") {
            try PersonalHistoryDeletion.reconcile(in: store)
        } matches: {
            if case PersonalHistoryDeletion.Issue.syncConflict(let games) = $0 {
                return games.contains { $0.contains("Newly Synced") }
            }
            return false
        }
        try check(try fetch(Game.self, in: store).count == 2 && fetch(PlayerProfile.self, in: store).count == 2,
                  "Recovery never deletes newly discovered games or partially processes a blocked receipt")
        try PersonalHistoryDeletion.deleteGame(id: lateID, in: store)
        try PersonalHistoryDeletion.reconcile(in: store)
        try PersonalHistoryDeletion.reconcile(in: store)
        try checkCounts(in: store, games: 0, rounds: 0, participants: 0, levels: 0, scores: 0)
        try check(try fetch(PlayerProfile.self, in: store).map(\.id) == [activeID], "Retries converge with the unaffected profile intact")

        let staleContext = ModelContext(store)
        let stale = ScoreEntry(score: 1, participant: RoundParticipant(player: PlayerProfile(name: "Fixture"), displayOrder: 0))
        stale.participant = nil
        guard let scoreID = plan.targets.scores.first else { throw Failure(message: "Missing confirmed score") }
        stale.id = scoreID
        staleContext.insert(stale)
        let staleProfile = PlayerProfile(name: "Retired")
        staleProfile.id = retiredID
        staleContext.insert(staleProfile)
        let staleGame = Game(title: "Confirmed", players: [staleProfile])
        staleGame.id = oldID
        staleContext.insert(staleGame)
        try staleContext.save()
        try check(try PersonalHistoryDeletion.visibleTargets(in: store).players == [retiredID] && !staleProfile.isRetired,
                  "Display targets exclude a stale confirmed UUID even when the profile was active on that device")
        try PersonalHistoryDeletion.reconcile(in: store)
        try check(try fetch(ScoreEntry.self, in: store).isEmpty && fetch(Game.self, in: store).isEmpty &&
                  fetch(PlayerProfile.self, in: store).map(\.id) == [activeID],
                  "Reconcile stale copies of the profile, game and a detached score by confirmed receipt IDs")

        let updated = ModelContext(store)
        let savedActive = try updated.fetch(FetchDescriptor<PlayerProfile>())
        let changedGame = game("More scores arrived", players: savedActive, scores: [[7]], in: updated)
        changedGame.id = oldID
        try updated.save()
        try expect("Recovery reports newly arrived scores outside the confirmed receipt") {
            try PersonalHistoryDeletion.reconcile(in: store)
        } matches: {
            if case PersonalHistoryDeletion.Issue.syncConflict(let games) = $0 {
                return games.contains { $0.contains("More scores arrived") }
            }
            return false
        }
        try check(try fetch(ScoreEntry.self, in: store).map(\.score) == [7],
                  "Recovery preserves a newly arrived score for review")
    }

    private func player(_ name: String, retired: Bool = false, in context: ModelContext) -> PlayerProfile {
        let player = PlayerProfile(name: name)
        if retired { player.retiredAt = .now }
        context.insert(player)
        return player
    }

    private mutating func game(
        _ title: String, players: [PlayerProfile], scores: [[Int]], complete: Bool = true, in context: ModelContext
    ) -> Game {
        let game = Game(title: title, players: players)
        context.insert(game)
        for row in scores {
            let round = GameRules.createRound(in: game)
            round.createdAt = nextRoundDate
            nextRoundDate += 1
            let level = LevelResult(levelNumber: 7)
            level.entries = zip(round.orderedParticipants, row).map { ScoreEntry(score: $0.1, participant: $0.0) }
            round.levels = [level]
            round.completedAt = round.createdAt
        }
        if complete { game.completedAt = nextRoundDate }
        return game
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, in store: ModelContainer) throws -> [T] {
        try ModelContext(store).fetch(FetchDescriptor<T>())
    }

    private func records(in store: ModelContainer) throws -> LifetimeRecords {
        let context = ModelContext(store)
        return LifetimeRecords(players: try context.fetch(FetchDescriptor()), games: try context.fetch(FetchDescriptor()))
    }

    private func checkCounts(
        in store: ModelContainer, games: Int, rounds: Int, participants: Int, levels: Int, scores: Int
    ) throws {
        try check(try fetch(Game.self, in: store).count == games && fetch(GameRound.self, in: store).count == rounds &&
                  fetch(RoundParticipant.self, in: store).count == participants &&
                  fetch(LevelResult.self, in: store).count == levels && fetch(ScoreEntry.self, in: store).count == scores,
                  "Persist expected game, round, participant, level and score counts")
    }

    private func deleted(_ result: PersonalHistoryDeletion.Outcome) throws {
        guard case .deleted = result else { throw Failure(message: "Expected deletion") }
    }

    private func expect(_ message: String, operation: () throws -> Void, matches: (Error) -> Bool) throws {
        do { try operation() }
        catch where matches(error) {
            print("PASS: \(message)")
            return
        }
        throw Failure(message: message)
    }

    private func check(_ result: Bool, _ message: String) throws {
        guard result else { throw Failure(message: message) }
        print("PASS: \(message)")
    }
}
