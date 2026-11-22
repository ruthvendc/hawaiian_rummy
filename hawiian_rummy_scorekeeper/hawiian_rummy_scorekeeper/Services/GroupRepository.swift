#if DEBUG
import CloudKit
import CryptoKit
import Foundation
import OSLog

struct GroupDetails {
    let group: GroupSummary
    let share: CKShare
    let invitationURL: URL?
    var memberDisplayNames: [CKShare.Participant.ID: String] = [:]
    var memberNamesUnavailable = false

    var members: [CKShare.Participant] {
        share.participants.filter { $0.role != .owner && $0.acceptanceStatus != .removed }
    }

    var requests: [CKShare.AccessRequester] {
        group.isOwner ? share.requesters : []
    }

    var canEditMyDisplayName: Bool {
        guard let current = share.currentUserParticipant else { return false }
        return current.role == .owner || (current.acceptanceStatus == .accepted && current.permission == .readWrite)
    }

    var myDisplayName: String? {
        share.currentUserParticipant.flatMap { memberDisplayNames[$0.participantID] }
    }

    func isCurrentUser(_ participant: CKShare.Participant) -> Bool {
        if participant.role == .owner { return group.isOwner }
        guard let current = share.currentUserParticipant else { return false }
        return participant.participantID == current.participantID || participant.isEqual(current)
    }

    func displayName(for participant: CKShare.Participant) -> String? {
        GroupMemberDisplayName.preferredName(
            custom: memberDisplayNames[participant.participantID],
            cloudKit: participant.userIdentity.nameComponents?.formatted()
        )
    }

    var cachedDetails: CachedGroupDetails {
        let participants = [share.owner] + members
        return CachedGroupDetails(members: participants.map { participant in
            let isYou = isCurrentUser(participant)
            let role = participant.role == .owner ? "Owner" :
                participant.acceptanceStatus == .accepted ? "Member" : "Invited"
            let fallback = participant.role == .owner ? "Group Owner" :
                participant.acceptanceStatus == .accepted ? "Member" : "Invited Member"
            let name = displayName(for: participant)
            return CachedGroupDetails.Member(
                id: participant.participantID,
                name: name.map { isYou ? "\($0) (You)" : $0 } ?? (isYou ? "You" : fallback),
                role: name != nil || isYou ? role : nil
            )
        }, savedAt: .now)
    }
}

enum GroupMembershipChange {
    case approve(CKUserIdentity.LookupInfo)
    case deny(CKUserIdentity.LookupInfo)
    case block(CKUserIdentity.LookupInfo)
    case revoke(CKShare.Participant.ID)
    case allowRequests(Bool)
}

enum GroupRepositoryError: LocalizedError {
    case accountChanged, unavailable, accountTemporarilyUnavailable
    case invalidGroup, invalidLink, approvalRequired, ownerRequired, requestChanged
    case memberNameNotWritable, memberNameInvalid

    var errorDescription: String? {
        switch self {
        case .accountChanged: "Your iCloud account changed. Refresh Groups and try again."
        case .unavailable: "Sign in to iCloud to use Groups."
        case .accountTemporarilyUnavailable: "Couldn’t verify your iCloud account. Check your connection and try again."
        case .invalidGroup: "This group is unavailable or uses an unsupported format."
        case .invalidLink: "Enter a Hawaiian Rummy group invitation link."
        case .approvalRequired: "The owner must approve your request before you can join."
        case .ownerRequired: "Only the group owner can do this."
        case .requestChanged: "This request or membership changed. Refresh and try again."
        case .memberNameNotWritable: "You can only change your own display name while you have access to this group."
        case .memberNameInvalid: "Use one line of up to \(GroupMemberDisplayName.maximumLength) characters."
        }
    }
}

struct GroupRepository {
    private static let zonePrefix = "RummyGroup-"
    private static let rootName = "group"
    private static let memberNamePrefix = "member-name-"
    private static let accountNamePrefix = memberNamePrefix + "account-"
    private static let logger = Logger(subsystem: "com.davidruthven.hawiian-rummy-scorekeeper", category: "GroupDisplayNames")
    private let container: CKContainer

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func accountID() async throws -> String {
        switch try await container.accountStatus() {
        case .available: return try await container.userRecordID().recordName
        case .noAccount, .restricted: throw GroupRepositoryError.unavailable
        default: throw GroupRepositoryError.accountTemporarilyUnavailable
        }
    }

    func verifyAccount(_ account: String) async throws {
        guard try await accountID() == account else { throw GroupRepositoryError.accountChanged }
    }

