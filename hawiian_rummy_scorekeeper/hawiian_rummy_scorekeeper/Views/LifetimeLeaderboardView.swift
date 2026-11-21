import SwiftUI
import SwiftData

struct LifetimeLeaderboardView: View {
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @Query private var games: [Game]

    @Environment(\.personalDeletionTargets) private var deletionTargets

    private var records: LifetimeRecords {
        LifetimeRecords(players: players.filter { !deletionTargets.players.contains($0.id) },
                        games: games.filter { !deletionTargets.games.contains($0.id) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SectionIntroCard(
                        title: "Family Records",
                        subtitle: "\(records.completedGameCount) completed games · \(records.completedRoundCount) completed rounds",
                        icon: "trophy.fill"
                    )
                    .listRowBackground(Color.clear)
                }
                Section("Competitive Records") {
                    RecordRow(title: "Most Game Wins", value: records.gameWinsRecord)
                    RecordRow(title: "Most Round Wins", value: records.roundWinsRecord)
                    RecordRow(title: "Best Average Round", value: records.bestAverageRecord, note: "Requires at least 10 completed rounds")
                    RecordRow(title: "Best Single Round", value: records.bestSingleRoundRecord)
                }
                Section("Family Moments") {
                    RecordRow(title: "Most Rounds Played", value: records.mostRoundsRecord)
                    RecordRow(title: "Longest Winning Streak", value: records.longestStreakRecord)
                    RecordRow(title: "Level 7 Record", value: records.levelSevenRecord, note: "The wheat from the chaff")
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 6, for: .scrollContent)
            .listSectionSpacing(10)
            .background(Color.softPurpleBackground)
            .navigationTitle("Family Records")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.softPurpleBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

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
