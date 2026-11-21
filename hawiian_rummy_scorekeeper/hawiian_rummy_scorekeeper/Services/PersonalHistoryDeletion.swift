import Foundation
import SwiftData

nonisolated struct PersonalDeletionTargets: Codable, Equatable, Sendable {
    var players: Set<UUID> = []
    var games: Set<UUID> = []
    var rounds: Set<UUID> = []
    var participants: Set<UUID> = []
    var levels: Set<UUID> = []
    var scores: Set<UUID> = []

    mutating func add(_ other: Self) {
        players.formUnion(other.players)
        games.formUnion(other.games)
        rounds.formUnion(other.rounds)
        participants.formUnion(other.participants)
        levels.formUnion(other.levels)
        scores.formUnion(other.scores)
    }

    func includes(_ other: Self) -> Bool {
        other.players.isSubset(of: players) && other.games.isSubset(of: games) &&
            other.rounds.isSubset(of: rounds) && other.participants.isSubset(of: participants) &&
            other.levels.isSubset(of: levels) && other.scores.isSubset(of: scores)
    }
}

@Model
final class PersonalDeletionReceipt {
    var payload: Data?

    init(_ targets: PersonalDeletionTargets) throws {
        payload = try JSONEncoder().encode(targets)
    }

    static func targets(from receipts: [PersonalDeletionReceipt]) throws -> PersonalDeletionTargets {
        var targets = PersonalDeletionTargets()
        for receipt in receipts {
            guard let payload = receipt.payload else { throw PersonalHistoryDeletion.Issue.unreadableReceipt }
            targets.add(try JSONDecoder().decode(PersonalDeletionTargets.self, from: payload))
        }
        return targets
    }
}

@MainActor
enum PersonalHistoryDeletion {
    struct Plan: Identifiable, Equatable {
        let targets: PersonalDeletionTargets
        let playerNames: [String]
        let gameTitles: [String]
        var id: Set<UUID> { targets.players }
    }

    enum Outcome {
        case deleted
        case reviewAgain(Plan)
    }

    enum Issue: LocalizedError {
        case selectionChanged
        case unfinished([String])
        case syncConflict([String])
        case unreadableReceipt

        var errorDescription: String? {
            switch self {
            case .selectionChanged:
                "The selected players have changed. Select the retired players again to continue."
            case .unfinished(let games):
                "Finish or separately delete these games before trying again.\n\n" + games.joined(separator: "\n")
            case .syncConflict(let games):
                "Synced data conflicts with a confirmed deletion. Review the affected games before retrying.\n\n"
                    + games.joined(separator: "\n")
            case .unreadableReceipt:
                "A deletion receipt could not be read. Try again after iCloud finishes syncing."
            }
        }
    }

    static func prepare(players: Set<UUID>, in container: ModelContainer) throws -> Plan {
        let context = ModelContext(container)
        try requireUnconfirmed(players, in: context)
        return try History(in: context).plan(players: players)
    }