    func discover() async throws -> [GroupSummary] {
        async let owned = discover(in: container.privateCloudDatabase, isOwner: true)
        async let joined = discover(in: container.sharedCloudDatabase, isOwner: false)
        return try await (owned + joined).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    func create(name: String, displayName: String, id: UUID, account: String) async throws -> GroupSummary {
        let memberName = try validatedMemberName(displayName)
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: Self.zoneName(id))
        let rootID = CKRecord.ID(recordName: Self.rootName, zoneID: zone.zoneID)

        // Keep the same identity when retrying after an ambiguous server response.
        if let existing = try await existingRoot(rootID, in: database) {
            let group = try summary(for: existing, isOwner: true)
            let details = try await details(for: group)
            guard let url = details.share.url else { throw GroupRepositoryError.invalidGroup }
            try await publishInvitationURL(url, on: existing, account: account)
            return group
        }

        try await verifyAccount(account)
        _ = try await database.save(zone)
        let root = CKRecord(recordType: GroupRecordTypes.group, recordID: rootID)
        root["groupID"] = id.uuidString
        root["name"] = name
        root["createdAt"] = Date.now
        root["schemaVersion"] = 1

        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = name
        share.publicPermission = .none
        share.allowsAccessRequests = true

        try await verifyAccount(account)
        var records: [CKRecord] = [root, share]
        if !memberName.isEmpty { records.append(makeNameRecord(memberName, account: account, root: rootID)) }
        let result = try await database.modifyRecords(
            saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        for record in records {
            guard let saved = result.saveResults[record.recordID] else { throw GroupRepositoryError.invalidGroup }
            _ = try saved.get()
        }
        guard let savedRoot = try result.saveResults[rootID]?.get(),
              let savedShare = try result.saveResults[share.recordID]?.get() as? CKShare,
              let url = savedShare.url, savedShare.publicPermission == .none else {
            throw GroupRepositoryError.invalidGroup
        }
        try await publishInvitationURL(url, on: savedRoot, account: account)
        return try summary(for: savedRoot, isOwner: true)
    }

    func details(for group: GroupSummary) async throws -> GroupDetails {
        let (root, fetchedShare) = try await groupShare(for: group)
        guard let share = fetchedShare,
              share.publicPermission == .none,
              let participant = share.currentUserParticipant,
              participant.acceptanceStatus == .accepted || participant.role == .owner,
              (participant.role == .owner) == group.isOwner else {
            throw GroupRepositoryError.invalidGroup
        }
        var invitationURL = share.url
        // A member may receive a share with restricted fields. Verify the link from the
        // shared root before surfacing it, since group writers can edit that record.
        if invitationURL == nil, let value = root["invitationURL"] as? String,
           let url = GroupsModel.invitationURL(from: value),
           let metadata = try? await container.shareMetadata(for: url),
           acceptsMetadata(metadata), metadata.share.recordID == share.recordID,
           metadata.hierarchicalRootRecordID == root.recordID {
            invitationURL = url
        }
        return try GroupDetails(
            group: summary(for: root, isOwner: group.isOwner), share: share, invitationURL: invitationURL
        )
    }

    private func groupShare(for group: GroupSummary) async throws -> (CKRecord, CKShare?) {
        let database = database(for: group)
        let root = try await database.record(for: rootID(for: group))
        guard let shareID = root.share?.recordID else { return (root, nil) }
        return (root, try await database.record(for: shareID) as? CKShare)
    }

    func roster(for group: GroupSummary, account: String) -> GroupRoster {
        let root = rootID(for: group)
        let verify = { try await self.verifyAccount(account) }
        return GroupRoster(
            groupID: group.id, root: root,
            store: GroupRosterCloudStore(database: database(for: group), root: root, verifyAccount: verify),
            authorize: { try await self.rosterAccess(for: group, account: account) },
            verifyAccount: verify
        )
    }

    func cloudStore(for group: GroupSummary, account: String) -> GroupCloudStore {
        GroupCloudStore(database: database(for: group), zoneID: rootID(for: group).zoneID,
                        verifyAccount: { try await self.verifyAccount(account) })
    }

    private func rosterAccess(for group: GroupSummary, account: String) async throws -> GroupRosterAccess {
        try await verifiedMembership(for: group, account: account).access
    }

    func gameManagementShare(for group: GroupSummary, account: String) async throws -> CKShare {
        let (share, access) = try await verifiedMembership(for: group, account: account)
        try access.requireOwner()
        return share
    }

    private func verifiedMembership(
        for group: GroupSummary, account: String
    ) async throws -> (share: CKShare, access: GroupRosterAccess) {
        try await verifyAccount(account)
        let root: CKRecord
        let fetchedShare: CKShare?
        do {
            (root, fetchedShare) = try await groupShare(for: group)
        } catch where GroupsModel.isAccessLoss(error) {
            try await verifyAccount(account)
            throw GroupRosterError.accessLost
        }
        try await verifyAccount(account)
        guard root.recordID == rootID(for: group),
              try summary(for: root, isOwner: group.isOwner).id == group.id else {
            throw GroupRepositoryError.invalidGroup
        }
        guard let shareID = root.share?.recordID else { throw GroupRosterError.accessLost }
        guard let share = fetchedShare, share.recordID == shareID, shareID.zoneID == root.recordID.zoneID,
              share.publicPermission == .none else { throw GroupRepositoryError.invalidGroup }
        guard let participant = share.currentUserParticipant,
              participant.role == .owner || participant.acceptanceStatus == .accepted else {
            throw GroupRosterError.accessLost
        }
        let isOwner = participant.role == .owner
        guard isOwner == group.isOwner else { throw GroupRepositoryError.invalidGroup }
        // These roles govern app actions. A read/write participant has broader CloudKit permissions.
        let role: GroupRosterAccess.Role = isOwner ? .owner : participant.permission == .readWrite ? .editor : .reader
        return (share, GroupRosterAccess(role: role, groupID: group.id, account: account,
                                        participantID: participant.participantID))
    }

    func loadMemberDisplayNames(in details: GroupDetails, account: String) async -> GroupDetails {
        var updated = details
        let root = rootID(for: details.group)
        let participants = [details.share.owner] + details.members.filter { $0.acceptanceStatus == .accepted }
        do {
            let records = try await memberNameRecords(in: root, database: database(for: details.group))
            for participant in participants {
                let isYou = details.isCurrentUser(participant)
                let userID = isYou ? account : participant.role == .owner ? root.zoneID.ownerName :
                    participant.userIdentity.userRecordID?.recordName
                if let record = latestNameRecord(
                    for: participant, account: userID, viewer: account, in: records
                ),
                   let name = GroupMemberDisplayName.visibleName(record["displayName"] as? String) {
                    updated.memberDisplayNames[participant.participantID] = name
                    if isYou, let current = details.share.currentUserParticipant {
                        updated.memberDisplayNames[current.participantID] = name
                    }
                }
            }
            Self.logger.debug("Read \(records.count, privacy: .public) member name records, resolved \(updated.memberDisplayNames.count, privacy: .public) names; owner view: \(details.group.isOwner, privacy: .public)")
        } catch {
            // Optional names should never prevent reading the share or managing memberships.
            updated.memberNamesUnavailable = true
            Self.logger.error("Member name fetch failed; error code: \((error as NSError).code, privacy: .public)")
        }
        return updated
    }

    func saveMyDisplayName(_ input: String, in group: GroupSummary, account: String) async throws {
        let name = try validatedMemberName(input)
        try await verifyAccount(account)
        let current = try await details(for: group)
        // CloudKit identifies this participant for the current session. Its exposed
        // identity can be an alias and need not match the container account record ID.
        guard current.canEditMyDisplayName, let participant = current.share.currentUserParticipant else {
            throw GroupRepositoryError.memberNameNotWritable
        }

        let root = rootID(for: current.group)
        let database = database(for: group)
        let records = try await memberNameRecords(in: root, database: database)
        let record: CKRecord
        if let existing = latestNameRecord(for: participant, account: account, viewer: account, in: records) {
            record = existing
        } else {
            if name.isEmpty { return }
            record = makeNameRecord(name, account: account, root: root)
        }
        try await verifyAccount(account)
        record["displayName"] = name
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        guard let saved = result.saveResults[record.recordID] else { throw GroupRepositoryError.invalidGroup }
        _ = try saved.get()
    }

    private func validatedMemberName(_ input: String) throws -> String {
        let name = GroupMemberDisplayName.trimmed(input)
        guard name.isEmpty || GroupMemberDisplayName.visibleName(name) != nil else {
            throw GroupRepositoryError.memberNameInvalid
        }
        return name
    }

    private func makeNameRecord(_ name: String, account: String, root: CKRecord.ID) -> CKRecord {
        let key = nameRecordKey(for: account, prefix: Self.accountNamePrefix)
        let id = CKRecord.ID(recordName: key, zoneID: root.zoneID)
        let record = CKRecord(recordType: GroupRecordTypes.memberDisplayName, recordID: id)
        record.setParent(root)
        record["displayName"] = name
        return record
    }

    private func nameRecordKey(for identity: String, prefix: String) -> String {
        prefix + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func memberNameRecords(in root: CKRecord.ID, database: CKDatabase) async throws -> [CKRecord] {
        // Read the same shared children in the owner's private database and the member's shared database.
        // Existing records can then be found using their CloudKit creator even if a participant key differs.
        var records: [CKRecord.ID: CKRecord] = [:]
        var token: CKServerChangeToken?
        while true {
            let page = try await database.recordZoneChanges(inZoneWith: root.zoneID, since: token)
            for (id, result) in page.modificationResultsByID where id.recordName.hasPrefix(Self.memberNamePrefix) {
                let record = try result.get().record
                if Self.isMemberNameRecord(record, in: root) { records[id] = record }
            }
            for deletion in page.deletions { records.removeValue(forKey: deletion.recordID) }
            guard page.moreComing else { return Array(records.values) }
            token = page.changeToken
        }
    }

    private static func isMemberNameRecord(_ record: CKRecord, in root: CKRecord.ID) -> Bool {
        // This fetch is already scoped to the verified group zone. CloudKit may represent
        // the zone owner differently in the private and shared databases.
        record.recordType == GroupRecordTypes.memberDisplayName &&
            record.parent?.recordID.recordName == root.recordName &&
            record.parent?.recordID.zoneID.zoneName == root.zoneID.zoneName
    }

    private func latestNameRecord(
        for participant: CKShare.Participant, account: String?, viewer: String, in records: [CKRecord]
    ) -> CKRecord? {
        let accountKey = account.map { nameRecordKey(for: $0, prefix: Self.accountNamePrefix) }
        let legacyKey = nameRecordKey(for: participant.participantID, prefix: Self.memberNamePrefix)
        return records.filter {
            GroupMemberDisplayName.matchesRecord(
                directMatch: $0.recordID.recordName == accountKey || $0.recordID.recordName == legacyKey,
                account: account,
                creator: Self.memberNameAccountID($0.creatorUserRecordID?.recordName, viewer: viewer),
                lastEditor: Self.memberNameAccountID($0.lastModifiedUserRecordID?.recordName, viewer: viewer)
            )
        }.max {
            let lhs = $0.modificationDate ?? .distantPast
            let rhs = $1.modificationDate ?? .distantPast
            return lhs == rhs ? $0.recordID.recordName < $1.recordID.recordName : lhs < rhs
        }
    }

    static func memberNameAccountID(_ recordName: String?, viewer: String) -> String? {
        recordName == CKCurrentUserDefaultName ? viewer : recordName
    }

    func changeMembership(_ change: GroupMembershipChange, group: GroupSummary, account: String) async throws {
        let details = try await ownerDetails(for: group)
        let share = details.share
        switch change {
        case .approve(let lookup):
            _ = try requester(lookup, in: share)
            let result = try await container.shareParticipants(for: [lookup])
            guard let participant = try result[lookup]?.get() else { throw GroupRepositoryError.requestChanged }
            participant.role = .privateUser
            participant.permission = .readWrite
            share.addParticipant(participant)
        case .deny(let lookup):
            share.denyRequesters([try requester(lookup, in: share)])
        case .block(let lookup):
            share.blockRequesters([try requester(lookup, in: share)])
        case .revoke(let id):
            guard let participant = details.members.first(where: { $0.participantID == id }) else {
                throw GroupRepositoryError.requestChanged
            }
            share.removeParticipant(participant)
        case .allowRequests(let enabled):
            share.allowsAccessRequests = enabled
        }
        try await verifyAccount(account)
        _ = try await container.privateCloudDatabase.save(share)
    }

    func leave(_ group: GroupSummary, account: String) async throws {
        guard !group.isOwner else { throw GroupRepositoryError.invalidGroup }
        let details = try await self.details(for: group)
        try await verifyAccount(account)
        _ = try await container.sharedCloudDatabase.deleteRecord(withID: details.share.recordID)
    }

    func delete(_ group: GroupSummary, account: String) async throws {
        _ = try await ownerDetails(for: group)
        try await verifyAccount(account)
        _ = try await container.privateCloudDatabase.deleteRecordZone(withID: rootID(for: group).zoneID)
    }

    func requestAccess(to url: URL, account: String) async throws {
        try await verifyAccount(account)
        do {
            let results = try await container.requestShareAccess(for: [url])
            guard let result = results[url] else { throw GroupRepositoryError.invalidLink }
            try result.get()
        } catch where Self.invitationError(error, for: url)?.code == .participantAlreadyInvited {
            // A prior request or invitation can already have been approved.
            // The normal refresh still verifies and accepts the private share.
        }
    }

    func invitationMetadata(for url: URL) async throws -> CKShare.Metadata {
        do {
            return try await container.shareMetadata(for: url)
        } catch {
            let cloud = Self.invitationError(error, for: url)
            throw cloud ?? error
        }
    }

    private static func invitationError(_ error: Error, for url: URL) -> CKError? {
        guard let cloud = error as? CKError else { return nil }
        return (cloud.partialErrorsByItemID?[url] as? CKError) ?? cloud
    }

    func acceptsMetadata(_ metadata: CKShare.Metadata) -> Bool {
        guard metadata.containerIdentifier == container.containerIdentifier,
              let root = metadata.hierarchicalRootRecordID else { return false }
        return root.recordName == Self.rootName && Self.groupID(in: root.zoneID) != nil
    }

    func accept(_ metadata: CKShare.Metadata, account: String) async throws -> UUID {
        guard acceptsMetadata(metadata), metadata.share.publicPermission == .none,
              let zone = metadata.hierarchicalRootRecordID?.zoneID,
              let groupID = Self.groupID(in: zone) else {
            throw GroupRepositoryError.invalidLink
        }
        try await verifyAccount(account)
        switch metadata.participantStatus {
        case .pending: _ = try await container.accept(metadata)
        case .accepted: break
        default: throw GroupRepositoryError.approvalRequired
        }
        return groupID
    }

    private func discover(in database: CKDatabase, isOwner: Bool) async throws -> [GroupSummary] {
        let zones = try await database.allRecordZones()
        var groups: [GroupSummary] = []
        for zone in zones where Self.groupID(in: zone.zoneID) != nil {
            let id = CKRecord.ID(recordName: Self.rootName, zoneID: zone.zoneID)
            do {
                if let root = try await existingRoot(id, in: database), root.share != nil {
                    groups.append(try summary(for: root, isOwner: isOwner))
                }
            } catch where !isOwner && GroupsModel.isAccessLoss(error) {
                continue
            }
        }
        return groups
    }

    private func existingRoot(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    private func publishInvitationURL(_ url: URL, on root: CKRecord, account: String) async throws {
        guard root["invitationURL"] as? String != url.absoluteString else { return }
        root["invitationURL"] = url.absoluteString
        try await verifyAccount(account)
        _ = try await container.privateCloudDatabase.save(root)
    }

    private func summary(for root: CKRecord, isOwner: Bool) throws -> GroupSummary {
        let zone = root.recordID.zoneID
        guard root.recordType == GroupRecordTypes.group,
              root.recordID.recordName == Self.rootName,
              let id = Self.groupID(in: zone),
              let rawID = root["groupID"] as? String, UUID(uuidString: rawID) == id,
              let name = root["name"] as? String,
              root["schemaVersion"] as? Int == 1 else {
            throw GroupRepositoryError.invalidGroup
        }
        return GroupSummary(id: id, zoneOwner: zone.ownerName, name: name, isOwner: isOwner)
    }

    private func ownerDetails(for group: GroupSummary) async throws -> GroupDetails {
        guard group.isOwner else { throw GroupRepositoryError.ownerRequired }
        return try await details(for: group)
    }

    private func requester(_ lookup: CKUserIdentity.LookupInfo, in share: CKShare) throws -> CKShare.AccessRequester {
        guard let requester = share.requesters.first(where: { $0.participantLookupInfo == lookup }) else {
            throw GroupRepositoryError.requestChanged
        }
        return requester
    }

    private func database(for group: GroupSummary) -> CKDatabase {
        group.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func rootID(for group: GroupSummary) -> CKRecord.ID {
        let zone = CKRecordZone.ID(zoneName: Self.zoneName(group.id), ownerName: group.zoneOwner)
        return CKRecord.ID(recordName: Self.rootName, zoneID: zone)
    }

    private static func zoneName(_ id: UUID) -> String { zonePrefix + id.uuidString }

    private static func groupID(in zone: CKRecordZone.ID) -> UUID? {
        guard zone.zoneName.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(zone.zoneName.dropFirst(zonePrefix.count)))
    }
}
#endif
