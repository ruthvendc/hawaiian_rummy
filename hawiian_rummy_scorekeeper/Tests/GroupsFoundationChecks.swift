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
        let model = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
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

        await model.refresh(accountID: { "A" }, discover: { [owned, joined] })
        try check(model.groups == [owned, joined] && owned.id != joined.id, "Discover both same-named groups on an empty cache")

        let cache = try GroupCache(url: cacheURL)
        try cache.save(GroupCacheSnapshot(groups: [owned, joined], pendingLinks: [link]), account: "A")
        let reopened = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        try check(reopened.groups.isEmpty, "Hide cache before resolving the account")
        await reopened.refresh(accountID: { "A" }, discover: { throw CKError(.networkUnavailable) })
        try check(reopened.isStale && reopened.groups == [owned, joined], "Retain current account cache after a network failure")
        try check(reopened.snapshot.pendingLinks == [link], "Retain account’s pending invitation across relaunch")

        reopened.prepareForAccountRefresh()
        await reopened.refresh(accountID: { throw GroupRepositoryError.accountTemporarilyUnavailable }, discover: { [] })
        try check(reopened.groups == [owned, joined] && reopened.account == "A" && reopened.isStale &&
                  reopened.snapshot.pendingLinks == [link],
                  "An account availability notification followed by offline failure retains groups and invitations")
        await reopened.refresh(accountID: { throw CKError(.notAuthenticated) }, discover: { [] })
        try check(reopened.groups == [owned, joined] && reopened.account == "A" && reopened.isStale,
                  "A request authentication failure does not confirm sign-out or discard cached groups")
        let offlineCache = try cache.load(account: "A")
        try check(offlineCache.groups == [owned, joined] && offlineCache.pendingLinks == [link],
                  "Failed account refreshes do not replace the persisted cache with an empty list")

        await reopened.refresh(accountID: { "B" }, discover: { [other] })
        try check(reopened.groups == [other] && reopened.snapshot.pendingLinks.isEmpty, "Switch accounts without leaking cached groups or links")
        let original = try cache.load(account: "A")
        try check(original.groups == [owned, joined] && original.pendingLinks == [link], "Retain first account’s private cache")

        await reopened.refresh(accountID: { "A" }, discover: { [owned] })
        try check(reopened.groups == [owned] && !reopened.isStale, "Remove a joined group omitted by successful server discovery")
        await reopened.refresh(accountID: { throw GroupRepositoryError.accountTemporarilyUnavailable }, discover: { [] })
        try check(reopened.groups == [owned] && reopened.isStale, "Do not clear cache on temporary account failure")
        await reopened.refresh(accountID: { throw GroupRepositoryError.unavailable }, discover: { [] })
        try check(reopened.groups.isEmpty && reopened.account == nil, "Hide cache after sign-out")

        await reopened.refresh(accountID: { "A" }, discover: {
            reopened.invalidateAccount()
            await reopened.refresh(accountID: { "B" }, discover: { [other] })
            return [owned, joined]
        })
        try check(reopened.account == "B" && reopened.groups == [other], "Ignore a late response from the previous account")
        try check(!GroupsModel.isAccessLoss(CKError(.networkFailure)), "Network failures do not confirm access loss")
        try check(GroupsModel.isAccessLoss(CKError(.permissionFailure)), "Permission denial confirms access loss")

        let sameInvitation = try require(URL(string: "https://icloud.com/share/test#Family"), "Equivalent share link")
        try cache.save(GroupCacheSnapshot(groups: [other], pendingLinks: [link, sameInvitation]), account: "recipient")
        let waiting = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        await waiting.refresh(accountID: { "recipient" }, discover: { [other] }, resolveInvitation: { _, account in
            try check(account == "recipient", "Only check an invitation under its saved account")
            throw GroupRepositoryError.approvalRequired
        })
        try check(waiting.snapshot.pendingLinks == [link] && waiting.isPending(sameInvitation),
                  "Recognize the same share with a different host alias or fragment")
        try check(waiting.invitationState(for: link) == .waiting && waiting.groups == [other],
                  "Waiting for approval grants no access")
        await waiting.refresh(accountID: { "recipient" }, discover: { [other] }, resolveInvitation: { _, _ in
            throw CKError(.networkFailure)
        }, pendingOnly: true)
        try check(waiting.invitationState(for: link) == .retrying && waiting.isPending(link),
                  "A temporary failure retains the pending request")

        let relaunched = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        await relaunched.refresh(accountID: { "recipient" }, discover: { [other] }, resolveInvitation: { _, _ in joined.id })
        try check(relaunched.invitationState(for: link) == .joining && relaunched.isPending(link),
                  "After relaunch, retain the accepted link until CloudKit discovery catches up")
        await relaunched.refresh(accountID: { "recipient" }, discover: { [other, joined] },
                                 resolveInvitation: { _, _ in joined.id }, pendingOnly: true)
        try check(relaunched.snapshot.pendingLinks.isEmpty && relaunched.groups == [other, joined]
                    && relaunched.invitationState(for: link) == .joined,
                  "Automatically rediscover the approved group and clear only its pending link")

        try cache.save(GroupCacheSnapshot(groups: [other], pendingLinks: [link]), account: "verification")
        let verification = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        await verification.refresh(accountID: { "verification" }, discover: { [other] }, resolveInvitation: { _, _ in
            throw CKError(.participantMayNeedVerification)
        })
        try check(verification.invitationState(for: link) == .needsVerification && !verification.hasPollableInvitations,
                  "Pause automatic retries when Apple requires verification")
        verification.willVerifyInvitation(link)
        try check(verification.hasPollableInvitations, "Resume checking after verification is opened")

        await verification.refresh(accountID: { "verification" }, discover: { [other] }, resolveInvitation: { _, _ in
            throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
        })
        var checksDuringBackoff = 0
        await verification.refresh(accountID: { "verification" }, discover: { [other] }, resolveInvitation: { _, _ in
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

        let names = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        await names.refresh(accountID: { "A" }, discover: { [owned, joined] })
        let savedDraft = names.keepMemberNameDraft("David", in: owned, account: "A")
        let savedClear = names.keepMemberNameDraft("", in: joined, account: "A")
        try check(savedDraft && savedClear, "Keep separate drafts, including a pending clear, for groups in the same account")
        let savedUnderWrongAccount = await names.saveMyDisplayName("Wrong account", in: owned, account: "B")
        try check(!savedUnderWrongAccount, "Reject a save from an editor opened under a different account")
        let namesRelaunched = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        await namesRelaunched.refresh(accountID: { "A" }, discover: { throw CKError(.networkFailure) })
        try check(namesRelaunched.snapshot.memberNameDrafts?[owned.id] == "David" &&
                  namesRelaunched.snapshot.memberNameDrafts?[joined.id] == "", "Keep offline drafts across launch without changing groups")
        await namesRelaunched.refresh(accountID: { "B" }, discover: { [other] })
        try check(namesRelaunched.snapshot.memberNameDrafts == nil, "Do not show drafts across iCloud accounts")

        let root = CKRecord(recordType: GroupRecordTypes.group, recordID: CKRecord.ID(recordName: "group"))
        let share = CKShare(rootRecord: root)
        var liveDetails = GroupDetails(group: owned, share: share, invitationURL: nil)
        liveDetails.memberDisplayNames[share.owner.participantID] = "David"
        let detailsModel = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
        await detailsModel.refresh(accountID: { "details-account" }, discover: { [owned, joined] })
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
        let detailsRelaunched = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: cacheURL)
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
        await detailsRelaunched.refresh(accountID: { "details-account" }, discover: { [joined] })
        try check(detailsRelaunched.cachedDetails(for: owned) == nil &&
                  detailsRelaunched.snapshot.groupDetails?[owned.id] == nil && !detailsRelaunched.isStale,
                  "Successful online discovery removes deleted or revoked groups and cached membership")
        await detailsRelaunched.refresh(accountID: { "details-account" }, discover: { [owned, joined] })
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
        await detailsRelaunched.refresh(accountID: { "another-account" }, discover: { [other] })
        try check(detailsRelaunched.cachedDetails(for: owned) == nil && detailsRelaunched.snapshot.groupDetails == nil,
                  "Cached membership never crosses a verified account switch")
        try check(legacySnapshot.groupDetails == nil, "Existing cache snapshots decode without membership data")
        try check(legacySnapshot.groupRosters == nil, "Existing cache snapshots decode without roster data")
        try await rosterCacheChecks(directory: directory, group: owned, otherGroup: joined)
        print("Groups Foundation checks passed.")
    }

    private static func rosterCacheChecks(directory: URL, group: GroupSummary, otherGroup: GroupSummary) async throws {
        let url = directory.appending(path: "roster-cache.store")
        let model = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: url)
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
        await model.refresh(accountID: { account }, discover: { [group, otherGroup] })
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
        let reopened = GroupsModel(containerIdentifier: "unused-in-local-checks", cacheURL: url)
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
                await model.refresh(accountID: { "different-account" }, discover: { [group] })
                return contents
            }
            throw Failure(message: "Expected a late read from the old account to be rejected")
        } catch GroupRepositoryError.accountChanged {
            try check(model.cachedRoster(for: group) == nil, "A late result cannot expose the previous account’s roster")
        }

        await model.refresh(accountID: { account }, discover: { [group] })
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
