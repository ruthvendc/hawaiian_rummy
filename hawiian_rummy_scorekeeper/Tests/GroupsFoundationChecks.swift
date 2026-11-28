import CloudKit
import Foundation

@main
struct GroupsFoundationChecks {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appending(path: "groups.store")
        let model = onlineModel(cacheURL: cacheURL)
        let owned = GroupSummary(id: UUID(), zoneOwner: "owner", name: "Crane Family", isOwner: true)
        let joined = GroupSummary(id: UUID(), zoneOwner: "remote", name: owned.name, isOwner: false)
        let other = GroupSummary(id: UUID(), zoneOwner: "other", name: "Other family", isOwner: true)
        let link = try require(
            GroupsModel.invitationURL(from: "  https://www.icloud.com/share/test  "),
            "Valid invitation link"
        )
        try check(GroupsModel.invitationURL(from: "https://icloud.com.evil.test/share/test") == nil, "Reject lookalike host")
        try check(GroupsModel.invitationURL(from: "https://user@www.icloud.com/share/test") == nil, "Reject URL credentials")
        try check(GroupsModel.invitationURL(from: "https://www.icloud.com/") == nil, "Reject unrelated iCloud links")

        await model.refresh(accountID: { "A" }, discover: { GroupDiscoveryResult(groups: [owned, joined]) })
        try check(model.groups == [owned, joined] && owned.id != joined.id, "Discover both same-named groups on an empty cache")

        let cache = try GroupCache(url: cacheURL)
        try cache.save(GroupCacheSnapshot(groups: [owned, joined], pendingLinks: [link]), account: "A")
        let reopened = onlineModel(cacheURL: cacheURL)
        try check(reopened.groups.isEmpty && reopened.scoringAccount == nil, "Hide cache and journal before resolving the account")
        await reopened.refresh(accountID: { "A" }, discover: { throw CKError(.networkUnavailable) })
        try check(reopened.isStale && reopened.groups == [owned, joined], "Retain current account cache after a network failure")
        try check(reopened.snapshot.pendingLinks == [link], "Retain account’s pending invitation across relaunch")
        try check(reopened.scoringAccount == "A", "A resolved account can unlock local scoring when group discovery is offline")

        reopened.prepareForAccountRefresh()
        await reopened.refresh(accountID: { throw GroupRepositoryError.accountTemporarilyUnavailable }, discover: { GroupDiscoveryResult(groups: []) })
        try check(reopened.groups == [owned, joined] && reopened.account == "A" && reopened.scoringAccount == nil && reopened.isStale &&
                  reopened.snapshot.pendingLinks == [link],
                  "Unresolved identity locks local scoring while keeping the group and invitation cache")
        await reopened.refresh(accountID: { throw CKError(.notAuthenticated) }, discover: { GroupDiscoveryResult(groups: []) })
        try check(reopened.groups == [owned, joined] && reopened.account == "A" && reopened.isStale,
                  "A request authentication failure does not confirm sign-out or discard cached groups")
        let offlineCache = try cache.load(account: "A")
        try check(offlineCache.groups == [owned, joined] && offlineCache.pendingLinks == [link],
                  "Failed account refreshes do not replace the persisted cache with an empty list")

        await reopened.refresh(accountID: { "B" }, discover: { GroupDiscoveryResult(groups: [other]) })
        try check(reopened.groups == [other] && reopened.scoringAccount == "B" && reopened.snapshot.pendingLinks.isEmpty,
                  "Switch accounts without leaking cached groups or links or unlocking the old journal")
        let original = try cache.load(account: "A")
        try check(original.groups == [owned, joined] && original.pendingLinks == [link], "Retain first account’s private cache")

