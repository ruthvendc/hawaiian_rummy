#if DEBUG
import CloudKit
import Foundation
import Observation

enum PendingInvitationState: Equatable {
    case waiting, joining, joined, needsVerification, unavailable, retrying
}

enum GroupRosterChange {
    case add(GroupPlayerDraft)
    case rename(GroupPlayerIdentity, String)
    case setRetired(GroupPlayerIdentity, Bool)
}

@Observable
final class GroupsModel {
    private enum DiscoveryInterrupted: LocalizedError {
        case contextChanged

        var errorDescription: String? { "Groups discovery was interrupted. Showing saved groups where available." }
    }

    @ObservationIgnored private lazy var repository = GroupRepository(containerIdentifier: containerIdentifier)
    @ObservationIgnored private lazy var cache = try? GroupCache(url: cacheURL)
    @ObservationIgnored private var scoringJournal: GroupGameJournal?
    private let containerIdentifier: String
    private let cacheURL: URL?
    private let journalURL: URL?

    private(set) var account: String?
    private(set) var scoringAccount: String?
    private(set) var snapshot = GroupCacheSnapshot()
    private(set) var isStale = false
    private(set) var isRefreshing = false
    private(set) var isWorking = false
    private(set) var refreshIssue: String?
    private(set) var cacheIssue: String?
    private(set) var nativeInvitation: CKShare.Metadata?
    private(set) var invitationRoute = 0
    private(set) var invitationIssue: String?
    private var invitationStates: [String: PendingInvitationState] = [:]
    private var retryInvitationAfter: [String: Date] = [:]
    private var nativeRefreshQueued = false
    private var discoveryRefreshQueued = false
    private var discoveryPathAvailable: Bool?
    private var discoveryPathGeneration = UUID()
    private var groupCacheGeneration = UUID()
    var actionIssue: String?

    private var generation = UUID()
    @ObservationIgnored private var rosterRequests: [UUID: UUID] = [:]
    @ObservationIgnored private var rosterWrites: [UUID: UUID] = [:]

    var groups: [GroupSummary] { snapshot.groups }
    var accountGeneration: UUID { generation }

    init(containerIdentifier: String, cacheURL: URL? = nil, journalURL: URL? = nil) {
        self.containerIdentifier = containerIdentifier
        self.cacheURL = cacheURL
        self.journalURL = journalURL
    }

    func updateDiscoveryPath(available: Bool) {
        discoveryPathAvailable = available
        discoveryPathGeneration = UUID()
        discoveryRefreshQueued = true
        if !available { isStale = !groups.isEmpty }
    }

    func receive(_ metadata: CKShare.Metadata) -> Bool {
        guard repository.acceptsMetadata(metadata) else { return false }
        nativeInvitation = metadata
        nativeRefreshQueued = true
        invitationIssue = nil
        invitationRoute += 1
        return true
    }

    func accountDidChange() async {
        prepareForAccountRefresh()
        await refresh()
    }

    // Availability changes also post CKAccountChanged. Cancel responses from the old
    // session, then resolve the account before deciding whether its cache must be hidden.
    func prepareForAccountRefresh() {
        generation = UUID()
        scoringAccount = nil
        isRefreshing = false
        isWorking = false
        isStale = !groups.isEmpty
        GroupAccountLaunchDiagnostic.activeTrace?.record("Account notification · scoring identity awaiting verification · memory kept \(GroupAccountLaunchDiagnostic.groupSummary(groups))")
    }

    func refresh() async {
        await synchronizeGroups()
    }

    func pollPendingInvitations() async {
        await synchronizeGroups(pendingOnly: true)
    }

    private func synchronizeGroups(pendingOnly: Bool = false) async {
        guard !isRefreshing, !isWorking else { return }
        repeat {
            let invitationsOnly = pendingOnly && !discoveryRefreshQueued
            nativeRefreshQueued = false
            discoveryRefreshQueued = false
            let diagnostic = invitationsOnly ? nil : GroupAccountLaunchDiagnostic.shared.begin()
            let trace = GroupAccountLaunchDiagnostic.activeTrace?.startRefresh(pendingOnly: invitationsOnly, groups: groups)
            await refresh(
                accountID: { try await self.repository.accountID(diagnostic: diagnostic?.takeInitialLookup()) },
                discover: { try await self.repository.discoverGroups(trace: trace) },
                confirmRemoval: { group, account in try await self.repository.confirmGroupRemoval(group, account: account) },
                resolveInvitation: { url, account in
                    let metadata = try await self.repository.invitationMetadata(for: url)
                    return try await self.repository.accept(metadata, account: account)
                },
                pendingOnly: invitationsOnly,
                diagnostic: diagnostic,
                trace: trace
            )
        } while (nativeRefreshQueued || discoveryRefreshQueued) && !Task.isCancelled && !isWorking && !isRefreshing
    }

