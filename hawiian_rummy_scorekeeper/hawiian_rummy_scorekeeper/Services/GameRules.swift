import Foundation
import SwiftData

struct LevelDefinition: Identifiable {
    let number: Int
    let cards: Int
    let goal: String
    var id: Int { number }

    static let all = [
        LevelDefinition(number: 1, cards: 7, goal: "2 Sets"),
        LevelDefinition(number: 2, cards: 8, goal: "1 Run · 1 Set"),
        LevelDefinition(number: 3, cards: 9, goal: "2 Runs"),
        LevelDefinition(number: 4, cards: 10, goal: "3 Sets"),
        LevelDefinition(number: 5, cards: 11, goal: "Run of 7 · 1 Set"),
        LevelDefinition(number: 6, cards: 12, goal: "2 Runs · 1 Set"),
        LevelDefinition(number: 7, cards: 12, goal: "2 Sets · 1 Run\nNo Discards")
    ]

    static func definition(for number: Int) -> LevelDefinition { all[number - 1] }
}

struct Standing: Identifiable {
    let participant: RoundParticipant
    let total: Int
    let rank: Int
    let isLeader: Bool
    var id: UUID { participant.id }
}

enum GameRules {
    static func parsedScores(for playerIDs: [UUID], values: [UUID: String]) -> [UUID: Int]? {
        guard !playerIDs.isEmpty else { return nil }
        var scores: [UUID: Int] = [:]
        for id in playerIDs {
            guard let value = values[id], let score = Int(value), score >= 0 else { return nil }
            scores[id] = score
        }
        return scores
    }

    static func total<Points: AdditiveArithmetic>(_ scores: some Sequence<Points>) -> Points {
        scores.reduce(.zero, +)
    }

    static func ranked<Player, Points: Comparable>(
        _ players: [Player], name: (Player) -> String, score: (Player) -> Points
    ) -> [(player: Player, total: Points, rank: Int)] {
        let sorted = players.map { (player: $0, total: score($0)) }.sorted {
            $0.total == $1.total ? name($0.player) < name($1.player) : $0.total < $1.total
        }
        var previous: Points?
        var rank = 0
        return sorted.enumerated().map { index, item in
            if previous != item.total {
                rank = index + 1
                previous = item.total
            }
            return (item.player, item.total, rank)
        }
    }

    static func score(for participant: RoundParticipant, in round: GameRound) -> Int {
        total((round.levels ?? []).flatMap { $0.entries ?? [] }
            .filter { $0.participant?.id == participant.id }.map(\.score))
    }

    static func score(for player: PlayerProfile, in game: Game) -> Int {
        total((game.rounds ?? []).flatMap { $0.levels ?? [] }.flatMap { $0.entries ?? [] }
            .filter { $0.participant?.player?.id == player.id }.map(\.score))
    }

    static func standings(for round: GameRound) -> [Standing] {
        ranked(round.participants ?? [], name: \.displayName, score: { score(for: $0, in: round) })
            .map { participant, total, rank in
                Standing(participant: participant, total: total, rank: rank, isLeader: rank == 1)
            }
    }

    static func gameStandings(for game: Game) -> [(PlayerProfile, Int, Int)] {
        ranked(game.players ?? [], name: \.name, score: { score(for: $0, in: game) })
    }

    static func createRound(in game: Game) -> GameRound {
        let roster = game.sortedRounds.first?.orderedParticipants.compactMap(\.player) ?? (game.players ?? [])
        let round = GameRound(number: (game.rounds?.count ?? 0) + 1, game: game, players: roster)
        game.rounds = (game.rounds ?? []) + [round]
        return round
    }

    static func save(scores: [UUID: Int], for levelNumber: Int, in round: GameRound, context: ModelContext) throws {
        if let existing = round.levels?.first(where: { $0.levelNumber == levelNumber }) {
            let previousEntries = existing.entries ?? []
            existing.entries = round.orderedParticipants.compactMap { participant in
                scores[participant.id].map { ScoreEntry(score: $0, participant: participant) }
            }
            previousEntries.forEach(context.delete)
        } else {
            let level = LevelResult(levelNumber: levelNumber)
            level.entries = round.orderedParticipants.compactMap { participant in
                scores[participant.id].map { ScoreEntry(score: $0, participant: participant) }
            }
            round.levels = (round.levels ?? []) + [level]
        }
        if round.levels?.count == LevelDefinition.all.count { round.completedAt = .now }
        try context.save()
    }
}
