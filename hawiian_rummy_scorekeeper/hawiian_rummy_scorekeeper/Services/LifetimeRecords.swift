import Foundation

struct LifetimeRecords {
    let players: [PlayerProfile]
    let games: [Game]

    var completedGames: [Game] { games.filter(\.isComplete) }
    var completedRounds: [GameRound] { games.flatMap { $0.rounds ?? [] }.filter(\.isComplete) }

    var rows: [LifetimeRow] {
        players.compactMap { player in
            let playerRounds = completedRounds.filter { round in
                (round.participants ?? []).contains { $0.player?.id == player.id }
            }
            guard !playerRounds.isEmpty else { return nil }
            let scores = playerRounds.compactMap { round -> Int? in
                guard let participant = round.participants?.first(where: { $0.player?.id == player.id }) else { return nil }
                return GameRules.score(for: participant, in: round)
            }
            let roundWins = playerRounds.filter { round in
                GameRules.standings(for: round).contains { $0.isLeader && $0.participant.player?.id == player.id }
            }.count
            return LifetimeRow(
                player: player,
                total: scores.reduce(0, +),
                average: Double(scores.reduce(0, +)) / Double(scores.count),
                rounds: scores.count,
                roundWins: roundWins,
                bestRound: scores.min() ?? 0
            )
        }
    }

    var gameWinCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for game in completedGames {
            for standing in GameRules.gameStandings(for: game) where standing.2 == 1 {
                counts[standing.0.id, default: 0] += 1
            }
        }
        return counts
    }

    var completedGameCount: Int { completedGames.count }
    var completedRoundCount: Int { completedRounds.count }

    var gameWinsRecord: RecordResult { countRecord(gameWinCounts, suffix: "game wins") }

    var roundWinsRecord: RecordResult {
        countRecord(Dictionary(uniqueKeysWithValues: rows.map { ($0.player.id, $0.roundWins) }), suffix: "round wins")
    }

    var bestAverageRecord: RecordResult {
        let qualified = rows.filter { $0.rounds >= 10 }
        guard let value = qualified.map(\.average).min() else { return RecordResult(detail: "No one qualifies yet") }
        let holders = qualified.filter { abs($0.average - value) < 0.001 }.map(\.player.id)
        return RecordResult(holders: names(for: holders), detail: "\(value.formatted(.number.precision(.fractionLength(1)))) average")
    }

    var bestSingleRoundRecord: RecordResult {
        guard let value = rows.map(\.bestRound).min() else { return RecordResult(detail: "No completed rounds yet") }
        return RecordResult(holders: names(for: rows.filter { $0.bestRound == value }.map(\.player.id)), detail: "\(value) points")
    }

    var mostRoundsRecord: RecordResult {
        guard let value = rows.map(\.rounds).max() else { return RecordResult(detail: "No completed rounds yet") }
        return RecordResult(holders: names(for: rows.filter { $0.rounds == value }.map(\.player.id)), detail: "\(value) rounds")
    }

    var longestStreakRecord: RecordResult {
        var streaks: [UUID: Int] = [:]
        for row in rows {
            let playerRounds = completedRounds
                .filter { ($0.participants ?? []).contains { $0.player?.id == row.player.id } }
                .sorted { $0.createdAt < $1.createdAt }
            var current = 0
            var longest = 0
            for round in playerRounds {
                let won = GameRules.standings(for: round).contains { $0.isLeader && $0.participant.player?.id == row.player.id }
                current = won ? current + 1 : 0
                longest = max(longest, current)
            }
            streaks[row.player.id] = longest
        }
        return countRecord(streaks, suffix: "rounds in a row")
    }

    var levelSevenRecord: RecordResult {
        let entries = completedRounds.flatMap { round in
            round.levels?.first(where: { $0.levelNumber == 7 })?.entries ?? []
        }
        guard let value = entries.map(\.score).min() else { return RecordResult(detail: "No Level 7 scores yet") }
        let holderIDs = entries.filter { $0.score == value }.compactMap { $0.participant?.player?.id }
        return RecordResult(holders: names(for: holderIDs), detail: "\(value) points")
    }

    private func countRecord(_ counts: [UUID: Int], suffix: String) -> RecordResult {
        guard let value = counts.values.max(), value > 0 else { return RecordResult(detail: "No record yet") }
        let holders = counts.filter { $0.value == value }.map(\.key)
        return RecordResult(holders: names(for: holders), detail: "\(value) \(suffix)")
    }

    private func names(for ids: [UUID]) -> [String] {
        let uniqueIDs = Set(ids)
        return players.filter { uniqueIDs.contains($0.id) }.map(\.name).sorted()
    }
}

struct LifetimeRow {
    let player: PlayerProfile
    let total: Int
    let average: Double
    let rounds: Int
    let roundWins: Int
    let bestRound: Int
}

struct RecordResult: Equatable {
    var holders: [String] = []
    let detail: String
}

