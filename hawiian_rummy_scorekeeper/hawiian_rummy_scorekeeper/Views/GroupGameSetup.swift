#if DEBUG
import Network
import Observation
import SwiftUI

@Observable
final class GroupGameSetup {
    struct LoadKey: Equatable {
        let group: GroupSummary?
        let session: UUID
        let online: Bool
    }

    let groups: GroupsModel
    var groupID: UUID? {
        didSet {
            guard groupID != oldValue else { return }
            selection = GroupGameSelection()
            roster = nil
            loadedKey = nil
            loadIssue = nil
            saveIssue = nil
        }
    }
    var online = false
    private(set) var selection = GroupGameSelection()
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var loadIssue: String?
    private(set) var saveIssue: String?
    private var loadedKey: LoadKey?
    private var roster: GroupRosterContents?
    private var request = UUID()
    private var pending: GroupGameOperation?

    init(groups: GroupsModel) { self.groups = groups }

    var choices: [GroupSummary] { groups.account == nil || groups.isStale ? [] : groups.groups }
    var group: GroupSummary? { choices.first { $0.id == groupID } }
    var loadKey: LoadKey { LoadKey(group: group, session: groups.accountGeneration, online: online) }
    var activePlayers: [GroupPlayerIdentity] {
        loadedKey == loadKey ? roster?.players.filter { $0.retiredAt == nil } ?? [] : []
    }
    var hasLoadedRoster: Bool { loadedKey == loadKey && roster != nil }
    var canWrite: Bool { hasLoadedRoster && roster?.access.canAdd == true }
    var canEditSelection: Bool { !isSaving && pending == nil }
    var canStart: Bool { online && group != nil && canWrite && !isSaving && (pending != nil || selection.canStart) }

    func select(_ id: UUID, isSelected: Bool) {
        guard canEditSelection, activePlayers.contains(where: { $0.id == id }) else { return }
        selection.select(id, isSelected: isSelected)
    }

    func accountChanged() {
        groupID = nil
        pending = nil
        selection = GroupGameSelection()
        roster = nil
        loadedKey = nil
        saveIssue = nil
    }

    func loadRoster() async {
        guard !Task.isCancelled else { return }
        let key = loadKey
        let id = UUID()
        request = id
        loadedKey = nil
        isLoading = false
        loadIssue = nil
        guard key.online, let group = key.group else { return }
        isLoading = true
        defer { if request == id { isLoading = false } }
        do {
            let fetched = try await groups.loadRoster(for: group)
            guard request == id, key == loadKey, !Task.isCancelled else { return }
            roster = fetched
            loadedKey = key
            // An ambiguous save keeps its original ordered IDs for receipt recovery.
            if pending == nil { selection.retainActivePlayers(fetched.players) }
        } catch is CancellationError {
            return
        } catch {
            guard request == id, key == loadKey, !Task.isCancelled else { return }
            loadIssue = GroupsModel.message(for: error)
        }
    }

    func start() async -> GroupGameRoute? {
        guard canStart, let group else { return nil }
        let session = groups.accountGeneration
        let account = groups.account
        let operation = pending ?? .create(groupID: group.id, gameID: UUID(), playerIDs: selection.playerIDs)
        pending = operation
        isSaving = true
        saveIssue = nil
        defer { isSaving = false }
        do {
            let receipt = try await groups.withSharedGroup(group, session: session) { repository, account in
                try await repository.games(for: group, account: account).perform(operation)
            }
            pending = nil
            return GroupGameRoute(group: group, gameID: receipt.gameID)
        } catch {
            guard groups.account == account else { return nil }
            saveIssue = GroupsModel.message(for: error)
            if (error as? GroupGameError) == .invalidPlayers {
                pending = nil
                await loadRoster()
            } else if !groups.containsGroup(group) {
                pending = nil
            } else {
                saveIssue = (saveIssue ?? "") + " Tap Start Game again to check the same request."
            }
            return nil
        }
    }
}

struct GroupGameSetupFields: View {
    @Bindable var setup: GroupGameSetup
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasPath = false
    @ScaledMetric(relativeTo: .body) private var selectionBadgeSize: CGFloat = 34

    var body: some View {
        Section("Group") {
            if setup.groups.isRefreshing && setup.choices.isEmpty {
                ProgressView("Finding groups…")
            }
            if setup.choices.isEmpty {
                Text(setup.groups.refreshIssue ?? "Join or create a group in the Groups tab.")
                    .foregroundStyle(.secondary)
                if setup.online {
                    Button("Refresh Groups") { Task { await setup.groups.refresh() } }
                        .disabled(setup.groups.isRefreshing)
                }
            } else {
                Picker("Group", selection: $setup.groupID) {
                    Text("Choose a group").tag(nil as UUID?)
                    ForEach(setup.choices) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .disabled(!setup.canEditSelection)
            }
        }
        Section {
            Group {
                if !setup.online {
                    Text("Connect to iCloud to start a group game.").foregroundStyle(.secondary)
                } else if setup.isLoading {
                    ProgressView("Loading players…")
                } else if let issue = setup.loadIssue {
                    Text(issue).foregroundStyle(.secondary)
                    Button("Refresh Players") { Task { await setup.loadRoster() } }
                } else if setup.hasLoadedRoster && !setup.canWrite {
                    Text("Your membership allows you to view games in this group.").foregroundStyle(.secondary)
                } else if setup.hasLoadedRoster {
                    if setup.activePlayers.isEmpty {
                        Text("Add or restore players in the group's Players screen.").foregroundStyle(.secondary)
                    }
                    ForEach(setup.activePlayers) { player in
                        playerRow(player)
                    }
                }
                if setup.isSaving { ProgressView("Starting game…") }
                if let issue = setup.saveIssue { Text(issue).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Select Players")
        } footer: {
            Text("Choose at least two players in scoring order.")
        }
        .task {
            let monitor = NWPathMonitor()
            for await path in monitor {
                hasPath = path.status == .satisfied
                setup.online = hasPath && scenePhase == .active
            }
        }
        .task(id: setup.online) {
            if setup.online { await setup.groups.refresh() }
        }
        .task(id: setup.loadKey) { await setup.loadRoster() }
        .onChange(of: scenePhase) { _, phase in setup.online = hasPath && phase == .active }
        .onChange(of: setup.groups.groups) { _, groups in
            if let id = setup.groupID, !groups.contains(where: { $0.id == id }) {
                setup.accountChanged()
            }
        }
    }

    private func playerRow(_ player: GroupPlayerIdentity) -> some View {
        let position = setup.selection.playerIDs.firstIndex(of: player.id)
        return HStack {
            ZStack {
                if let position {
                    Circle().fill(Color.grammyLavender)
                    Text("\(position + 1)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.grammyPurple)
                        .accessibilityLabel("Score entry position \(position + 1)")
                }
            }
            .frame(width: selectionBadgeSize, height: selectionBadgeSize)
            Text(player.displayName)
            Spacer()
            Toggle("Select \(player.displayName)", isOn: Binding(
                get: { setup.selection.playerIDs.contains(player.id) },
                set: { setup.select(player.id, isSelected: $0) }
            ))
            .labelsHidden()
        }
        .disabled(!setup.canEditSelection)
    }
}
#endif
