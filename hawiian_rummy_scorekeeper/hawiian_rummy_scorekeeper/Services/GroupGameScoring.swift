#if DEBUG
import Foundation
import Observation

@Observable
final class GroupGameScoring {
    struct Detail {
        let game: GroupGameSnapshot
        let access: GroupRosterAccess
        let scorekeeperName: String?

        var canScore: Bool {
            game.header.status == .inProgress && access.canAdd && access.isScorekeeper(game.header.scorekeeperKey)
        }
    }

    struct EditVersion: Equatable {
        let confirmed: GroupGameVersion
        let local: UUID
    }

    struct Draft {
        let round: Int
        let hand: Int
        let participants: [GroupGameParticipant]
        let isCorrection: Bool
        let originalValues: [UUID: String]
        var version: EditVersion
        var values: [UUID: String]

        var scores: [UUID: Int]? {
            GameRules.parsedScores(for: participants.map(\.playerID), values: values)
        }
    }

    private let load: () async throws -> Detail
    private let perform: (GroupGameOperation) async throws -> GroupGameReceipt
    private let loadCandidates: () async throws -> [GroupGameScorekeeperCandidate]
    private let hasGroup: () -> Bool
    private let journal: () throws -> GroupGameJournal.Game
    private var saved: GroupGameJournal.Entry?
    private var showsLocalScorecard = false
    private var ownerPending: GroupGameOperation?
    private var awaitingOwnerReadback = false
    private var accessLost = false
    private var isFresh = false

    private(set) var detail: Detail?
    private(set) var draft: Draft?
    private(set) var isRefreshing = false
    private(set) var isSubmitting = false
    private(set) var loadIssue: String?
    private(set) var changeIssue: String?
    private(set) var isDeleted = false
    var online = false {
        didSet { if !online { isFresh = false } }
    }

    init(
        hasGroup: @escaping () -> Bool,
        load: @escaping () async throws -> Detail,
        perform: @escaping (GroupGameOperation) async throws -> GroupGameReceipt,
        journal: @escaping () throws -> GroupGameJournal.Game,
        loadCandidates: @escaping () async throws -> [GroupGameScorekeeperCandidate] = { [] }
    ) {
        self.hasGroup = hasGroup
        self.load = load
        self.perform = perform
        self.journal = journal
        self.loadCandidates = loadCandidates
    }

    convenience init(route: GroupGameRoute, groups: GroupsModel) {
        let account = groups.scoringAccount ?? groups.account
        let group = route.group
        let hasGroup = {
            account != nil && groups.scoringAccount == account && groups.containsGroup(group)
        }
        self.init(hasGroup: hasGroup) {
            guard hasGroup() else { throw GroupRepositoryError.accountChanged }
            return try await groups.withSharedGroup(group, session: groups.accountGeneration) { repository, account in
                let (game, access) = try await repository.games(for: group, account: account).loadWithAccess(route.gameID)
                let key = game.header.scorekeeperKey
                let name = access.isScorekeeper(key) ? "You" : await repository.gameScorekeeperNames(for: group, account: account)[key]
                return Detail(game: game, access: access, scorekeeperName: name)
            }
        } perform: { operation in
            guard hasGroup() else { throw GroupRepositoryError.accountChanged }
            return try await groups.withSharedGroup(group, session: groups.accountGeneration) { repository, account in
                try await repository.games(for: group, account: account).perform(operation)
            }
        } journal: {
            try groups.gameJournal(for: route, account: account)
        } loadCandidates: {
            guard hasGroup() else { throw GroupRepositoryError.accountChanged }
            return try await groups.withSharedGroup(group, session: groups.accountGeneration) { repository, account in
                try await repository.gameScorekeeperCandidates(for: group, account: account)
            }
        }
    }