    func refresh(
        accountID: () async throws -> String,
        discover: () async throws -> GroupDiscoveryResult,
        confirmRemoval: (GroupSummary, String) async throws -> Bool = { _, _ in false },
        resolveInvitation: ((URL, String) async throws -> UUID)? = nil,
        pendingOnly: Bool = false,
        diagnostic: GroupAccountLaunchDiagnostic? = nil,
        trace: GroupAccountLaunchDiagnostic.RefreshTrace? = nil
    ) async {
        guard !isRefreshing, !isWorking else { return }
        var started = generation
        defer {
            if generation == started { isRefreshing = false }
            diagnostic?.finish()
            trace?.record("Refresh ended · memory \(GroupAccountLaunchDiagnostic.groupSummary(groups)) · scoring identity \(scoringAccount == nil ? "unresolved" : "resolved")")
        }
        var resolvingAccount = true
        var stage = "initial account lookup"
        isRefreshing = true
        do {
            let verified = try await accountID()
            guard generation == started else { return }
            resolvingAccount = false
            if account != verified {
                if account != nil {
                    invalidateAccount()
                    started = generation
                    isRefreshing = true
                }
                account = verified
                snapshot = GroupCacheSnapshot()
                isStale = false
                do {
                    if let cache {
                        snapshot = try cache.load(account: verified)
                        diagnostic?.reportCache(.read(groupsPresent: !snapshot.groups.isEmpty))
                        trace?.record("Resolved account · disk cache read · \(GroupAccountLaunchDiagnostic.groupSummary(groups))")
                    } else {
                        diagnostic?.reportCache(.unavailable)
                        trace?.record("Resolved account · disk cache unavailable")
                    }
                    snapshot.pendingLinks = Self.uniqueInvitationLinks(snapshot.pendingLinks)
                    cacheIssue = cache == nil ? "Groups could not open its local cache." : nil
                } catch {
                    diagnostic?.reportCache(.failed)
                    trace?.record("Resolved account · disk cache read failed")
                    cacheIssue = "Groups could not read its local cache."
                }
            } else {
                diagnostic?.reportCache(.reusedInMemory)
                trace?.record("Resolved account · reused memory · \(GroupAccountLaunchDiagnostic.groupSummary(groups))")
            }
            scoringAccount = verified
            trace?.identifyTarget(account: verified, groups: groups)
            refreshIssue = nil
            guard discoveryPathAvailable == true else {
                isStale = !groups.isEmpty
                trace?.record("Discovery skipped · network path unavailable or unobserved · memory and disk cache kept")
                return
            }
            let path = discoveryPathGeneration
            stage = "invitation resolution"
            let resolved: [String: UUID]
            if let resolveInvitation {
                resolved = try await resolveInvitations(account: verified, generation: started, resolve: resolveInvitation)
            } else {
                resolved = [:]
            }
            guard generation == started else { return }
            if pendingOnly && resolved.isEmpty {
                trace?.record("Discovery skipped · no invitation resolved")
                return
            }
            let membership = groupCacheGeneration
            func requireCurrentDiscovery() throws {
                try Task.checkCancellation()
                guard generation == started, discoveryPathIsCurrent(path), groupCacheGeneration == membership else {
                    throw DiscoveryInterrupted.contextChanged
                }
            }
            try requireCurrentDiscovery()
            stage = "group discovery"
            trace?.record("Before discovery · memory \(GroupAccountLaunchDiagnostic.groupSummary(self.groups))")
            let discovered = try await discover()
            trace?.record("Discovery returned · \(GroupAccountLaunchDiagnostic.groupSummary(discovered.groups)) · \(discovered.skippedRoots) skipped root(s) · memory still \(GroupAccountLaunchDiagnostic.groupSummary(self.groups))")
            try requireCurrentDiscovery()
            stage = "verification of omitted groups"
            let result = try await discovered.reconcile(cached: groups, confirmRemoval: { group in
                try requireCurrentDiscovery()
                do {
                    return try await confirmRemoval(group, verified)
                } catch where !Self.isAccountLoss(error) && !(error is CancellationError) {
                    trace?.record("Omitted group verification inconclusive · \(GroupAccountLaunchDiagnostic.errorCode(error))")
                    return false
                }
            }, trace: trace)
            try requireCurrentDiscovery()
            resolvingAccount = true
            stage = "account recheck after discovery"
            guard try await accountID() == verified else { throw GroupRepositoryError.accountChanged }
            guard generation == started else { return }
            resolvingAccount = false
            try requireCurrentDiscovery()
            let groups = result.groups
            let visible = Set(groups.map(\.id))
            let previousScopes = Set(snapshot.groups.map(\.scope))
            let sameScope = Set(groups.filter { previousScopes.contains($0.scope) }.map(\.id))
            trace?.record("Applying \(result.incomplete ? "partial" : "verified") discovery · \(previousScopes.count - sameScope.count) cached scope(s) removed after verification")
            if snapshot.groups != groups { groupCacheGeneration = UUID() }
            snapshot.groups = groups
            snapshot.groupDetails = snapshot.groupDetails?.filter { sameScope.contains($0.key) }
            snapshot.groupRosters = snapshot.groupRosters?.filter { sameScope.contains($0.key) }
            rosterRequests = rosterRequests.filter { sameScope.contains($0.key) }
            rosterWrites = rosterWrites.filter { sameScope.contains($0.key) }
            for url in snapshot.pendingLinks {
                let key = Self.invitationKey(url)
                if let id = resolved[key], visible.contains(id) {
                    removePendingLink(key)
                    invitationStates[key] = .joined
                }
            }
            isStale = result.incomplete
            if result.incomplete { refreshIssue = "Some groups couldn’t be verified. Showing saved groups where available." }
            let persisted = saveCache()
            trace?.identifyTarget(account: verified, groups: groups)
            trace?.record("Discovery applied · memory \(GroupAccountLaunchDiagnostic.groupSummary(groups)) · disk cache \(persisted ? "saved" : "save failed or unavailable")")
            if !result.incomplete { diagnostic?.recordOnlineBaseline(account: verified) }
        } catch {
            trace?.record("\(stage) failed · \(GroupAccountLaunchDiagnostic.errorCode(error)) · this refresh did not apply a discovery result")
            guard generation == started else { return }
            if resolvingAccount { scoringAccount = nil }
            if Self.isAccountLoss(error) {
                invalidateAccount()
            } else {
                isStale = !groups.isEmpty
            }
            refreshIssue = Self.message(for: error)
        }
    }