        await reopened.refresh(accountID: { "A" }, discover: { GroupDiscoveryResult(groups: [owned]) },
                               confirmRemoval: { group, _ in group.scope == joined.scope })
        try check(reopened.groups == [owned] && !reopened.isStale, "Remove a joined group omitted by successful server discovery")
        await reopened.refresh(accountID: { throw GroupRepositoryError.accountTemporarilyUnavailable }, discover: { GroupDiscoveryResult(groups: []) })
        try check(reopened.groups == [owned] && reopened.isStale, "Do not clear cache on temporary account failure")
        await reopened.refresh(accountID: { throw GroupRepositoryError.unavailable }, discover: { GroupDiscoveryResult(groups: []) })
        try check(reopened.groups.isEmpty && reopened.account == nil, "Hide cache after sign-out")

        await reopened.refresh(accountID: { "A" }, discover: {
            reopened.invalidateAccount()
            await reopened.refresh(accountID: { "B" }, discover: { GroupDiscoveryResult(groups: [other]) })
            return GroupDiscoveryResult(groups: [owned, joined])
        })
        try check(reopened.account == "B" && reopened.groups == [other], "Ignore a late response from the previous account")
        try check(!GroupsModel.isAccessLoss(CKError(.networkFailure)), "Network failures do not confirm access loss")
        try check(GroupsModel.isAccessLoss(CKError(.permissionFailure)), "Permission denial confirms access loss")

        let sameInvitation = try require(URL(string: "https://icloud.com/share/test#Family"), "Equivalent share link")
        try cache.save(GroupCacheSnapshot(groups: [other], pendingLinks: [link, sameInvitation]), account: "recipient")
        let waiting = onlineModel(cacheURL: cacheURL)
        await waiting.refresh(accountID: { "recipient" }, discover: { GroupDiscoveryResult(groups: [other]) }, resolveInvitation: { _, account in
            try check(account == "recipient", "Only check an invitation under its saved account")
            throw GroupRepositoryError.approvalRequired
        })
        try check(waiting.snapshot.pendingLinks == [link] && waiting.isPending(sameInvitation),
                  "Recognize the same share with a different host alias or fragment")
        try check(waiting.invitationState(for: link) == .waiting && waiting.groups == [other],
                  "Waiting for approval grants no access")
        await waiting.refresh(accountID: { "recipient" }, discover: { GroupDiscoveryResult(groups: [other]) }, resolveInvitation: { _, _ in
            throw CKError(.networkFailure)
        }, pendingOnly: true)
        try check(waiting.invitationState(for: link) == .retrying && waiting.isPending(link),
                  "A temporary failure retains the pending request")

        let relaunched = onlineModel(cacheURL: cacheURL)
        await relaunched.refresh(accountID: { "recipient" }, discover: { GroupDiscoveryResult(groups: [other]) }, resolveInvitation: { _, _ in joined.id })
        try check(relaunched.invitationState(for: link) == .joining && relaunched.isPending(link),
                  "After relaunch, retain the accepted link until CloudKit discovery catches up")
        await relaunched.refresh(accountID: { "recipient" }, discover: { GroupDiscoveryResult(groups: [other, joined]) },
                                 resolveInvitation: { _, _ in joined.id }, pendingOnly: true)
        try check(relaunched.snapshot.pendingLinks.isEmpty && relaunched.groups == [other, joined]
                    && relaunched.invitationState(for: link) == .joined,
                  "Automatically rediscover the approved group and clear only its pending link")

        try cache.save(GroupCacheSnapshot(groups: [other], pendingLinks: [link]), account: "verification")
        let verification = onlineModel(cacheURL: cacheURL)
        await verification.refresh(accountID: { "verification" }, discover: { GroupDiscoveryResult(groups: [other]) }, resolveInvitation: { _, _ in
            throw CKError(.participantMayNeedVerification)
        })
        try check(verification.invitationState(for: link) == .needsVerification && !verification.hasPollableInvitations,
                  "Pause automatic retries when Apple requires verification")
        verification.willVerifyInvitation(link)
        try check(verification.hasPollableInvitations, "Resume checking after verification is opened")

