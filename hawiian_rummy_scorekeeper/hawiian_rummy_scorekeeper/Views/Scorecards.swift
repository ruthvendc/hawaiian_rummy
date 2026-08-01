import SwiftUI

struct RoundResultsView: View {
    let round: GameRound

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Round \(round.number) Winner").font(.headline)
            ForEach(GameRules.standings(for: round)) { standing in
                HStack {
                    Text("\(standing.rank). \(standing.participant.displayName)")
                    Spacer()
                    if standing.isLeader { LeaderBadge() }
                    Text("\(standing.total)").monospacedDigit().bold()
                }
            }
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        LevelScoreMatrixView(round: round)
    }
}

struct LevelScoreMatrixView: View {
    let round: GameRound

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Level-by-Level Scores").font(.headline)
            Text("Swipe sideways to see every player.").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        matrixCell("Level", width: 70, emphasized: true)
                        ForEach(round.participants) { participant in
                            matrixCell(participant.displayName, width: 118, emphasized: true)
                        }
                    }
                    ForEach(LevelDefinition.all) { definition in
                        let level = round.levels.first { $0.levelNumber == definition.number }
                        HStack(spacing: 0) {
                            matrixCell("\(definition.number)", width: 70, emphasized: true)
                            ForEach(round.participants) { participant in
                                let score = level?.entries.first { $0.participant?.id == participant.id }?.score
                                matrixCell(score.map(String.init) ?? "—", width: 118, emphasized: false)
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        matrixCell("Total", width: 70, emphasized: true)
                        ForEach(round.participants) { participant in
                            matrixCell("\(GameRules.score(for: participant, in: round))", width: 118, emphasized: true)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            }
            .scrollIndicators(.visible)
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func matrixCell(_ text: String, width: CGFloat, emphasized: Bool) -> some View {
        Text(text)
            .font(emphasized ? .subheadline.weight(.semibold) : .body.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, height: 44)
            .padding(.horizontal, 6)
            .background(emphasized ? Color.grammyLavender.opacity(0.5) : Color.clear)
            .overlay(Rectangle().stroke(.quaternary, lineWidth: 0.5))
            .accessibilityLabel(text)
    }
}

struct OverallStandingsView: View {
    let game: Game
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text("All rounds played so far · lowest total leads")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(GameRules.gameStandings(for: game), id: \.0.id) { player, total, rank in
                HStack {
                    Text("\(rank). \(player.name)")
                    Spacer()
                    if rank == 1 { LeaderBadge() }
                    Text("\(total)").monospacedDigit().bold()
                }
            }
        }
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct GameFinalView: View {
    let game: Game
    @State private var correction: LevelCorrection?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Game Complete").font(.largeTitle.bold())
            let standings = GameRules.gameStandings(for: game)
            if !standings.isEmpty {
                Text(standings.filter { $0.2 == 1 }.map { $0.0.name }.joined(separator: " & ") + " won!")
                    .font(.title2.bold()).foregroundStyle(Color.grammyPurple)
                Text("Lowest total score across \(game.rounds.count) rounds").foregroundStyle(.secondary)
            }
            OverallStandingsView(game: game, title: "Final Standings")
            Rectangle()
                .fill(Color.grammyPurple.opacity(0.35))
                .frame(height: 1)
                .padding(.vertical, 8)
            Text("Round-by-Round Results")
                .font(.title3.bold())
            ForEach(game.sortedRounds) { RoundResultsView(round: $0) }
            Menu("Correct a Completed Level") {
                ForEach(game.sortedRounds) { round in
                    ForEach(round.sortedLevels) { level in
                        Button("Round \(round.number), Level \(level.levelNumber)") {
                            correction = LevelCorrection(round: round, levelNumber: level.levelNumber)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .sheet(item: $correction) { correction in
            ScoreEntryView(round: correction.round, levelNumber: correction.levelNumber)
        }
    }
}

private struct LevelCorrection: Identifiable {
    let round: GameRound
    let levelNumber: Int
    var id: String { "\(round.id.uuidString)-\(levelNumber)" }
}
