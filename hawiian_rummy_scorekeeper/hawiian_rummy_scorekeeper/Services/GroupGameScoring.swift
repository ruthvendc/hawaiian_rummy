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

    struct Draft {
        let round: Int
        let hand: Int
        let participants: [GroupGameParticipant]
        let isCorrection: Bool
        let originalValues: [UUID: String]
        var version: GroupGameVersion
        var values: [UUID: String]

        var scores: [UUID: Int]? {
            GameRules.parsedScores(for: participants.map(\.playerID), values: values)
        }
    }

    private let load: () async throws -> Detail
    private let perform: (GroupGameOperation) async throws -> GroupGameReceipt
    private let loadCandidates: () async throws -> [GroupGameScorekeeperCandidate]
    private let hasGroup: () -> Bool
    private var accessLost = false
    private var isFresh = false

    private(set) var detail: Detail?
    private(set) var draft: Draft?
    private(set) var pending: GroupGameOperation?
    private(set) var isRefreshing = false
    private(set) var isSubmitting = false
    private(set) var loadIssue: String?
    private(set) var changeIssue: String?
    private(set) var awaitingReadback = false
    private(set) var isDeleted = false
    var online = false {
        didSet { if !online { isFresh = false } }
    }

    init(
        hasGroup: @escaping () -> Bool,
        load: @escaping () async throws -> Detail,
        perform: @escaping (GroupGameOperation) async throws -> GroupGameReceipt,
        loadCandidates: @escaping () async throws -> [GroupGameScorekeeperCandidate] = { [] }
    ) {
        self.hasGroup = hasGroup
        self.load = load
        self.perform = perform
        self.loadCandidates = loadCandidates
    }

    convenience init(route: GroupGameRoute, groups: GroupsModel) {
        let session = groups.accountGeneration
        let group = route.group
        self.init {
            groups.accountGeneration == session && groups.account != nil && groups.containsGroup(group)
        } load: {
            try await groups.withSharedGroup(group, session: session) { repository, account in
                let (game, access) = try await repository.games(for: group, account: account).loadWithAccess(route.gameID)
                let key = game.header.scorekeeperKey
                let name = access.isScorekeeper(key) ? "You" : await repository.gameScorekeeperNames(for: group, account: account)[key]
                return Detail(game: game, access: access, scorekeeperName: name)
            }
        } perform: { operation in
            try await groups.withSharedGroup(group, session: session) { repository, account in
                try await repository.games(for: group, account: account).perform(operation)
            }
        } loadCandidates: {
            try await groups.withSharedGroup(group, session: session) { repository, account in
                try await repository.gameScorekeeperCandidates(for: group, account: account)
            }
        }
    }

    var canView: Bool { !accessLost && hasGroup() }
    var hasLiveSnapshot: Bool { canView && online && isFresh }
    var isBusy: Bool { isRefreshing || isSubmitting }
    private var canChange: Bool { hasLiveSnapshot && !isBusy && pending == nil }
    var canScore: Bool { canChange && detail?.canScore == true }
    var canStartChange: Bool { canScore && draft == nil }
    var managementHeader: GroupGameHeader? {
        guard canView, let detail, detail.access.role == .owner else { return nil }
        return detail.game.header
    }
    var canManage: Bool { canChange && managementHeader != nil && draft == nil }
    var canRetry: Bool { canView && online && !isBusy && pending != nil }
    var draftNeedsReview: Bool {
        guard let draft, let game = detail?.game else { return false }
        return draft.version != game.header.version
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
        guard !isBusy else { return }
        await reload()
    }

    func discardInaccessibleGame() {
        detail = nil
        draft = nil
        pending = nil
        loadIssue = nil
        changeIssue = nil
        awaitingReadback = false
        isFresh = false
        isDeleted = false
    }

    func beginScores(round number: Int, hand: Int) {
        guard canStartChange, let game = detail?.game, let round = round(number: number),
              acceptsHand(hand, in: round) else { return }
        let existing = round.hands.first { $0.number == hand }
        let values = Dictionary(uniqueKeysWithValues: (existing?.scores ?? []).map { ($0.playerID, String($0.points)) })
        draft = Draft(round: number, hand: hand, participants: game.header.participants, isCorrection: existing != nil,
                      originalValues: values, version: game.header.version, values: values)
        changeIssue = nil
    }

    func updateScore(for id: UUID, value: String) {
        guard pending == nil, !isSubmitting, detail?.canScore == true else { return }
        draft?.values[id] = value
    }

    func closeDraft() {
        guard pending == nil, !isSubmitting else { return }
        draft = nil
    }

    func reviewDraft() {
        guard canReviewDraft, let version = detail?.game.header.version else { return }
        draft?.version = version
        changeIssue = nil
    }

    func saveDraft() async {
        guard canSaveDraft, let draft, let scores = draft.scores else { return }
        await submit(.saveHand(round: draft.round, hand: GroupGameHand(number: draft.hand, scores: scores)),
                     version: draft.version)
    }

    func advance(from version: GroupGameVersion) async {
        guard canStartChange, detail?.game.rounds.last?.hands.count == LevelDefinition.all.count else { return }
        await submit(.startNextRound, version: version)
    }

    func complete(from version: GroupGameVersion) async {
        guard canStartChange else { return }
        await submit(.complete, version: version)
    }

    func scorekeeperCandidates() async throws -> [GroupGameScorekeeperCandidate] {
        guard canManage else { throw GroupGameError.invalidTransition }
        return try await loadCandidates()
    }

    func reassignScorekeeper(_ key: String, from version: GroupGameVersion) async {
        await submit(.reassignScorekeeper(participantKey: key), version: version)
    }

    func cancel(from version: GroupGameVersion) async {
        await submit(.cancel, version: version)
    }

    func delete(from version: GroupGameVersion) async {
        await submit(.delete, version: version)
    }

    func retry() async {
        guard canRetry, let pending else { return }
        await submit(pending)
    }

    private func round(number: Int) -> GroupGameRound? {
        detail?.game.rounds.first { $0.id.number == number }
    }

    private func acceptsHand(_ hand: Int, in round: GroupGameRound) -> Bool {
        (1...LevelDefinition.all.count).contains(hand) &&
            (hand <= round.hands.count ||
             (round.id == detail?.game.rounds.last?.id && hand == round.hands.count + 1))
    }

    private func submit(_ action: GroupGameOperation.Action, version: GroupGameVersion) async {
        guard action.requiresOwner ? canManage : canScore, let header = detail?.game.header else { return }
        guard header.version == version else {
            changeIssue = "This game changed. Review the latest scores before trying again."
            return
        }
        await submit(GroupGameOperation(id: UUID(), groupID: header.groupID, gameID: header.id,
                                        expectedVersion: version, action: action))
    }

    private func submit(_ operation: GroupGameOperation) async {
        pending = operation
        isFresh = false
        isSubmitting = true
        changeIssue = nil
        defer { isSubmitting = false }

        do {
            _ = try await perform(operation)
            guard canView else { discardInaccessibleGame(); return }
            pending = nil
            if case .saveHand = operation.action { draft = nil }
            awaitingReadback = true
            if case .delete = operation.action { markDeleted() }
            await reload()
        } catch {
            guard handleAccess(error) else { return }
            switch error {
            case GroupGameError.staleGame:
                pending = nil
                changeIssue = operation.action.requiresOwner
                    ? "The game or group membership changed. Review the latest information before trying again."
                    : "This game changed on another device. Review the latest saved scores before trying again."
                await reload()
            case GroupGameError.gameDeleted:
                pending = nil
                markDeleted()
            case GroupGameError.notScorekeeper, GroupRosterError.notAuthorized, GroupGameError.invalidTransition,
                 GroupGameError.gameNotFound, GroupGameError.invalidScores, GroupGameError.scorekeeperUnavailable,
                 GroupGameError.deletionTooLarge:
                pending = nil
                if (error as? GroupRosterError) == .notAuthorized {
                    changeIssue = operation.action.requiresOwner
                        ? "Only the group owner can manage this game."
                        : "Your group membership no longer allows score changes."
                } else {
                    changeIssue = GroupsModel.message(for: error)
                }
                await reload()
            default:
                // Transport, authorization readback and cancellation errors can mask a committed write.
                changeIssue = "Couldn’t confirm the change. Retry to check the same request."
            }
        }
    }

    private func reload() async {
        guard canView, online, !Task.isCancelled else { return }
        isFresh = false
        isRefreshing = true
        loadIssue = nil
        defer { isRefreshing = false }
        do {
            let loaded = try await load()
            guard canView, !Task.isCancelled else { return }
            detail = loaded
            isFresh = online
            awaitingReadback = false
        } catch is CancellationError {
            return
        } catch {
            guard handleAccess(error), !Task.isCancelled else { return }
            switch error {
            case GroupGameError.gameDeleted:
                markDeleted()
            case GroupGameError.gameNotFound:
                detail = nil
                loadIssue = GroupsModel.message(for: error)
            default:
                loadIssue = GroupsModel.message(for: error)
            }
        }
    }

    private func markDeleted() {
        detail = nil
        draft = nil
        awaitingReadback = false
        loadIssue = nil
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