        await verification.refresh(accountID: { "verification" }, discover: { GroupDiscoveryResult(groups: [other]) }, resolveInvitation: { _, _ in
            throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
        })
        var checksDuringBackoff = 0
        await verification.refresh(accountID: { "verification" }, discover: { GroupDiscoveryResult(groups: [other]) }, resolveInvitation: { _, _ in
            checksDuringBackoff += 1
            return joined.id
        })
        try check(checksDuringBackoff == 0 && verification.isPending(link), "Respect CloudKit retry-after without dropping the link")

        let legacySnapshot = try JSONDecoder().decode(
            GroupCacheSnapshot.self, from: Data(#"{"groups":[],"pendingLinks":[]}"#.utf8)
        )
        try check(legacySnapshot.memberNameDrafts == nil, "Read existing group caches without a display name draft")
        try check(GroupMemberDisplayName.visibleName("  David  ") == "David" &&
                  GroupMemberDisplayName.visibleName(" ") == nil, "Trim an optional display name")
        let longName = String(repeating: "👨🏽‍🦱", count: GroupMemberDisplayName.maximumLength)
        try check(GroupMemberDisplayName.visibleName(longName) == longName &&
                  GroupMemberDisplayName.visibleName(longName + "x") == nil &&
                  GroupMemberDisplayName.visibleName("David\nCrane") == nil, "Validate display names by character and reject multiline input")
        try check(GroupMemberDisplayName.preferredName(custom: "Wendy", cloudKit: "Wendy Crane") == "Wendy",
                  "Use the synchronized name ahead of the CloudKit name")
        try check(GroupMemberDisplayName.preferredName(custom: "", cloudKit: "Wendy Crane") == "Wendy Crane",
                  "Restore the CloudKit participant name after a custom name is cleared")
        try check(GroupMemberDisplayName.cloudKitName("wendy@example.invalid") == nil &&
                  GroupMemberDisplayName.cloudKitName("+1 (123) 456-7890") == nil,
                  "Skip contact handles as display names")
        try check(GroupMemberDisplayName.matchesRecord(directMatch: false, account: "B", creator: "B", lastEditor: "B"),
                  "Recover an existing name by its CloudKit creator when the participant key differs")
        try check(!GroupMemberDisplayName.matchesRecord(directMatch: true, account: "A", creator: "B", lastEditor: "B") &&
                  !GroupMemberDisplayName.matchesRecord(directMatch: false, account: "B", creator: "A", lastEditor: "B"),
                  "Do not assign another account’s record to this member")
        try check(GroupMemberDisplayName.matchesRecord(directMatch: true, account: nil, creator: nil, lastEditor: nil) &&
                  !GroupMemberDisplayName.matchesRecord(directMatch: false, account: nil, creator: nil, lastEditor: nil),
                  "Require the exact participant key when CloudKit omits account identity")
        let ownerInPrivateDB = GroupRepository.memberNameAccountID(CKCurrentUserDefaultName, viewer: "A")
        let ownerInSharedDB = GroupRepository.memberNameAccountID("A", viewer: "B")
        try check(ownerInPrivateDB == "A" && ownerInSharedDB == "A" &&
                  GroupMemberDisplayName.matchesRecord(directMatch: false, account: "A",
                                                       creator: ownerInPrivateDB, lastEditor: ownerInSharedDB),
                  "Resolve the owner’s private alias to the same account seen by members")
        try check(GroupRepository.memberNameAccountID(nil, viewer: "B") == nil &&
                  GroupRepository.memberNameAccountID("A", viewer: "B") == "A",
                  "Keep missing or other participants’ identities separate from the viewer")

        let names = onlineModel(cacheURL: cacheURL)
        await names.refresh(accountID: { "A" }, discover: { GroupDiscoveryResult(groups: [owned, joined]) })
        let savedDraft = names.keepMemberNameDraft("David", in: owned, account: "A")
        let savedClear = names.keepMemberNameDraft("", in: joined, account: "A")
        try check(savedDraft && savedClear, "Keep separate drafts, including a pending clear, for groups in the same account")
        let savedUnderWrongAccount = await names.saveMyDisplayName("Wrong account", in: owned, account: "B")
        try check(!savedUnderWrongAccount, "Reject a save from an editor opened under a different account")
        let namesRelaunched = onlineModel(cacheURL: cacheURL)
        await namesRelaunched.refresh(accountID: { "A" }, discover: { throw CKError(.networkFailure) })
        try check(namesRelaunched.snapshot.memberNameDrafts?[owned.id] == "David" &&
                  namesRelaunched.snapshot.memberNameDrafts?[joined.id] == "", "Keep offline drafts across launch without changing groups")
        await namesRelaunched.refresh(accountID: { "B" }, discover: { GroupDiscoveryResult(groups: [other]) })
        try check(namesRelaunched.snapshot.memberNameDrafts == nil, "Do not show drafts across iCloud accounts")

        let root = CKRecord(recordType: GroupRecordTypes.group, recordID: CKRecord.ID(recordName: "group"))
        let share = CKShare(rootRecord: root)
        var liveDetails = GroupDetails(group: owned, share: share, invitationURL: nil)
        liveDetails.memberDisplayNames[share.owner.participantID] = "David"
        let detailsModel = onlineModel(cacheURL: cacheURL)
        await detailsModel.refresh(accountID: { "details-account" }, discover: { GroupDiscoveryResult(groups: [owned, joined]) })
        _ = detailsModel.keepMemberNameDraft("Unsent draft", in: owned, account: "details-account")
        _ = try await detailsModel.details(for: owned, verifyAccount: { _ in }, fetch: { _ in liveDetails })
        let savedDetails = try require(detailsModel.cachedDetails(for: owned), "Store successfully fetched membership details")
        try check(savedDetails.members.first?.name == "David (You)",
                  "Cache resolved member names and roles after a successful online details read")
        do {
            _ = try await detailsModel.details(for: owned, verifyAccount: { _ in throw CKError(.networkUnavailable) },
                                               fetch: { _ in throw Failure(message: "Should not fetch while offline") })
            throw Failure(message: "Expected offline details failure")
        } catch let error as CKError {
            try check(error.code == .networkUnavailable && detailsModel.cachedDetails(for: owned) == savedDetails &&
                      detailsModel.groups == [owned, joined],
                      "Offline details refresh retains group membership and names for display")
        }
        let detailsRelaunched = onlineModel(cacheURL: cacheURL)
        await detailsRelaunched.refresh(accountID: { "details-account" }, discover: { throw CKError(.networkFailure) })
        try check(detailsRelaunched.cachedDetails(for: owned) == savedDetails &&
                  detailsRelaunched.snapshot.memberNameDrafts?[owned.id] == "Unsent draft",
                  "Membership cache and unsent name draft survive recreating the app model")
        var updatedDetails = liveDetails
        updatedDetails.memberDisplayNames[share.owner.participantID] = "David Updated"
        let recovered = try await detailsRelaunched.details(
            for: owned, verifyAccount: { _ in }, fetch: { _ in updatedDetails }
        )
        try check(recovered.displayName(for: share.owner) == "David Updated" && detailsRelaunched.isStale &&
                  detailsRelaunched.cachedDetails(for: owned)?.members.first?.name == "David Updated (You)",
                  "An individual group recovers fresh data while the overall Groups list is still stale")
        try check(detailsRelaunched.snapshot.memberNameDrafts?[owned.id] == "Unsent draft",
                  "Refreshing an individual group preserves the member’s unsent display name draft")
        _ = try await detailsRelaunched.details(for: owned, verifyAccount: { _ in }, fetch: { _ in liveDetails })
        var incompleteNames = liveDetails
        incompleteNames.memberNamesUnavailable = true
        incompleteNames.memberDisplayNames = [:]
        _ = try await detailsRelaunched.details(for: owned, verifyAccount: { _ in }, fetch: { _ in incompleteNames })
        try check(detailsRelaunched.cachedDetails(for: owned)?.members == savedDetails.members,
                  "An optional display name fetch failure does not overwrite saved names")
        await detailsRelaunched.refresh(accountID: { "details-account" }, discover: { GroupDiscoveryResult(groups: [joined]) },
                                       confirmRemoval: { group, _ in group.scope == owned.scope })
        try check(detailsRelaunched.cachedDetails(for: owned) == nil &&
                  detailsRelaunched.snapshot.groupDetails?[owned.id] == nil && !detailsRelaunched.isStale,
                  "Successful online discovery removes deleted or revoked groups and cached membership")
        await detailsRelaunched.refresh(accountID: { "details-account" }, discover: { GroupDiscoveryResult(groups: [owned, joined]) })
        _ = try await detailsRelaunched.details(for: owned, verifyAccount: { _ in }, fetch: { _ in liveDetails })
        do {
            _ = try await detailsRelaunched.details(for: owned, verifyAccount: { _ in },
                                                   fetch: { _ in throw CKError(.permissionFailure) })
            throw Failure(message: "Expected confirmed access loss")
        } catch let error as CKError {
            try check(error.code == .permissionFailure && !detailsRelaunched.groups.contains(owned) &&
                      detailsRelaunched.cachedDetails(for: owned) == nil,
                      "A server permission denial removes cached details instead of showing stale access")
        }
        await detailsRelaunched.refresh(accountID: { "another-account" }, discover: { GroupDiscoveryResult(groups: [other]) })
        try check(detailsRelaunched.cachedDetails(for: owned) == nil && detailsRelaunched.snapshot.groupDetails == nil,
                  "Cached membership never crosses a verified account switch")
        try check(legacySnapshot.groupDetails == nil, "Existing cache snapshots decode without membership data")
        try check(legacySnapshot.groupRosters == nil, "Existing cache snapshots decode without roster data")
        try await rosterCacheChecks(directory: directory, group: owned, otherGroup: joined)
        try await offlineDiscoveryChecks(directory: directory)
        print("Groups Foundation checks passed.")
    }