    static func deletePlayers(
        confirmed: Plan, in container: ModelContainer, save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Outcome {
        let context = ModelContext(container)
        try requireUnconfirmed(confirmed.targets.players, in: context)
        let history = try History(in: context)
        let current = try history.plan(players: confirmed.targets.players)
        guard current == confirmed else { return .reviewAgain(current) }
        try commit(current.targets, history: history, in: context, save: save)
        return .deleted
    }

    static func deleteGame(id: UUID, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let receipts = try context.fetch(FetchDescriptor<PersonalDeletionReceipt>())
        let confirmed = try PersonalDeletionReceipt.targets(from: receipts)
        guard !confirmed.games.contains(id) else { return }
        let history = try History(in: context)
        guard history.games.contains(where: { $0.id == id }) else { return }
        var targets = PersonalDeletionTargets()
        targets.games.insert(id)
        try commit(history.descendants(of: targets), history: history, in: context, save: { try $0.save() })
    }

    static func reconcile(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let receipts = try context.fetch(FetchDescriptor<PersonalDeletionReceipt>())
        guard !receipts.isEmpty else { return }
        let targets = try PersonalDeletionReceipt.targets(from: receipts)
        let history = try History(in: context)
        try history.validate(targets)
        history.delete(targets, in: context)
        if context.hasChanges { try saveOrRollback(context, save: { try $0.save() }) }
    }

    static func visibleTargets(in container: ModelContainer) throws -> PersonalDeletionTargets {
        let context = ModelContext(container)
        let receipts = try context.fetch(FetchDescriptor<PersonalDeletionReceipt>())
        // Display valid confirmed deletions even if another receipt cannot be read.
        return receipts.reduce(into: PersonalDeletionTargets()) { targets, receipt in
            if let confirmed = try? PersonalDeletionReceipt.targets(from: [receipt]) {
                targets.add(confirmed)
            }
        }
    }

    private static func requireUnconfirmed(_ playerIDs: Set<UUID>, in context: ModelContext) throws {
        let receipts = try context.fetch(FetchDescriptor<PersonalDeletionReceipt>())
        let confirmed = try PersonalDeletionReceipt.targets(from: receipts)
        guard confirmed.players.isDisjoint(with: playerIDs) else { throw Issue.selectionChanged }
    }

    private static func commit(
        _ targets: PersonalDeletionTargets, history: History, in context: ModelContext,
        save: (ModelContext) throws -> Void
    ) throws {
        try history.validate(targets)
        context.insert(try PersonalDeletionReceipt(targets))
        history.delete(targets, in: context)
        try saveOrRollback(context, save: save)
    }

    private static func saveOrRollback(_ context: ModelContext, save: (ModelContext) throws -> Void) throws {
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private struct History {
        let players: [PlayerProfile]
        let games: [Game]
        let rounds: [GameRound]
        let participants: [RoundParticipant]
        let levels: [LevelResult]
        let scores: [ScoreEntry]

        init(in context: ModelContext) throws {
            players = try context.fetch(FetchDescriptor())
            games = try context.fetch(FetchDescriptor())
            rounds = try context.fetch(FetchDescriptor())
            participants = try context.fetch(FetchDescriptor())
            levels = try context.fetch(FetchDescriptor())
            scores = try context.fetch(FetchDescriptor())
        }

        func plan(players ids: Set<UUID>) throws -> Plan {
            let selected = players.filter { ids.contains($0.id) }
            guard !ids.isEmpty, selected.count == ids.count, Set(selected.map(\.id)) == ids,
                  selected.allSatisfy(\.isRetired) else { throw Issue.selectionChanged }
            let affected = games.filter { !playerIDs(in: $0).isDisjoint(with: ids) }
            let unfinished = affected.filter { !$0.isComplete }
            if !unfinished.isEmpty {
                throw Issue.unfinished(unfinished.map { game in
                    let relevant = playerIDs(in: game)
                    let names = selected.filter { relevant.contains($0.id) }.map(\.name).sorted()
                    return "\(label(for: game)) — \(names.joined(separator: ", "))"
                }.sorted())
            }
            var targets = PersonalDeletionTargets()
            targets.players = ids
            targets.games = Set(affected.map(\.id))
            let expanded = descendants(of: targets)
            try validate(expanded)
            return Plan(targets: expanded, playerNames: selected.map(\.name).sorted(),
                        gameTitles: affected.map { label(for: $0) }.sorted())
        }

        private func label(for game: Game) -> String {
            "\(game.title) (\(game.createdAt.formatted(date: .abbreviated, time: .shortened)))"
        }

        // Use both the game roster and round links. Either relationship may arrive first during sync.
        private func playerIDs(in game: Game) -> Set<UUID> {
            let gameRounds = Set((game.rounds ?? []).map(\.id))
                .union(rounds.filter { $0.game?.id == game.id }.map(\.id))
            let linked = rounds.filter { gameRounds.contains($0.id) }.flatMap { $0.participants ?? [] }
                + participants.filter { $0.round.map { gameRounds.contains($0.id) } ?? false }
            return Set((game.players ?? []).map(\.id)).union(linked.compactMap { $0.player?.id })
        }

        func descendants(of targets: PersonalDeletionTargets) -> PersonalDeletionTargets {
            var result = targets
            let targetedGames = games.filter { targets.games.contains($0.id) }
            result.rounds.formUnion(targetedGames.flatMap { $0.rounds ?? [] }.map(\.id))
            result.rounds.formUnion(rounds.filter { $0.game.map { targets.games.contains($0.id) } ?? false }.map(\.id))

            let roundIDs = result.rounds
            let targetedRounds = rounds.filter { roundIDs.contains($0.id) }
            result.participants.formUnion(targetedRounds.flatMap { $0.participants ?? [] }.map(\.id))
            result.participants.formUnion(participants.filter { $0.round.map { roundIDs.contains($0.id) } ?? false }.map(\.id))
            result.levels.formUnion(targetedRounds.flatMap { $0.levels ?? [] }.map(\.id))
            result.levels.formUnion(levels.filter { $0.round.map { roundIDs.contains($0.id) } ?? false }.map(\.id))

            let levelIDs = result.levels
            let participantIDs = result.participants
            result.scores.formUnion(levels.filter { levelIDs.contains($0.id) }.flatMap { $0.entries ?? [] }.map(\.id))
            result.scores.formUnion(participants.filter { participantIDs.contains($0.id) }.flatMap { $0.scoreEntries ?? [] }.map(\.id))
            result.scores.formUnion(scores.filter {
                ($0.level.map { levelIDs.contains($0.id) } ?? false) ||
                    ($0.participant.map { participantIDs.contains($0.id) } ?? false)
            }.map(\.id))
            return result
        }

        func validate(_ targets: PersonalDeletionTargets) throws {
            guard Set(games.filter { targets.games.contains($0.id) }.map(\.id)).count ==
                    games.filter({ targets.games.contains($0.id) }).count,
                  Set(players.filter { targets.players.contains($0.id) }.map(\.id)).count ==
                    players.filter({ targets.players.contains($0.id) }).count else {
                throw Issue.syncConflict(["More than one local record has the same player or game identifier."])
            }
            let survivingGames = games.filter { !targets.games.contains($0.id) }
            var surviving = PersonalDeletionTargets()
            surviving.games = Set(survivingGames.map(\.id))
            let survivingHistory = descendants(of: surviving)
            if !targets.rounds.isDisjoint(with: survivingHistory.rounds) ||
                !targets.participants.isDisjoint(with: survivingHistory.participants) ||
                !targets.levels.isDisjoint(with: survivingHistory.levels) ||
                !targets.scores.isDisjoint(with: survivingHistory.scores) {
                let conflicts = survivingGames.filter { game in
                    var gameTarget = PersonalDeletionTargets()
                    gameTarget.games.insert(game.id)
                    let history = descendants(of: gameTarget)
                    return !targets.rounds.isDisjoint(with: history.rounds) ||
                        !targets.participants.isDisjoint(with: history.participants) ||
                        !targets.levels.isDisjoint(with: history.levels) ||
                        !targets.scores.isDisjoint(with: history.scores)
                }
                throw Issue.syncConflict(conflicts.map { label(for: $0) }.sorted())
            }
            let references = survivingGames.filter { !playerIDs(in: $0).isDisjoint(with: targets.players) }
            if !references.isEmpty { throw Issue.syncConflict(references.map { label(for: $0) }.sorted()) }
            let detached = participants.contains {
                guard let player = $0.player, targets.players.contains(player.id) else { return false }
                return !targets.participants.contains($0.id)
            }
            if detached { throw Issue.syncConflict(["A round for a selected player is missing its game."]) }
            if !targets.includes(descendants(of: targets)) {
                let labels = games.filter { targets.games.contains($0.id) }.map { label(for: $0) }.sorted()
                throw Issue.syncConflict(labels.isEmpty ? ["New scoring data arrived for a deleted game."] : labels)
            }
        }

        func delete(_ targets: PersonalDeletionTargets, in context: ModelContext) {
            for score in scores where targets.scores.contains(score.id) { context.delete(score) }
            for level in levels where targets.levels.contains(level.id) { context.delete(level) }
            for participant in participants where targets.participants.contains(participant.id) { context.delete(participant) }
            for round in rounds where targets.rounds.contains(round.id) { context.delete(round) }
            for game in games where targets.games.contains(game.id) { context.delete(game) }
            for player in players where targets.players.contains(player.id) { context.delete(player) }
        }
    }
}
