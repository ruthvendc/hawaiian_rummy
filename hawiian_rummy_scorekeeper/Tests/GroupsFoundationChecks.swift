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
        print("Groups Foundation checks passed.")
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