    private static func onlineModel(cacheURL: URL) -> GroupsModel {
        let model = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        model.updateDiscoveryPath(available: true)
        return model
    }

    private static func offlineDiscoveryChecks(directory: URL) async throws {
        let cacheURL = directory.appending(path: "offline-discovery.store")
        let journalURL = directory.appending(path: "offline-discovery-journal.store")
        let account = "member-account"
        let container = "offline-discovery-checks"
        let groups = (1...4).map { GroupSummary(id: UUID(), zoneOwner: "owner-\($0)", name: "Group \($0)", isOwner: false) }
        let target = groups[0]
        let route = GroupGameRoute(group: target, gameID: UUID())
        let access = GroupRosterAccess(role: .editor, groupID: target.id, account: account)
        let players = [GroupGameParticipant(playerID: UUID(), displayName: "One"),
                       GroupGameParticipant(playerID: UUID(), displayName: "Two")]
        let confirmed = GroupGameSnapshot(
            header: GroupGameHeader(id: route.gameID, groupID: target.id, participants: players, creatorKey: access.creatorKey,
                                   scorekeeperKey: access.creatorKey, roundCount: 1, completedAt: nil, cancelledAt: nil,
                                   createdAt: nil, updatedAt: nil, version: .init(revision: 1, changeTag: "cloud-revision-1")),
            rounds: [GroupGameRound(id: .init(gameID: route.gameID, number: 1), hands: [])]
        )
        let cache = try GroupCache(url: cacheURL)
        let original = GroupCacheSnapshot(groups: groups)
        try cache.save(original, account: account)
        let scope = GroupGameJournal.Scope(namespace: .init(account: account, container: container, environment: "Development"), route: route)
        let operationID: UUID
        do {
            let store = try GroupGameJournal(url: journalURL)
            let game = GroupGameJournal.Game(store: store, scope: scope)
            let entry = try require(game.recordConfirmed(confirmed, access: access), "Seed the member journal")
            let hand = GroupGameHand(number: 1, scores: [players[0].playerID: 8, players[1].playerID: 11])
            let queued = try game.append(.saveHand(round: 1, hand: hand), editID: entry.editID, submitImmediately: false)
            operationID = try require(queued.operations.first?.request.id, "Save a pending hand before relaunch")
        }

        let model = GroupsModel(containerIdentifier: container, cacheURL: cacheURL, journalURL: journalURL)
        var discoveries = 0
        let emptyDiscovery = {
            discoveries += 1
            return GroupDiscoveryResult(groups: [])
        }
        await model.refresh(accountID: { account }, discover: emptyDiscovery)
        let resumed = try model.resumableGames()
        let game = try model.gameJournal(for: route, account: account)
        let reopened = try require(game.load(), "Reopen the journal on cold launch")
        try check(discoveries == 0 && model.scoringAccount == account && model.groups == groups && model.isStale &&
                  (try cache.load(account: account)) == original && resumed.map(\.route) == [route] &&
                  reopened.operations.first?.request.id == operationID && (try reopened.scorecard()).standings().map(\.total) == [8, 11],
                  "A cold launch before path availability resolves the member account and recovers the cached group and pending hand")

        model.updateDiscoveryPath(available: true)
        await model.refresh(accountID: { account }, discover: { GroupDiscoveryResult(groups: groups) })
        try check(!model.isStale, "An online member refresh verifies the full group list")
        model.updateDiscoveryPath(available: false)
        for _ in 0..<3 { await model.refresh(accountID: { account }, discover: emptyDiscovery) }
        try check(discoveries == 0 && model.groups == groups && (try cache.load(account: account)) == original,
                  "Repeated offline refreshes after a warm disconnect leave all four groups in memory and on disk")

        model.updateDiscoveryPath(available: true)
        do {
            _ = try await model.loadRoster(for: target) { _ in
                model.updateDiscoveryPath(available: false)
                throw GroupRosterError.accessLost
            }
            throw Failure(message: "Expected the interrupted membership lookup to stop")
        } catch GroupRepositoryError.groupScopeUnavailable {}
        try check(model.groups == groups && (try cache.load(account: account)) == original &&
                  (try model.resumableGames()).map(\.route) == [route],
                  "An interrupted membership read cannot revoke offline access to the saved scorecard")

        model.updateDiscoveryPath(available: true)
        await model.refresh(accountID: { account }, discover: {
            model.updateDiscoveryPath(available: false)
            model.updateDiscoveryPath(available: true)
            return GroupDiscoveryResult(groups: [])
        }, confirmRemoval: { _, _ in
            throw Failure(message: "A result spanning a path change must reach no removal checks")
        })
        try check(model.groups == groups && (try cache.load(account: account)) == original,
                  "Discard a discovery started before disconnect even when connectivity returns before it finishes")

        var rechecks = 0
        await model.refresh(accountID: {
            rechecks += 1
            if rechecks == 2 { model.updateDiscoveryPath(available: false) }
            return account
        }, discover: emptyDiscovery, confirmRemoval: { _, _ in true })
        try check(rechecks == 2 && model.groups == groups && (try cache.load(account: account)) == original,
                  "Recheck connectivity immediately before applying even a confirmed empty result")

        model.updateDiscoveryPath(available: true)
        await model.refresh(accountID: { account }, discover: emptyDiscovery, confirmRemoval: { _, _ in
            throw CKError(.networkUnavailable)
        })
        try check(model.isStale && model.groups == groups && (try cache.load(account: account)) == original,
                  "An apparently online empty list with inconclusive scoped checks cannot clear the cache")

        let owned = GroupSummary(id: UUID(), zoneOwner: "local-owner", name: "Owned", isOwner: true)
        let wrongZone = GroupSummary(id: target.id, zoneOwner: "wrong-owner", name: target.name, isOwner: false)
        await model.refresh(accountID: { account }, discover: {
            GroupDiscoveryResult(groups: [wrongZone, groups[1], owned], skippedRoots: 1)
        }, confirmRemoval: { group, verified in
            try check(verified == account, "Omitted scope checks use the resolved account")
            if group.scope == target.scope { throw CKError(.participantMayNeedVerification) }
            return group.scope == groups[2].scope
        })
        let partial = try cache.load(account: account)
        let partialResume = try model.resumableGames()
        try check(model.isStale && Set(model.groups) == Set([target, groups[1], groups[3], owned]) &&
                  partial.groups == model.groups && partialResume.map(\.route) == [route],
                  "A partial scan admits positive scopes, confirms removal individually, and retains an inconclusive shared scope")

        try check(GroupRepository.isConfirmedGroupAbsence(CKError(.zoneNotFound)) &&
                  GroupRepository.isConfirmedGroupAbsence(CKError(.permissionFailure)) &&
                  !GroupRepository.isConfirmedGroupAbsence(CKError(.participantMayNeedVerification)),
                  "Direct zone absence and permission denial differ from inconclusive participant verification")
        await model.refresh(accountID: { account }, discover: emptyDiscovery, confirmRemoval: { _, _ in true })
        try check(model.groups.isEmpty && !model.isStale && (try cache.load(account: account)).groups.isEmpty &&
                  (try model.resumableGames()).isEmpty,
                  "Confirmed shared revocation and owned-group deletion can produce an authoritative empty cache")
        do {
            _ = try await model.withSharedGroup(target) { _, _ in true }
            throw Failure(message: "A missing local scope must not reach a shared-group operation")
        } catch GroupRepositoryError.groupScopeUnavailable {}
        try check((try game.load())?.operations.first?.request.id == operationID && (try game.load())?.isEligible == true,
                  "Removing visibility or encountering a local miss preserves the stored journal and pending operation")

        await model.refresh(accountID: { account }, discover: { GroupDiscoveryResult(groups: [target]) })
        try check(model.scoringAccount == account && (try model.resumableGames()).map(\.route) == [route],
                  "Restoring the matching scope under the same account makes the saved game resumable again")
        var identityChecks = 0
        await model.refresh(accountID: {
            identityChecks += 1
            return identityChecks == 1 ? account : "different-account"
        }, discover: emptyDiscovery, confirmRemoval: { _, _ in true })
        try check(model.account == nil && (try cache.load(account: account)).groups == [target],
                  "A changed account during discovery hides the old session without replacing its disk cache")
        model.updateDiscoveryPath(available: false)
        await model.refresh(accountID: { "different-account" }, discover: emptyDiscovery)
        try check(model.scoringAccount == "different-account" && (try model.resumableGames()).isEmpty &&
                  (try game.load())?.operations.first?.request.id == operationID,
                  "A different account cannot read the old journal and its pending scores survive the switch")
    }

