import SwiftData
import SwiftUI

struct RestorePlayersView: View {
    enum Scope: Identifiable {
        case all
        case matching(String)

        var id: String {
            switch self {
            case .all: "all"
            case .matching(let key): "name:" + key
            }
        }
    }

    let scope: Scope
    var onRestore: (PlayerProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.modelContext) private var context
    @Environment(\.personalDeletionTargets) private var deletionTargets
    @Environment(\.personalDeletionIssue) private var deletionIssue
    @Query(sort: \PlayerProfile.name) private var players: [PlayerProfile]
    @State private var issue: String?
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var review: DeletionReview?
    @State private var playerToRename: PlayerProfile?

    private var allowsDeletion: Bool {
        if case .all = scope { return true }
        return false
    }

    private var retiredPlayers: [PlayerProfile] {
        players.filter { player in
            guard player.isRetired, !deletionTargets.players.contains(player.id) else { return false }
            switch scope {
            case .all: return true
            case .matching(let key): return PersonalPlayers.nameKey(player.name) == key
            }
        }
    }

    private var eligibleIDs: Set<UUID> { Set(retiredPlayers.map(\.id)) }
    private var selection: Set<UUID> { selectedIDs.intersection(eligibleIDs) }

    var body: some View {
        NavigationStack {
            List {
                if selecting && textSize.isAccessibilitySize {
                    Section { selectionActions }
                }
                if let deletionIssue, allowsDeletion {
                    Text(deletionIssue).font(.footnote).foregroundStyle(.secondary)
                }
                if retiredPlayers.isEmpty {
                    Text("No players to restore.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(retiredPlayers) { player in
                            playerRow(player)
                        }
                    } header: {
                        if case .matching = scope {
                            Text("A removed player already has this name.")
                        }
                    } footer: {
                        Text("Restoring a player brings back their original profile and game history.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting && !textSize.isAccessibilitySize {
                    selectionActions
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .background(.regularMaterial)
                }
            }
            .navigationTitle(selecting ? "\(selection.count) Selected" : "Restore Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if allowsDeletion && (selecting || !retiredPlayers.isEmpty) {
                        Button(selecting ? "Cancel" : "Select") {
                            selecting.toggle()
                            selectedIDs.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !selecting {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onChange(of: eligibleIDs) { _, eligible in
                selectedIDs.formIntersection(eligible)
            }
            .alert("Couldn’t restore players", isPresented: Binding(
                get: { issue != nil }, set: { if !$0 { issue = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(issue ?? "")
            }
            .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
                deletionReview
            }
            .sheet(item: $playerToRename) { player in
                RetiredPlayerRenameView(player: player)
            }
        }
    }

    @ViewBuilder
    private func playerRow(_ player: PlayerProfile) -> some View {
        if selecting {
            let isSelected = selectedIDs.contains(player.id)
            Button {
                if isSelected {
                    selectedIDs.remove(player.id)
                } else {
                    selectedIDs.insert(player.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.grammyPurple : Color.secondary)
                        .accessibilityHidden(true)
                    playerLabel(player)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            HStack(spacing: 12) {
                playerLabel(player)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if allowsDeletion {
                    Menu {
                        Button("Restore Player", systemImage: "arrow.uturn.backward") { restore(player) }
                        Button("Rename Player", systemImage: "pencil") { playerToRename = player }
                        Button("Permanently Delete", systemImage: "trash", role: .destructive) { prepare([player.id]) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.grammyPurple)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Manage \(player.name)")
                } else {
                    Button("Restore Player") { restore(player) }
                        .frame(minHeight: 44)
                        .accessibilityLabel("Restore \(player.name)")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func playerLabel(_ player: PlayerProfile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(player.name)
            PlayerProfileHistoryLabel(player: player)
        }
        .accessibilityElement(children: .combine)
    }

    private var selectionActions: some View {
        let allSelected = !selection.isEmpty && selection == eligibleIDs
        return VStack(spacing: 6) {
            Button(allSelected ? "Deselect All" : "Select All") {
                selectedIDs = allSelected ? [] : eligibleIDs
            }
            .frame(minHeight: 44)
            .disabled(eligibleIDs.isEmpty)

            Button {
                restoreSelected()
            } label: {
                Text("Restore Selected").frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)

            Button(role: .destructive) {
                prepare(selection)
            } label: {
                Text("Permanently Delete Selected").frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .disabled(selection.isEmpty)
        }
    }

    private enum DeletionReview {
        case confirm(PersonalHistoryDeletion.Plan, changed: Bool)
        case blocked(String)
    }

    private var deletionReview: some View {
        NavigationStack {
            List {
                switch review {
                case let .confirm(plan, changed):
                    if changed {
                        Text("The affected data changed. Review the updated deletion before confirming again.")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Text("\(plan.targets.players.count) \(plan.targets.players.count == 1 ? "player" : "players")")
                        Text("\(plan.targets.games.count) \(plan.targets.games.count == 1 ? "game" : "games")")
                        Text("All rounds and scores from these games will be deleted. Other players’ lifetime statistics may change. This action cannot be undone.")
                    }
                    Section("Players") {
                        ForEach(plan.playerNames.indices, id: \.self) { Text(plan.playerNames[$0]) }
                    }
                    if !plan.gameTitles.isEmpty {
                        Section("Games") {
                            ForEach(plan.gameTitles.indices, id: \.self) { Text(plan.gameTitles[$0]) }
                        }
                    }
                    Button("Permanently Delete", role: .destructive) { confirm(plan) }
                case .blocked(let message):
                    Text(message)
                case nil:
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("Permanent Deletion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { review = nil }
                }
            }
        }
    }

    private func prepare(_ ids: Set<UUID>) {
        do {
            review = .confirm(try PersonalHistoryDeletion.prepare(players: ids, in: context.container), changed: false)
        } catch {
            showDeletionIssue(error)
        }
    }

    private func confirm(_ plan: PersonalHistoryDeletion.Plan) {
        do {
            switch try PersonalHistoryDeletion.deletePlayers(confirmed: plan, in: context.container) {
            case .deleted:
                review = nil
                selectedIDs.removeAll()
                selecting = false
            case .reviewAgain(let updated):
                review = .confirm(updated, changed: true)
            }
        } catch {
            showDeletionIssue(error)
        }
    }

    private func showDeletionIssue(_ error: Error) {
        review = .blocked((error as? PersonalHistoryDeletion.Issue)?.errorDescription
            ?? "The deletion couldn’t be saved. Please try again.")
    }

    private func restore(_ player: PlayerProfile) {
        do {
            let restored = try PersonalPlayers.restore(player, in: context)
            onRestore(restored)
            if case .matching = scope { dismiss() }
        } catch {
            issue = (error as? PersonalPlayers.Issue)?.errorDescription ?? "Your change wasn’t saved. Please try again."
        }
    }

    private func restoreSelected() {
        let ids = selection
        let candidates = retiredPlayers.filter { ids.contains($0.id) }
        do {
            let restored = try PersonalPlayers.restore(candidates, in: context)
            selectedIDs.removeAll()
            selecting = false
            restored.forEach(onRestore)
        } catch {
            issue = (error as? PersonalPlayers.Issue)?.errorDescription ?? "Your changes weren’t saved. Please try again."
        }
    }
}

private struct RetiredPlayerRenameView: View {
    let player: PlayerProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name: String
    @State private var issue: String?

    init(player: PlayerProfile) {
        self.player = player
        _name = State(initialValue: player.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .onSubmit(save)
                if let issue {
                    Text(issue).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("Rename Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(PersonalPlayers.nameKey(name).isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            try PersonalPlayers.rename(player, to: name, whileRetired: true, in: context)
            dismiss()
        } catch {
            issue = (error as? PersonalPlayers.Issue)?.errorDescription ?? "Your change wasn’t saved. Please try again."
        }
    }
}

struct PlayerProfileHistoryLabel: View {
    let player: PlayerProfile

    var body: some View {
        let date = player.createdAt.formatted(date: .abbreviated, time: .shortened)
        let count = player.games?.count ?? 0
        Text("Added \(date) · \(count) \(count == 1 ? "game" : "games")")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