    private func discoveryPathIsCurrent(_ generation: UUID) -> Bool {
        discoveryPathAvailable == true && discoveryPathGeneration == generation
    }

    func create(_ name: String, displayName: String, id: UUID) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let success = await perform { account in
            let group = try await self.repository.create(name: name, displayName: displayName, id: id, account: account)
            return { self.upsert(group) }
        }
        if success { await refresh() }
        return success
    }

    func details(for group: GroupSummary) async throws -> GroupDetails {
        try await details(
            for: group,
            verifyAccount: { try await self.repository.verifyAccount($0) },
            fetch: { account in
                let shareDetails = try await self.repository.details(for: group)
                return await self.repository.loadMemberDisplayNames(in: shareDetails, account: account)
            }
        )
    }

    func details(
        for group: GroupSummary,
        verifyAccount: (String) async throws -> Void,
        fetch: (String) async throws -> GroupDetails
    ) async throws -> GroupDetails {
        guard let account else { throw GroupRepositoryError.unavailable }
        let started = generation
        let path = discoveryPathGeneration
        var checkingDetails = false
        do {
            try await verifyAccount(account)
            checkingDetails = true
            let details = try await fetch(account)
            checkingDetails = false
            try await verifyAccount(account)
            guard generation == started else { throw GroupRepositoryError.accountChanged }
            guard containsGroup(group) else { throw GroupRepositoryError.groupScopeUnavailable }
            var saved = snapshot.groupDetails ?? [:]
            let previous = saved[group.id]
            let refreshed = details.cachedDetails
            // Refresh membership even if optional names fail, retaining known names only
            // for participants who are still in the freshly fetched share.
            let members = refreshed.members.map { member in
                guard details.memberNamesUnavailable,
                      let known = previous?.members.first(where: { $0.id == member.id }) else { return member }
                return CachedGroupDetails.Member(id: member.id, name: known.name, role: member.role ?? known.role)
            }
            saved[group.id] = CachedGroupDetails(members: members, savedAt: refreshed.savedAt)
            snapshot.groupDetails = saved
            saveCache()
            return details
        } catch {
            guard generation == started else { throw GroupRepositoryError.accountChanged }
            if Self.isAccountLoss(error) {
                invalidateAccount()
            } else if checkingDetails, GroupRepository.isConfirmedGroupAbsence(error), discoveryPathIsCurrent(path) {
                try await verifyAccount(account)
                if generation == started, discoveryPathIsCurrent(path), containsGroup(group) {
                    removeCachedGroup(group.id, reason: "Group details error \(GroupAccountLaunchDiagnostic.errorCode(error))")
                }
            }
            throw error
        }
    }

    func cachedDetails(for group: GroupSummary) -> CachedGroupDetails? {
        guard account != nil, containsGroup(group) else { return nil }
        return snapshot.groupDetails?[group.id]
    }

    func cachedRoster(for group: GroupSummary) -> CachedGroupRoster? {
        guard account != nil, containsGroup(group),
              let saved = snapshot.groupRosters?[group.id], saved.zoneOwner == group.zoneOwner else { return nil }
        return saved
    }

    func loadRoster(for group: GroupSummary) async throws -> GroupRosterContents {
        try await loadRoster(for: group) { account in
            try await self.withCloudRoster(for: group, account: account) { try await $0.contents() }
        }
    }

    func loadRoster(
        for group: GroupSummary, fetch: (String) async throws -> GroupRosterContents
    ) async throws -> GroupRosterContents {
        try Task.checkCancellation()
        guard containsGroup(group) else { throw GroupRosterError.accessLost }
        let request = UUID()
        rosterRequests[group.id] = request
        defer {
            if rosterRequests[group.id] == request { rosterRequests[group.id] = nil }
        }
        return try await withRosterSession(for: group, operation: fetch, isCurrent: {
            self.rosterRequests[group.id] == request && !Task.isCancelled
        }) { result in
            self.saveRoster(result.players.map { CachedGroupRoster.Player($0) }, for: group)
        }
    }

    func changeRoster(_ change: GroupRosterChange, in group: GroupSummary, session: UUID) async throws {
        try await changeRoster(in: group, session: session) { account in
            try await self.withCloudRoster(for: group, account: account) { roster in
                switch change {
                case .add(let draft): try await roster.add(draft)
                case .rename(let player, let name): try await roster.rename(player, to: name)
                case .setRetired(let player, let retired): try await roster.setRetired(retired, player: player)
                }
            }
        }
    }

    func changeRoster(
        in group: GroupSummary, session: UUID, save: (String) async throws -> GroupPlayerIdentity
    ) async throws {
        guard generation == session else { throw GroupRepositoryError.accountChanged }
        try Task.checkCancellation()
        guard containsGroup(group) else { throw GroupRosterError.accessLost }
        guard rosterWrites[group.id] == nil else { throw GroupRosterError.writeInProgress }
        let request = UUID()
        rosterWrites[group.id] = request
        defer {
            if rosterWrites[group.id] == request { rosterWrites[group.id] = nil }
        }
        _ = try await withRosterSession(for: group, operation: save, isCurrent: {
            self.rosterWrites[group.id] == request
        }) { player in
            guard player.groupID == group.id else { throw GroupRosterError.wrongGroup }
            self.rosterRequests[group.id] = nil
            guard var cached = self.cachedRoster(for: group)?.players else { return }
            cached.removeAll { $0.id == player.id }
            cached.append(CachedGroupRoster.Player(player))
            self.saveRoster(cached, for: group)
        }
    }

    private func withCloudRoster<Result>(
        for group: GroupSummary, account: String, operation: (GroupRoster) async throws -> Result
    ) async throws -> Result {
        let roster = repository.roster(for: group, account: account)
        do {
            return try await operation(roster)
        } catch where Self.isAccessLoss(error) {
            // A child record or a write can fail even when the share is still accessible.
            _ = try await roster.authorize()
            throw error
        }
    }

    private func withRosterSession<Result>(
        for group: GroupSummary, operation: (String) async throws -> Result,
        isCurrent: () -> Bool, apply: (Result) throws -> Void
    ) async throws -> Result {
        guard let account else { throw GroupRepositoryError.unavailable }
        let started = generation
        let path = discoveryPathGeneration
        do {
            let result = try await operation(account)
            guard generation == started else { throw GroupRepositoryError.accountChanged }
            guard isCurrent() else { throw CancellationError() }
            guard containsGroup(group) else {
                GroupAccountLaunchDiagnostic.activeTrace?.record("Shared group session ended · group scope missing from memory")
                throw GroupRepositoryError.groupScopeUnavailable
            }
            try apply(result)
            return result
        } catch {
            guard generation == started else { throw GroupRepositoryError.accountChanged }
            // A superseded request cannot modify or remove a newly loaded roster.
            guard isCurrent() else { throw CancellationError() }
            if Self.isAccountLoss(error) {
                invalidateAccount()
            } else if (error as? GroupRosterError) == .accessLost {
                guard discoveryPathIsCurrent(path) else { throw GroupRepositoryError.groupScopeUnavailable }
                if containsGroup(group) { removeCachedGroup(group.id, reason: "Shared group session reported access lost") }
            }
            throw error
        }
    }

    func containsGroup(_ group: GroupSummary) -> Bool {
        groups.contains { $0.scope == group.scope }
    }

    func gameJournal(for route: GroupGameRoute, account expectedAccount: String?) throws -> GroupGameJournal.Game {
        guard let scoringAccount, scoringAccount == expectedAccount, containsGroup(route.group) else {
            throw GroupRepositoryError.accountTemporarilyUnavailable
        }
        let store = try openScoringJournal()
        return GroupGameJournal.Game(store: store, scope: .init(namespace: journalNamespace(scoringAccount), route: route))
    }

    func resumableGames() throws -> [GroupGameJournal.ResumeItem] {
        let trace = GroupAccountLaunchDiagnostic.activeTrace
        guard let scoringAccount else {
            trace?.record("Resume journal scan skipped · scoring identity unresolved")
            return []
        }
        let entries: [GroupGameJournal.Entry]
        do {
            entries = try openScoringJournal().entries(in: journalNamespace(scoringAccount))
        } catch {
            trace?.record("Resume journal scan failed · local store open, fetch, or decode error")
            throw error
        }
        if let trace {
            let matching = entries.filter { trace.isTarget($0.scope.groupID) }.count
            let targetRows = trace.knowsTarget ? "\(matching) for the test group" : "test group not identified yet"
            trace.record("Resume journal scan · \(entries.count) row(s) for verified account · \(targetRows) · memory \(GroupAccountLaunchDiagnostic.groupSummary(groups))")
        }
        return entries.filter { entry in
            if !entry.canResume {
                trace?.recordJournal(entry, outcome: entry.isEligible ? "excluded · confirmed game is not in progress and queue is empty" : "excluded · saved eligibility is false")
            }
            return entry.canResume
        }.sorted {
            ($0.operations.last?.createdAt ?? $0.confirmed.header.updatedAt ?? .distantPast) >
                ($1.operations.last?.createdAt ?? $1.confirmed.header.updatedAt ?? .distantPast)
        }.compactMap { entry in
            guard let group = groups.first(where: entry.scope.matches) else {
                if let trace {
                    let sameGroup = groups.filter { $0.id == entry.scope.groupID }
                    let reason = if sameGroup.isEmpty {
                        "group absent from memory"
                    } else if !sameGroup.contains(where: { $0.zoneOwner == entry.scope.zoneOwner }) {
                        "cached zone owner differs"
                    } else {
                        "cached owner/member role differs"
                    }
                    trace.recordJournal(entry, outcome: "excluded · \(reason)")
                }
                return nil
            }
            guard let game = try? entry.scorecard() else {
                trace?.recordJournal(entry, outcome: "excluded · local scorecard projection failed")
                return nil
            }
            trace?.recordJournal(entry, outcome: "included in resume results")
            return GroupGameJournal.ResumeItem(route: GroupGameRoute(group: group, gameID: entry.scope.gameID),
                                               header: game.header, syncStatus: entry.syncStatus)
        }
    }

    func diagnosticDiskCacheSummary() -> String {
        guard let scoringAccount else { return "Scoring identity unresolved" }
        guard let cache else { return "Cache unavailable" }
        guard let persisted = try? cache.load(account: scoringAccount) else { return "Cache read failed" }
        return GroupAccountLaunchDiagnostic.groupSummary(persisted.groups)
    }

    private func openScoringJournal() throws -> GroupGameJournal {
        if let scoringJournal { return scoringJournal }
        let opened = try GroupGameJournal(url: journalURL)
        scoringJournal = opened
        return opened
    }

    private func journalNamespace(_ account: String) -> GroupGameJournal.Namespace {
        // Groups currently ships in Debug with the Development CloudKit entitlement.
        .init(account: account, container: containerIdentifier, environment: "Development")
    }

    func withSharedGroup<Result>(
        _ group: GroupSummary, session: UUID? = nil,
        operation: (GroupRepository, String) async throws -> Result
    ) async throws -> Result {
        if let session, session != generation { throw GroupRepositoryError.accountChanged }
        try Task.checkCancellation()
        guard containsGroup(group) else {
            GroupAccountLaunchDiagnostic.activeTrace?.record("Shared group session rejected · group scope missing from memory")
            throw GroupRepositoryError.groupScopeUnavailable
        }
        let path = discoveryPathGeneration
        return try await withRosterSession(for: group, operation: { account in
            do {
                let result = try await operation(self.repository, account)
                try await self.repository.verifyAccount(account)
                return result
            } catch GroupGameError.gameNotFound where !self.discoveryPathIsCurrent(path) {
                // An interrupted lookup cannot make the local scorecard ineligible.
                throw GroupRepositoryError.groupScopeUnavailable
            } catch where Self.isAccessLoss(error) {
                // A missing game or child record alone does not establish loss of membership.
                _ = try await self.repository.roster(for: group, account: account).authorize()
                throw error
            }
        }, isCurrent: { !Task.isCancelled }) { _ in }
    }

    private func saveRoster(_ players: [CachedGroupRoster.Player], for group: GroupSummary) {
        var rosters = snapshot.groupRosters ?? [:]
        let sorted = players.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        rosters[group.id] = CachedGroupRoster(zoneOwner: group.zoneOwner, players: sorted)
        snapshot.groupRosters = rosters
        saveCache()
    }

    @discardableResult
    func keepMemberNameDraft(_ draft: String?, in group: GroupSummary, account editorAccount: String) -> Bool {
        guard account == editorAccount, groups.contains(where: { $0.id == group.id }) else { return false }
        var drafts = snapshot.memberNameDrafts ?? [:]
        drafts[group.id] = draft
        snapshot.memberNameDrafts = drafts.isEmpty ? nil : drafts
        return saveCache()
    }

    func saveMyDisplayName(_ name: String, in group: GroupSummary, account editorAccount: String) async -> Bool {
        guard account == editorAccount, groups.contains(where: { $0.id == group.id }) else {
            actionIssue = GroupRepositoryError.accountChanged.localizedDescription
            return false
        }
        return await perform(failureMessage: "Couldn’t save your display name.") { account in
            guard account == editorAccount else { throw GroupRepositoryError.accountChanged }
            try await self.repository.saveMyDisplayName(name, in: group, account: account)
            return { self.keepMemberNameDraft(nil, in: group, account: account) }
        }
    }

    func changeMembership(_ change: GroupMembershipChange, group: GroupSummary) async -> Bool {
        let failureMessage = switch change {
        case .approve: "Couldn’t approve the request."
        default: "Couldn’t update membership."
        }
        return await perform(failureMessage: failureMessage) { account in
            try await self.repository.changeMembership(change, group: group, account: account)
            return {}
        }
    }

    func remove(_ group: GroupSummary) async {
        let success = await perform { account in
            if group.isOwner {
                try await self.repository.delete(group, account: account)
            } else {
                try await self.repository.leave(group, account: account)
            }
            return {
                self.removeCachedGroup(group.id, reason: "Explicit leave or delete succeeded")
            }
        }
        if success { await refresh() }
    }

    func requestAccess(to url: URL) async -> Bool {
        if let account, isPending(url) {
            // A repeated paste does not send the owner another request.
            return await perform { current in
                guard account == current else { throw GroupRepositoryError.accountChanged }
                return {}
            }
        }
        return await perform { account in
            try await self.repository.requestAccess(to: url, account: account)
            return {
                self.rememberLink(url)
                self.saveCache()
            }
        }
    }

    func invitationState(for url: URL) -> PendingInvitationState {
        invitationStates[Self.invitationKey(url)] ?? .waiting
    }

    func willVerifyInvitation(_ url: URL) {
        invitationStates[Self.invitationKey(url)] = .waiting
    }

    func isPending(_ url: URL) -> Bool {
        let key = Self.invitationKey(url)
        return snapshot.pendingLinks.contains { Self.invitationKey($0) == key }
    }

    var hasPollableInvitations: Bool {
        snapshot.pendingLinks.contains {
            let state = invitationState(for: $0)
            return state != .needsVerification && state != .unavailable
        }
    }

    private func resolveInvitations(
        account: String, generation started: UUID, resolve: (URL, String) async throws -> UUID
    ) async throws -> [String: UUID] {
        var resolved: [String: UUID] = [:]
        var nativeKey: String?
        if let metadata = nativeInvitation {
            let url = metadata.share.url.flatMap { Self.invitationURL(from: $0.absoluteString) }
            if let url {
                nativeKey = Self.invitationKey(url)
                rememberLink(url)
                saveCache()
            }
            do {
                let id = try await repository.accept(metadata, account: account)
                guard generation == started else { return [:] }
                // The empty key only triggers discovery when native metadata had no URL.
                resolved[nativeKey ?? ""] = id
                if let nativeKey { invitationStates[nativeKey] = .joining }
                if nativeInvitation === metadata { nativeInvitation = nil }
                invitationIssue = nil
            } catch {
                guard generation == started else { return [:] }
                if Self.isAccountLoss(error) { throw error }
                if let nativeKey {
                    noteInvitationFailure(error, for: nativeKey)
                    if nativeInvitation === metadata { nativeInvitation = nil }
                } else {
                    invitationIssue = "Couldn’t finish joining. Refresh Groups or reopen the original invitation."
                }
            }
        }

        for url in snapshot.pendingLinks {
            let key = Self.invitationKey(url)
            guard key != nativeKey, (retryInvitationAfter[key] ?? .distantPast) <= .now else { continue }
            guard generation == started, !Task.isCancelled else { return resolved }
            // If verification or a new link is needed, wait for the person to act.
            let state = invitationState(for: url)
            guard state != .needsVerification && state != .unavailable else { continue }
            do {
                let id = try await resolve(url, account)
                guard generation == started else { return [:] }
                resolved[key] = id
                invitationStates[key] = .joining
            } catch {
                guard generation == started else { return [:] }
                if Self.isAccountLoss(error) { throw error }
                noteInvitationFailure(error, for: key)
            }
        }
        return resolved
    }

    private func noteInvitationFailure(_ error: Error, for key: String) {
        let cloud = error as? CKError
        if let delay = cloud?.retryAfterSeconds, delay > 0 {
            retryInvitationAfter[key] = Date.now.addingTimeInterval(delay)
        }
        invitationStates[key] = switch (error as? GroupRepositoryError, cloud?.code) {
        case (_, .participantMayNeedVerification): .needsVerification
        case (.invalidLink, _): .unavailable
        case (.approvalRequired, _), (_, .permissionFailure), (_, .unknownItem): .waiting
        default: .retrying
        }
    }

    func forgetLink(_ url: URL) {
        guard !isRefreshing, !isWorking else { return }
        removePendingLink(Self.invitationKey(url))
        saveCache()
    }

    private func rememberLink(_ url: URL) {
        if !isPending(url) {
            invitationStates[Self.invitationKey(url)] = .waiting
            snapshot.pendingLinks.append(url)
        }
    }

    private func removePendingLink(_ key: String) {
        snapshot.pendingLinks.removeAll { Self.invitationKey($0) == key }
        invitationStates[key] = nil
        retryInvitationAfter[key] = nil
    }

    private func perform(
        failureMessage: String? = nil,
        _ operation: (String) async throws -> (() -> Void)
    ) async -> Bool {
        guard !isWorking, !isRefreshing else { return false }
        guard let account else {
            actionIssue = "Connect to iCloud and refresh Groups first."
            return false
        }
        let started = generation
        isWorking = true
        defer {
            if generation == started {
                isWorking = false
                if nativeRefreshQueued || discoveryRefreshQueued { Task { await refresh() } }
            }
        }
        do {
            try await repository.verifyAccount(account)
            let commit = try await operation(account)
            guard generation == started else { return false }
            // Server-confirmed operations may be followed immediately by loss of connectivity.
            // Their effects only apply to the snapshot for the account that started the operation.
            commit()
            return true
        } catch {
            guard generation == started else { return false }
            if Self.isAccountLoss(error) { invalidateAccount() }
            let reason = Self.message(for: error)
            actionIssue = failureMessage.map { "\($0) \(reason)" } ?? reason
            return false
        }
    }

    private func upsert(_ group: GroupSummary) {
        groupCacheGeneration = UUID()
        snapshot.groups.removeAll { $0.id == group.id }
        snapshot.groups.append(group)
        snapshot.groups.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        saveCache()
    }

    private func removeCachedGroup(_ id: UUID, reason: String) {
        groupCacheGeneration = UUID()
        let trace = GroupAccountLaunchDiagnostic.activeTrace
        trace?.record("Group cache removal started · \(reason) · memory \(GroupAccountLaunchDiagnostic.groupSummary(groups))")
        snapshot.groups.removeAll { $0.id == id }
        snapshot.groupDetails?.removeValue(forKey: id)
        snapshot.groupRosters?.removeValue(forKey: id)
        rosterRequests[id] = nil
        rosterWrites[id] = nil
        let persisted = saveCache()
        trace?.record("Group cache removal ended · memory \(GroupAccountLaunchDiagnostic.groupSummary(groups)) · disk cache \(persisted ? "replaced" : "save failed or unavailable")")
    }

    func invalidateAccount() {
        let trace = GroupAccountLaunchDiagnostic.activeTrace
        trace?.record("Account invalidated · memory cleared from \(GroupAccountLaunchDiagnostic.groupSummary(groups)) to 0 groups · this action did not write the disk cache")
        trace?.forgetTargetContext()
        generation = UUID()
        account = nil
        scoringAccount = nil
        snapshot = GroupCacheSnapshot()
        rosterRequests.removeAll()
        rosterWrites.removeAll()
        isStale = false
        isRefreshing = false
        isWorking = false
        refreshIssue = nil
        cacheIssue = nil
        actionIssue = nil
        nativeInvitation = nil
        nativeRefreshQueued = false
        invitationIssue = nil
        invitationStates = [:]
        retryInvitationAfter = [:]
    }

    @discardableResult
    private func saveCache() -> Bool {
        guard let account else { return false }
        guard let cache else {
            cacheIssue = "Groups could not open its local cache."
            return false
        }
        do {
            try cache.save(snapshot, account: account)
            cacheIssue = nil
            return true
        } catch {
            cacheIssue = "Groups could not save its local cache."
            return false
        }
    }

    static func invitationURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.port == nil,
              ["www.icloud.com", "icloud.com", "www.icloud.com.cn", "icloud.com.cn"].contains(components.host ?? ""),
              components.path.hasPrefix("/share/"), components.path.count > "/share/".count else { return nil }
        return components.url
    }

    private static func invitationKey(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + url.path()
    }

    private static func uniqueInvitationLinks(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter {
            invitationURL(from: $0.absoluteString) != nil && seen.insert(invitationKey($0)).inserted
        }
    }

    static func isAccessLoss(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return [.zoneNotFound, .unknownItem, .permissionFailure, .participantMayNeedVerification].contains(error.code)
    }

    private static func isAccountLoss(_ error: Error) -> Bool {
        // Only an explicit account status or verified identity change confirms account loss.
        // A CloudKit request can fail authentication while the account is temporarily unavailable.
        guard let error = error as? GroupRepositoryError else { return false }
        return [.accountChanged, .unavailable].contains(error)
    }

    static func message(for error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .serverRecordChanged: return "This group changed on another device. Refresh and try again."
        case .networkUnavailable, .networkFailure, .serviceUnavailable:
            return "Couldn’t reach iCloud. Check your connection and try again."
        case .notAuthenticated:
            return "Couldn’t verify iCloud right now. Connect and refresh to try again."
        default: return "\(error.localizedDescription) (CloudKit \(error.code.rawValue))"
        }
    }
}
#endif