    var canView: Bool { !accessLost && hasGroup() }
    var hasLiveSnapshot: Bool { canView && online && isFresh }
    var isBusy: Bool { isRefreshing || isSubmitting }
    var canScore: Bool {
        canView && !isBusy && ownerPending == nil && showsLocalScorecard && detail?.canScore == true && saved?.needsReview == false
    }
    var canStartChange: Bool { canScore && draft == nil }
    var editVersion: EditVersion? {
        guard let saved, let header = detail?.game.header, showsLocalScorecard else { return nil }
        return EditVersion(confirmed: header.version, local: saved.editID)
    }
    var managementHeader: GroupGameHeader? {
        guard canView, let detail, detail.access.role == .owner else { return nil }
        return detail.game.header
    }
    var canManage: Bool {
        hasLiveSnapshot && !isBusy && ownerPending == nil && managementHeader != nil && draft == nil &&
            saved?.operations.isEmpty != false
    }
    var pending: GroupGameOperation? {
        if let ownerPending { return ownerPending }
        guard let head = saved?.operations.first, head.state == .pendingConfirmation else { return nil }
        return head.request
    }
    var canRetry: Bool { canView && online && !isBusy && pending != nil }
    var awaitingReadback: Bool {
        if awaitingOwnerReadback { return true }
        if case .synced = saved?.operations.first?.state { return true }
        return false
    }
    var syncStatus: String? {
        if let saved { return saved.syncStatus }
        return detail == nil ? nil : "Synced"
    }
    var draftNeedsReview: Bool {
        guard let draft, let editVersion else { return false }
        return draft.version != editVersion
    }
    var savedDraftHand: GroupGameHand? {
        guard let draft, let round = round(number: draft.round) else { return nil }
        return round.hands.first { $0.number == draft.hand }
    }
    var canReviewDraft: Bool {
        guard canScore, let draft, let round = round(number: draft.round), draftNeedsReview else { return false }
        return acceptsHand(draft.hand, in: round)
    }
    var canSaveDraft: Bool { canScore && !draftNeedsReview && draft?.scores != nil }

    func refresh() async {
        guard canView, !isBusy else { return }
        restoreJournal()
        await reload()
    }

    func discardInaccessibleGame() {
        detail = nil
        draft = nil
        saved = nil
        showsLocalScorecard = false
        ownerPending = nil
        loadIssue = nil
        changeIssue = nil
        awaitingOwnerReadback = false
        isFresh = false
        isDeleted = false
    }

    func beginScores(round number: Int, hand: Int) {
        guard canStartChange, let game = detail?.game, let version = editVersion,
              let round = round(number: number), acceptsHand(hand, in: round) else { return }
        let existing = round.hands.first { $0.number == hand }
        let values = Dictionary(uniqueKeysWithValues: (existing?.scores ?? []).map { ($0.playerID, String($0.points)) })
        draft = Draft(round: number, hand: hand, participants: game.header.participants, isCorrection: existing != nil,
                      originalValues: values, version: version, values: values)
        changeIssue = nil
    }

    func updateScore(for id: UUID, value: String) {
        guard !isSubmitting, canView, detail?.canScore == true else { return }
        draft?.values[id] = value
    }

    func closeDraft() {
        guard !isSubmitting else { return }
        draft = nil
    }

    func reviewDraft() {
        guard canReviewDraft, let editVersion else { return }
        draft?.version = editVersion
        changeIssue = nil
    }

    func saveDraft() async {
        guard canSaveDraft, let draft, let scores = draft.scores else { return }
        await saveScore(.saveHand(round: draft.round, hand: GroupGameHand(number: draft.hand, scores: scores)),
                        from: draft.version)
    }

    func advance(from version: EditVersion) async {
        guard canStartChange, detail?.game.rounds.last?.hands.count == LevelDefinition.all.count else { return }
        await saveScore(.startNextRound, from: version)
    }

    func complete(from version: EditVersion) async {
        guard canStartChange else { return }
        await saveScore(.complete, from: version)
    }

    func scorekeeperCandidates() async throws -> [GroupGameScorekeeperCandidate] {
        guard canManage else { throw GroupGameError.invalidTransition }
        return try await loadCandidates()
    }

    func reassignScorekeeper(_ key: String, from version: GroupGameVersion) async {
        await manage(.reassignScorekeeper(participantKey: key), from: version)
    }

    func cancel(from version: GroupGameVersion) async {
        await manage(.cancel, from: version)
    }

