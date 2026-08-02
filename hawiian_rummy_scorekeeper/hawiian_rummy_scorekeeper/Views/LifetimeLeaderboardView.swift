import SwiftUI
import SwiftData

struct LifetimeLeaderboardView: View {
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @Query private var games: [Game]

    private var completedGames: [Game] { games.filter(\.isComplete) }
    private var completedRounds: [GameRound] { games.flatMap(\.rounds).filter(\.isComplete) }

    private var rows: [LifetimeRow] {
        players.compactMap { player in
            let playerRounds = completedRounds.filter { round in
                round.participants.contains { $0.player?.id == player.id }
            }
            guard !playerRounds.isEmpty else { return nil }
            let scores = playerRounds.compactMap { round -> Int? in
                guard let participant = round.participants.first(where: { $0.player?.id == player.id }) else { return nil }
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

    private var gameWinCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for game in completedGames {
            for standing in GameRules.gameStandings(for: game) where standing.2 == 1 {
                counts[standing.0.id, default: 0] += 1
            }
        }
        return counts
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SectionIntroCard(
                        title: "Family Records",
                        subtitle: "\(completedGames.count) completed games · \(completedRounds.count) completed rounds",
                        icon: "trophy.fill"
                    )
                    .listRowBackground(Color.clear)
                }
                Section("Competitive Records") {
                    RecordRow(title: "Most Game Wins", value: gameWinsRecord)
                    RecordRow(title: "Most Round Wins", value: roundWinsRecord)
                    RecordRow(title: "Best Average Round", value: bestAverageRecord, note: "Requires at least 10 completed rounds")
                    RecordRow(title: "Best Single Round", value: bestSingleRoundRecord)
                }
                Section("Family Moments") {
                    RecordRow(title: "Most Rounds Played", value: mostRoundsRecord)
                    RecordRow(title: "Longest Winning Streak", value: longestStreakRecord)
                    RecordRow(title: "Level 7 Record", value: levelSevenRecord, note: "The wheat from the chaff")
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 6, for: .scrollContent)
            .listSectionSpacing(10)
            .background(Color.softPurpleBackground)
            .navigationTitle("Family Records")
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private var gameWinsRecord: RecordResult { countRecord(gameWinCounts, suffix: "game wins") }

    private var roundWinsRecord: RecordResult {
        countRecord(Dictionary(uniqueKeysWithValues: rows.map { ($0.player.id, $0.roundWins) }), suffix: "round wins")
    }

    private var bestAverageRecord: RecordResult {
        let qualified = rows.filter { $0.rounds >= 10 }
        guard let value = qualified.map(\.average).min() else { return RecordResult(detail: "No one qualifies yet") }
        let holders = qualified.filter { abs($0.average - value) < 0.001 }.map(\.player.id)
        return RecordResult(holders: names(for: holders), detail: "\(value.formatted(.number.precision(.fractionLength(1)))) average")
    }

    private var bestSingleRoundRecord: RecordResult {
        guard let value = rows.map(\.bestRound).min() else { return RecordResult(detail: "No completed rounds yet") }
        return RecordResult(holders: names(for: rows.filter { $0.bestRound == value }.map(\.player.id)), detail: "\(value) points")
    }

    private var mostRoundsRecord: RecordResult {
        guard let value = rows.map(\.rounds).max() else { return RecordResult(detail: "No completed rounds yet") }
        return RecordResult(holders: names(for: rows.filter { $0.rounds == value }.map(\.player.id)), detail: "\(value) rounds")
    }

    private var longestStreakRecord: RecordResult {
        var streaks: [UUID: Int] = [:]
        for row in rows {
            let playerRounds = completedRounds
                .filter { $0.participants.contains { $0.player?.id == row.player.id } }
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

    private var levelSevenRecord: RecordResult {
        let entries = completedRounds.flatMap { round in
            round.levels.first(where: { $0.levelNumber == 7 })?.entries ?? []
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

private struct LifetimeRow {
    let player: PlayerProfile
    let total: Int
    let average: Double
    let rounds: Int
    let roundWins: Int
    let bestRound: Int
}

private struct RecordRow: View {
    let title: String
    let value: RecordResult
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(value.detail).font(.body.weight(.medium))
            if !value.holders.isEmpty {
                NameChipFlowLayout(spacing: 6) {
                    ForEach(value.holders, id: \.self) { holder in
                        Text(holder)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.grammyLavender.opacity(0.7), in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordResult {
    var holders: [String] = []
    let detail: String
}

private struct NameChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}