    private static func rosterCacheChecks(directory: URL, group: GroupSummary, otherGroup: GroupSummary) async throws {
        let url = directory.appending(path: "roster-cache.store")
        let model = onlineModel(cacheURL: url)
        let account = "roster-account"
        let id = UUID()
        let access = GroupRosterAccess(role: .owner, groupID: group.id, account: account)
        let initial = GroupPlayerIdentity(
            id: id, groupID: group.id, creatorKey: access.creatorKey,
            displayName: "Example Player", retiredAt: nil, changeTag: "1"
        )
        let retired = GroupPlayerIdentity(
            id: id, groupID: group.id, creatorKey: access.creatorKey,
            displayName: initial.displayName, retiredAt: .now, changeTag: "2"
        )
        let contents = GroupRosterContents(access: access, players: [initial])
        let empty = GroupRosterContents(
            access: GroupRosterAccess(role: .editor, groupID: otherGroup.id, account: account), players: []
        )
        await model.refresh(accountID: { account }, discover: { GroupDiscoveryResult(groups: [group, otherGroup]) })
        let live = try await model.loadRoster(for: group) { verified in
            try check(verified == account, "Roster reads are bound to the current account")
            return contents
        }
        _ = try await model.loadRoster(for: otherGroup) { _ in empty }
        try check(live.access == access && model.cachedRoster(for: group)?.players.map(\.id) == [id],
                  "A live roster supplies permissions and populates the display cache")
        try check(model.cachedRoster(for: otherGroup)?.players == [],
                  "A loaded empty roster is distinct from an uncached group and stays group-scoped")
        let wrongZone = GroupSummary(id: group.id, zoneOwner: "other-zone", name: group.name, isOwner: group.isOwner)
        try check(model.cachedRoster(for: wrongZone) == nil, "A matching group UUID cannot read another zone’s cache")

        let session = model.accountGeneration
        try await model.changeRoster(in: group, session: session) { _ in retired }
        try check(model.cachedRoster(for: group)?.players.first?.isRetired == true,
                  "A confirmed write updates the cached row even before a fresh full load")
        do {
            _ = try await model.loadRoster(for: group) { _ in throw CKError(.unknownItem) }
            throw Failure(message: "Expected a child read error")
        } catch let error as CKError {
            try check(error.code == .unknownItem && model.cachedRoster(for: group)?.players.first?.isRetired == true,
                      "An ordinary missing child does not purge the saved roster")
        }
        let reopened = onlineModel(cacheURL: url)
        await reopened.refresh(accountID: { account }, discover: { throw CKError(.networkUnavailable) })
        try check(reopened.cachedRoster(for: group)?.players.first?.isRetired == true,
                  "An identified account can reopen its saved roster during a connection failure")

        do {
            _ = try await model.loadRoster(for: group) { _ in
                _ = try await model.loadRoster(for: group) { _ in
                    GroupRosterContents(access: access, players: [retired])
                }
                throw GroupRosterError.accessLost
            }
            throw Failure(message: "Expected the older roster read to be superseded")
        } catch is CancellationError {
            try check(model.cachedRoster(for: group)?.players.first?.isRetired == true,
                      "An older read failure cannot remove a fresher saved roster")
        }

        model.prepareForAccountRefresh()
        do {
            try await model.changeRoster(in: group, session: session) { _ in
                throw Failure(message: "The old session must not reach the write")
            }
            throw Failure(message: "Expected the old roster editing session to be rejected")
        } catch GroupRepositoryError.accountChanged {}
        do {
            _ = try await model.loadRoster(for: group) { _ in
                await model.refresh(accountID: { "different-account" }, discover: { GroupDiscoveryResult(groups: [group]) })
                return contents
            }
            throw Failure(message: "Expected a late read from the old account to be rejected")
        } catch GroupRepositoryError.accountChanged {
            try check(model.cachedRoster(for: group) == nil, "A late result cannot expose the previous account’s roster")
        }

        await model.refresh(accountID: { account }, discover: { GroupDiscoveryResult(groups: [group]) },
                            confirmRemoval: { omitted, _ in omitted.scope == otherGroup.scope })
        try check(model.cachedRoster(for: otherGroup) == nil && model.snapshot.groupRosters?[otherGroup.id] == nil,
                  "Successful discovery removes saved rosters for groups that disappeared")
        do {
            _ = try await model.loadRoster(for: group) { _ in throw GroupRosterError.accessLost }
            throw Failure(message: "Expected roster membership loss")
        } catch GroupRosterError.accessLost {
            let cache = try GroupCache(url: url)
            let stored = try cache.load(account: account)
            try check(model.cachedRoster(for: group) == nil && stored.groupRosters?[group.id] == nil &&
                      !model.groups.contains(group), "Confirmed roster access loss purges the persisted roster and group")
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("PASS: \(message)")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    private struct Failure: Error {
        let message: String
    }
}