    func delete(from version: GroupGameVersion) async {
        await manage(.delete, from: version)
    }

    func retry() async {
        guard canRetry, let pending else { return }
        if ownerPending != nil {
            await sendManagement(pending)
        } else {
            do {
                let local = try journal()
                let current = try local.load()
                guard let head = current?.operations.first,
                      head.request.id == pending.id, head.state == .pendingConfirmation else {
                    await refresh()
                    return
                }
                isSubmitting = true
                changeIssue = nil
                defer { isSubmitting = false }
                await sendScore(head.request, in: local)
            } catch {
                changeIssue = "Couldn’t open saved scoring on this iPhone."
            }
        }
    }

    private func round(number: Int) -> GroupGameRound? {
        detail?.game.rounds.first { $0.id.number == number }
    }

    private func acceptsHand(_ hand: Int, in round: GroupGameRound) -> Bool {
        (1...LevelDefinition.all.count).contains(hand) &&
            (hand <= round.hands.count ||
             (round.id == detail?.game.rounds.last?.id && hand == round.hands.count + 1))
    }

    private func saveScore(_ action: GroupGameOperation.Action, from version: EditVersion) async {
        guard editVersion == version else {
            changeIssue = GroupGameJournalError.staleEditor.localizedDescription
            return
        }
        let submitImmediately = hasLiveSnapshot
        isSubmitting = true
        changeIssue = nil
        defer { isSubmitting = false }
        do {
            let local = try journal()
            let entry = try local.append(action, editID: version.local, submitImmediately: submitImmediately)
            if case .saveHand = action { draft = nil }
            try showLocal(entry)
            if let operation = entry.operations.last, operation.state == .pendingConfirmation {
                isFresh = false
                await sendScore(operation.request, in: local)
            }
        } catch GroupGameJournalError.staleEditor {
            restoreJournal()
            changeIssue = GroupGameJournalError.staleEditor.localizedDescription
        } catch {
            changeIssue = "Couldn’t save the change on this iPhone. Try again."
        }
    }

    private func sendScore(_ operation: GroupGameOperation, in local: GroupGameJournal.Game) async {
        do {
            let receipt = try await perform(operation)
            do {
                saved = try local.acknowledge(receipt)
            } catch {
                changeIssue = "CloudKit confirmed the change, but this iPhone couldn’t update the journal. Retry to check the same request."
                return
            }
            guard canView else { discardInaccessibleGame(); return }
            await reload()
        } catch {
            if Self.isDefinitiveRejection(error) {
                let hide = Self.hidesLocalGame(error)
                flagLocalChange(in: local, operationID: operation.id, hide: hide)
                changeIssue = GroupsModel.message(for: error)
                guard handleAccess(error) else { return }
                if (error as? GroupGameError) == .gameDeleted { markDeleted() } else { await reload() }
            } else if handleAccess(error) {
                changeIssue = "Couldn’t confirm the change. Retry to check the same request."
            }
        }
    }

    private func manage(_ action: GroupGameOperation.Action, from version: GroupGameVersion) async {
        guard canManage, let header = managementHeader else { return }
        guard header.version == version else {
            changeIssue = "This game changed. Review the latest information before trying again."
            return
        }
        await sendManagement(GroupGameOperation(id: UUID(), groupID: header.groupID, gameID: header.id,
                                                expectedVersion: version, action: action))
    }

    private func sendManagement(_ operation: GroupGameOperation) async {
        let local = try? journal()
        ownerPending = operation
        isFresh = false
        isSubmitting = true
        changeIssue = nil
        defer { isSubmitting = false }
        do {
            _ = try await perform(operation)
            if case .delete = operation.action {
                flagLocalChange(in: local, hide: true)
                markDeleted()
            }
            guard canView else { discardInaccessibleGame(); return }
            ownerPending = nil
            awaitingOwnerReadback = true
            await reload()
        } catch {
            guard handleAccess(error) else { return }
            switch error {
            case GroupGameError.staleGame, GroupGameError.scorekeeperUnavailable, GroupGameError.deletionTooLarge,
                 GroupGameError.notScorekeeper, GroupGameError.invalidTransition, GroupGameError.gameNotFound,
                 GroupRosterError.notAuthorized:
                ownerPending = nil
                changeIssue = GroupsModel.message(for: error)
                await reload()
            case GroupGameError.gameDeleted:
                ownerPending = nil
                flagLocalChange(in: local, hide: true)
                markDeleted()
            default:
                changeIssue = "Couldn’t confirm the change. Retry to check the same request."
            }
        }
    }

