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
        LevelDefinition(number: 7, cards: 12, goal: "2 Sets · 1 Run · No discards")
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
    static func score(for participant: RoundParticipant, in round: GameRound) -> Int {
        round.levels.flatMap(\.entries)
            .filter { $0.participant?.id == participant.id }
            .reduce(0) { $0 + $1.score }
    }

    static func score(for player: PlayerProfile, in game: Game) -> Int {
        game.rounds.flatMap(\.levels).flatMap(\.entries)
            .filter { $0.participant?.player?.id == player.id }
            .reduce(0) { $0 + $1.score }
    }

    static func standings(for round: GameRound) -> [Standing] {
        let sorted = round.participants.sorted {
            let left = score(for: $0, in: round)
            let right = score(for: $1, in: round)
            return left == right ? $0.displayName < $1.displayName : left < right
        }
        var priorScore: Int?
        var rank = 0
        return sorted.enumerated().map { index, participant in
            let total = score(for: participant, in: round)
            if priorScore != total { rank = index + 1; priorScore = total }
            return Standing(participant: participant, total: total, rank: rank, isLeader: rank == 1)
        }
    }

    static func gameStandings(for game: Game) -> [(PlayerProfile, Int, Int)] {
        var ordered: [(player: PlayerProfile, total: Int)] = []
        for player in game.players {
            ordered.append((player: player, total: score(for: player, in: game)))
        }
        ordered.sort { left, right in
            left.total == right.total ? left.player.name < right.player.name : left.total < right.total
        }
        var previous: Int?
        var rank = 0
        return ordered.enumerated().map { index, item in
            if previous != item.total { rank = index + 1; previous = item.total }
            return (item.player, item.total, rank)
        }
    }

    static func createRound(in game: Game) -> GameRound {
        let round = GameRound(number: game.rounds.count + 1, game: game, players: game.players)
        game.rounds.append(round)
        return round
    }

    static func save(scores: [UUID: Int], for levelNumber: Int, in round: GameRound, context: ModelContext) {
        if let existing = round.levels.first(where: { $0.levelNumber == levelNumber }) {
            existing.entries.forEach(context.delete)
            existing.entries = round.participants.compactMap { participant in
                scores[participant.id].map { ScoreEntry(score: $0, participant: participant) }
            }
        } else {
            let level = LevelResult(levelNumber: levelNumber)
            level.entries = round.participants.compactMap { participant in
                scores[participant.id].map { ScoreEntry(score: $0, participant: participant) }
            }
            round.levels.append(level)
        }
        if round.levels.count == LevelDefinition.all.count { round.completedAt = .now }
        try? context.save()
    }
}