    private func restoreJournal() {
        do {
            saved = try journal().load()
            if let saved, saved.canResume {
                let version = saved.confirmed.header.version
                let displayed = detail?.game.header.version
                if !hasLiveSnapshot || version == displayed || version.revision > (displayed?.revision ?? 0) {
                    if version != displayed { isFresh = false }
                    try showLocal(saved)
                } else {
                    showsLocalScorecard = false
                }
            } else if showsLocalScorecard {
                detail = nil
                showsLocalScorecard = false
            }
        } catch {
            showsLocalScorecard = false
            loadIssue = "Couldn’t open saved scoring on this iPhone."
        }
    }

    private func showLocal(_ entry: GroupGameJournal.Entry) throws {
        detail = Detail(game: try entry.scorecard(), access: entry.access, scorekeeperName: "You")
        saved = entry
        showsLocalScorecard = true
        isDeleted = false
    }

    private func reload() async {
        guard canView, online, !Task.isCancelled else { return }
        let local = try? journal()
        isFresh = false
        isRefreshing = true
        loadIssue = nil
        defer { isRefreshing = false }
        do {
            let loaded = try await load()
            guard canView, !Task.isCancelled else { return }
            detail = loaded
            showsLocalScorecard = false
            isFresh = online
            isDeleted = false
            awaitingOwnerReadback = false
            do {
                guard let local else { throw GroupGameJournalError.unavailable }
                saved = try local.recordConfirmed(loaded.game, access: loaded.access)
                if let saved, saved.canResume, !saved.needsReview,
                   saved.confirmed.header.version == loaded.game.header.version {
                    try showLocal(saved)
                }
            } catch {
                loadIssue = "Couldn’t save this scorecard on this iPhone."
            }
        } catch is CancellationError {
            return
        } catch {
            if Self.hidesLocalGame(error) { flagLocalChange(in: local, hide: true) }
            guard handleAccess(error), !Task.isCancelled else { return }
            switch error {
            case GroupGameError.gameDeleted:
                markDeleted()
            case GroupGameError.gameNotFound:
                detail = nil
                showsLocalScorecard = false
                loadIssue = GroupsModel.message(for: error)
            default:
                loadIssue = GroupsModel.message(for: error)
            }
        }
    }

    private func flagLocalChange(in local: GroupGameJournal.Game?, operationID: UUID? = nil, hide: Bool = false) {
        guard let local else { return }
        do {
            saved = try local.flagForReview(operationID: operationID, hide: hide)
        } catch {
            loadIssue = "Couldn’t update the local scoring journal."
        }
        showsLocalScorecard = false
    }

    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        switch error {
        case GroupGameError.staleGame, GroupGameError.gameDeleted, GroupGameError.gameNotFound,
             GroupGameError.notScorekeeper, GroupGameError.invalidTransition, GroupGameError.invalidScores,
             GroupGameError.reusedOperation, GroupRosterError.notAuthorized, GroupRosterError.accessLost:
            true
        default:
            false
        }
    }

    private static func hidesLocalGame(_ error: Error) -> Bool {
        switch error {
        case GroupGameError.gameDeleted, GroupGameError.gameNotFound, GroupRosterError.accessLost: true
        default: false
        }
    }

    private func markDeleted() {
        detail = nil
        draft = nil
        showsLocalScorecard = false
        awaitingOwnerReadback = false
        isFresh = false
        isDeleted = true
    }

    private func handleAccess(_ error: Error) -> Bool {
        if (error as? GroupRosterError) == .accessLost { accessLost = true }
        guard canView else {
            discardInaccessibleGame()
            return false
        }
        return true
    }
}
#endif
