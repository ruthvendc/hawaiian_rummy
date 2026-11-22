#if DEBUG
import CloudKit
import Foundation

enum GroupGameError: LocalizedError, Equatable {
    case wrongGroup, notScorekeeper, gameNotFound, invalidRecord, invalidPlayers
    case invalidScores, invalidTransition, staleGame, reusedOperation
    case gameDeleted, scorekeeperUnavailable, deletionTooLarge

    var errorDescription: String? {
        switch self {
        case .wrongGroup: "This game belongs to a different group."
        case .notScorekeeper: "Only the assigned scorekeeper can change this game."
        case .gameNotFound: "This group game is no longer available."
        case .invalidRecord: "The shared game contains a record with an unexpected format."
        case .invalidPlayers: "Choose at least two different active players from this group."
        case .invalidScores: "Enter a non-negative whole-number score for each participant."
        case .invalidTransition: "That change isn’t available in this game’s current state."
        case .staleGame: "This game changed on another device. Refresh and review your change."
        case .reusedOperation: "This operation ID was already used for a different change."
        case .gameDeleted: "This group game was permanently deleted."
        case .scorekeeperUnavailable: "That member is no longer eligible to keep score. Refresh and choose an active member."
        case .deletionTooLarge: "This game exceeds CloudKit’s limit for a single permanent deletion."
        }
    }
}

protocol GroupGameRecordStore: GroupRecordStore {
    func gameChildren(of game: CKRecord.ID) async throws -> [GroupStoredRecord]
    func saveManagement(
        _ records: [GroupStoredRecord], deleting ids: [CKRecord.ID], checking share: GroupStoredRecord
    ) async throws -> [CKRecord.ID: GroupStoredRecord]
}

struct GroupGameOwnerAuthority {
    let share: GroupStoredRecord
    let eligibleKeys: Set<String>
}

struct GroupGameStore {
    let groupID: UUID
    let root: CKRecord.ID
    let store: any GroupGameRecordStore
    let authorize: () async throws -> GroupRosterAccess
    let verifyAccount: () async throws -> Void
    let loadPlayers: () async throws -> [GroupPlayerIdentity]
    let loadOwnerAuthority: () async throws -> GroupGameOwnerAuthority

    func list(fetchHeaders: () async throws -> [GroupStoredRecord]) async throws -> [GroupGameHeader] {
        _ = try await authorize()
        let headers = try await fetchHeaders().compactMap { entry -> GroupGameHeader? in
            guard let id = Self.gameUUID(entry.record.recordID) else { throw GroupGameError.invalidRecord }
            if try isDeleted(entry, game: id) { return nil }
            return try decodeHeader(entry, game: id)
        }
        try await verifyAccount()
        return headers.sorted {
            let left = $0.createdAt ?? .distantPast
            let right = $1.createdAt ?? .distantPast
            return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
        }
    }

    func load(_ gameID: UUID) async throws -> GroupGameSnapshot {
        try await loadWithAccess(gameID).game
    }

    func loadWithAccess(_ gameID: UUID) async throws -> (game: GroupGameSnapshot, access: GroupRosterAccess) {
        let access = try await authorize()
        let (_, header) = try await fetchHeader(gameID)
        var rounds: [GroupGameRound] = []
        do {
            for number in 1...header.roundCount {
                let (_, round) = try await fetchRound(number, header: header)
                guard number == header.roundCount || round.hands.count == LevelDefinition.all.count else {
                    throw GroupGameError.invalidRecord
                }
                rounds.append(round)
            }
        } catch GroupGameError.invalidRecord {
            // An in-flight read can reach a round just after the deletion batch removes it.
            guard try await fetchHeader(gameID).1.version == header.version else { throw GroupGameError.staleGame }
            throw GroupGameError.invalidRecord
        }
        let (_, current) = try await fetchHeader(gameID)
        guard current.version == header.version else { throw GroupGameError.staleGame }
        try await verifyAccount()
        return (GroupGameSnapshot(header: header, rounds: rounds), access)
    }

    func perform(_ operation: GroupGameOperation) async throws -> GroupGameReceipt {
        guard operation.groupID == groupID else { throw GroupGameError.wrongGroup }
        let access = try await authorize()
        if operation.action.requiresOwner {
            try access.requireOwner()
        } else {
            try access.requireAdd()
        }
        let revision = try resultRevision(for: operation)
        let fingerprint = GroupRoster.digest("game-operation-v1:" + String(decoding: try encode(operation), as: UTF8.self))
        if let receipt = try await findReceipt(for: operation, revision: revision, key: access.creatorKey, fingerprint: fingerprint) {
            return receipt
        }

        let receiptID = receiptID(for: operation)
        do {
            var batch = try await changes(for: operation, revision: revision, access: access)
            let acknowledgment = newRecord(GroupRecordTypes.gameOperation, id: receiptID, parent: gameID(operation.gameID))
            acknowledgment.record["actorKey"] = access.creatorKey
            acknowledgment.record["fingerprint"] = fingerprint
            acknowledgment.record["revision"] = revision
            batch.records.append(acknowledgment)

            guard try await authorize() == access else { throw GroupRosterError.notAuthorized }
            try Task.checkCancellation()
            let saved: [CKRecord.ID: GroupStoredRecord]
            if operation.action.requiresOwner {
                let authority = try await loadOwnerAuthority()
                if case .reassignScorekeeper(let key) = operation.action, !authority.eligibleKeys.contains(key) {
                    throw GroupGameError.scorekeeperUnavailable
                }
                // A membership change after the eligibility check invalidates the share's change tag.
                saved = try await store.saveManagement(batch.records, deleting: batch.deleting, checking: authority.share)
            } else {
                saved = try await store.saveAtomically(batch.records)
            }
            try await verifyAccount()
            guard let stored = saved[receiptID] else {
                throw GroupAtomicWriteError.unconfirmed(GroupGameError.invalidRecord)
            }
            return try decodeReceipt(stored, operation: operation, revision: revision,
                                     key: access.creatorKey, fingerprint: fingerprint)
        } catch let error as CKError where error.code == .limitExceeded {
            if case .delete = operation.action { throw GroupGameError.deletionTooLarge }
            throw error
        } catch let error where error is GroupAtomicWriteError ||
            (error as? GroupGameError) == .staleGame || (error as? GroupGameError) == .gameDeleted {
            // A matching receipt is durable even if a later operation updated the game.
            guard try await authorize() == access else { throw GroupRosterError.notAuthorized }
            if let receipt = try await findReceipt(
                for: operation, revision: revision, key: access.creatorKey, fingerprint: fingerprint
            ) { return receipt }
            if case GroupAtomicWriteError.conflict = error { throw GroupGameError.staleGame }
            throw error
        }
    }

    private func resultRevision(for operation: GroupGameOperation) throws -> Int {
        if case .create = operation.action {
            guard operation.expectedVersion == nil, operation.id == operation.gameID else {
                throw GroupGameError.invalidTransition
            }
            return 1
        }
        guard let version = operation.expectedVersion, (1..<Int.max).contains(version.revision),
              !version.changeTag.isEmpty, operation.id != operation.gameID else {
            throw GroupGameError.invalidTransition
        }
        return version.revision + 1
    }

    private func changes(
        for operation: GroupGameOperation, revision: Int, access: GroupRosterAccess
    ) async throws -> (records: [GroupStoredRecord], deleting: [CKRecord.ID]) {
        let game = operation.gameID
        if case .create(let playerIDs) = operation.action {
            if let existing = try await store.record(for: gameID(game)), try isDeleted(existing, game: game) {
                throw GroupGameError.gameDeleted
            }
            return (try await createRecords(id: game, playerIDs: playerIDs, key: access.creatorKey), [])
        }
        let (entry, header) = try await fetchHeader(game)
        if !operation.action.requiresOwner, !access.isScorekeeper(header.scorekeeperKey) {
            throw GroupGameError.notScorekeeper
        }
        guard header.version == operation.expectedVersion else { throw GroupGameError.staleGame }
        if case .delete = operation.action {
            let children = try await childrenForDeletion(header)
            entry.record["revision"] = revision
            entry.record["deletedAt"] = Date.now
            for key in ["participants", "creatorKey", "scorekeeperKey", "roundCount", "completedAt", "cancelledAt"] {
                entry.record[key] = nil
            }
            return ([entry], children)
        }
        guard header.status == .inProgress else { throw GroupGameError.invalidTransition }
        entry.record["revision"] = revision

        switch operation.action {
        case .create, .delete:
            throw GroupGameError.invalidTransition
        case .saveHand(let number, let hand):
            guard (1...header.roundCount).contains(number) else { throw GroupGameError.invalidTransition }
            try GroupGameScoringTransition.validate(hand, participants: header.participants)
            let (roundEntry, round) = try await fetchRound(number, header: header)
            let hands = try GroupGameScoringTransition.hands(saving: hand, in: round, currentRound: header.roundCount)
            roundEntry.record["hands"] = try encode(hands)
            return ([entry, roundEntry], [])
        case .startNextRound:
            guard header.roundCount < Int.max else {
                throw GroupGameError.invalidTransition
            }
            let (_, current) = try await fetchRound(header.roundCount, header: header)
            let next = try GroupGameScoringTransition.nextRound(after: current)
            entry.record["roundCount"] = next
            return ([entry, try newRound(game: game, number: next)], [])
        case .complete:
            entry.record["completedAt"] = Date.now
            return ([entry], [])
        case .reassignScorekeeper(let key):
            guard key != header.scorekeeperKey else { throw GroupGameError.invalidTransition }
            entry.record["scorekeeperKey"] = key
            return ([entry], [])
        case .cancel:
            entry.record["cancelledAt"] = Date.now
            return ([entry], [])
        }
    }

    private func childrenForDeletion(_ header: GroupGameHeader) async throws -> [CKRecord.ID] {
        let parent = gameID(header.id)
        let children = try await store.gameChildren(of: parent)
        guard try await fetchHeader(header.id).1.version == header.version else { throw GroupGameError.staleGame }
        var rounds: Set<CKRecord.ID> = []
        var revisions: Set<Int> = []
        for child in children {
            let record = child.record
            guard record.parent?.recordID == parent, record.recordID.zoneID == parent.zoneID,
                  child.changeTag != nil else { throw GroupGameError.invalidRecord }
            switch record.recordType {
            case GroupRecordTypes.gameRound:
                guard rounds.insert(record.recordID).inserted else { throw GroupGameError.invalidRecord }
            case GroupRecordTypes.gameOperation:
                let prefix = "game-op-\(header.id.uuidString)-"
                guard record.recordID.recordName.hasPrefix(prefix),
                      UUID(uuidString: String(record.recordID.recordName.dropFirst(prefix.count))) != nil,
                      let revision = record["revision"] as? Int, (1...header.version.revision).contains(revision),
                      revisions.insert(revision).inserted else { throw GroupGameError.invalidRecord }
            default:
                throw GroupGameError.invalidRecord
            }
        }
        guard rounds.count == header.roundCount,
              (1...header.roundCount).allSatisfy({ rounds.contains(roundID(game: header.id, number: $0)) }),
              revisions.count == header.version.revision else { throw GroupGameError.invalidRecord }
        return children.map(\.record.recordID)
    }

    private func createRecords(id: UUID, playerIDs: [UUID], key: String) async throws -> [GroupStoredRecord] {
        guard playerIDs.count >= GroupGameSelection.minimumPlayers,
              Set(playerIDs).count == playerIDs.count else { throw GroupGameError.invalidPlayers }
        let available = try await loadPlayers().filter { $0.groupID == groupID && $0.retiredAt == nil }
        let participants = try playerIDs.map { playerID in
            guard let player = available.first(where: { $0.id == playerID }) else { throw GroupGameError.invalidPlayers }
            return GroupGameParticipant(playerID: playerID, displayName: player.displayName)
        }
        let header = newRecord(GroupRecordTypes.game, id: gameID(id), parent: root)
        header.record["participants"] = try encode(participants)
        header.record["creatorKey"] = key
        header.record["scorekeeperKey"] = key
        header.record["revision"] = 1
        header.record["roundCount"] = 1
        return [header, try newRound(game: id, number: 1)]
    }

    private func newRound(game: UUID, number: Int) throws -> GroupStoredRecord {
        let round = newRecord(GroupRecordTypes.gameRound, id: roundID(game: game, number: number), parent: gameID(game))
        round.record["hands"] = try encode([GroupGameHand]())
        return round
    }

    private func fetchHeader(_ game: UUID) async throws -> (GroupStoredRecord, GroupGameHeader) {
        let id = gameID(game)
        guard let entry = try await store.record(for: id) else { throw GroupGameError.gameNotFound }
        if try isDeleted(entry, game: game) { throw GroupGameError.gameDeleted }
        return (entry, try decodeHeader(entry, game: game))
    }

    private func isDeleted(_ entry: GroupStoredRecord, game: UUID) throws -> Bool {
        guard entry.record["deletedAt"] != nil else { return false }
        guard isRecord(entry, type: GroupRecordTypes.game, id: gameID(game), parent: root),
              entry.record["deletedAt"] is Date, let revision = entry.record["revision"] as? Int,
              revision > 1 else { throw GroupGameError.invalidRecord }
        return true
    }

    private func decodeHeader(_ entry: GroupStoredRecord, game: UUID) throws -> GroupGameHeader {
        let record = entry.record
        guard isRecord(entry, type: GroupRecordTypes.game, id: gameID(game), parent: root),
              let creator = record["creatorKey"] as? String, isDigest(creator),
              let scorekeeper = record["scorekeeperKey"] as? String, isDigest(scorekeeper),
              let revision = record["revision"] as? Int, revision > 0,
              let roundCount = record["roundCount"] as? Int, (1...revision).contains(roundCount),
              let tag = entry.changeTag else { throw GroupGameError.invalidRecord }
        let participants = try decode([GroupGameParticipant].self, from: record, field: "participants")
        guard participants.count >= 2, Set(participants.map(\.playerID)).count == participants.count,
              participants.allSatisfy({ !PlayerName.trimmed($0.displayName).isEmpty }) else {
            throw GroupGameError.invalidRecord
        }
        let completed = record["completedAt"] as? Date
        let cancelled = record["cancelledAt"] as? Date
        guard record["completedAt"] == nil || completed != nil,
              record["cancelledAt"] == nil || cancelled != nil,
              completed == nil || cancelled == nil else { throw GroupGameError.invalidRecord }
        return GroupGameHeader(
            id: game, groupID: groupID, participants: participants, creatorKey: creator, scorekeeperKey: scorekeeper,
            roundCount: roundCount, completedAt: completed, cancelledAt: cancelled, createdAt: record.creationDate,
            updatedAt: record.modificationDate, version: GroupGameVersion(revision: revision, changeTag: tag)
        )
    }

    private func fetchRound(_ number: Int, header: GroupGameHeader) async throws -> (GroupStoredRecord, GroupGameRound) {
        let id = roundID(game: header.id, number: number)
        guard let entry = try await store.record(for: id),
              isRecord(entry, type: GroupRecordTypes.gameRound, id: id, parent: gameID(header.id)) else {
            throw GroupGameError.invalidRecord
        }
        let hands = try decode([GroupGameHand].self, from: entry.record, field: "hands")
        for (index, hand) in hands.enumerated() {
            guard hand.number == index + 1 else { throw GroupGameError.invalidRecord }
            do { try GroupGameScoringTransition.validate(hand, participants: header.participants) }
            catch { throw GroupGameError.invalidRecord }
        }
        return (entry, GroupGameRound(id: .init(gameID: header.id, number: number), hands: hands))
    }

    private func findReceipt(
        for operation: GroupGameOperation, revision: Int, key: String, fingerprint: String
    ) async throws -> GroupGameReceipt? {
        guard let entry = try await store.record(for: receiptID(for: operation)) else { return nil }
        let receipt = try decodeReceipt(entry, operation: operation, revision: revision, key: key, fingerprint: fingerprint)
        try await verifyAccount()
        return receipt
    }

    private func decodeReceipt(
        _ entry: GroupStoredRecord, operation: GroupGameOperation, revision: Int, key: String, fingerprint: String
    ) throws -> GroupGameReceipt {
        let record = entry.record
        guard isRecord(entry, type: GroupRecordTypes.gameOperation, id: receiptID(for: operation),
                       parent: gameID(operation.gameID)),
              let actor = record["actorKey"] as? String, let savedFingerprint = record["fingerprint"] as? String,
              let savedRevision = record["revision"] as? Int else { throw GroupGameError.invalidRecord }
        guard key == actor, fingerprint == savedFingerprint, revision == savedRevision else {
            throw GroupGameError.reusedOperation
        }
        return GroupGameReceipt(operationID: operation.id, gameID: operation.gameID, revision: savedRevision)
    }

    private func newRecord(_ type: CKRecord.RecordType, id: CKRecord.ID, parent: CKRecord.ID) -> GroupStoredRecord {
        let record = CKRecord(recordType: type, recordID: id)
        record.setParent(parent)
        return GroupStoredRecord(record)
    }

    private func isRecord(_ entry: GroupStoredRecord, type: CKRecord.RecordType, id: CKRecord.ID, parent: CKRecord.ID) -> Bool {
        entry.changeTag != nil && entry.record.recordType == type && entry.record.recordID == id &&
            entry.record.parent?.recordID == parent
    }

    func gameID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "game-\(id.uuidString)", zoneID: root.zoneID)
    }

    static func gameUUID(_ id: CKRecord.ID) -> UUID? {
        let prefix = "game-"
        guard id.recordName.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(id.recordName.dropFirst(prefix.count)))
    }

    func roundID(game: UUID, number: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "game-round-\(game.uuidString)-\(number)", zoneID: root.zoneID)
    }

    func receiptID(for operation: GroupGameOperation) -> CKRecord.ID {
        receiptID(game: operation.gameID, operationID: operation.id)
    }

    func receiptID(game: UUID, operationID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "game-op-\(game.uuidString)-\(operationID.uuidString)", zoneID: root.zoneID)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: CKRecord, field: String) throws -> T {
        guard let data = record[field] as? Data, let value = try? JSONDecoder().decode(type, from: data) else {
            throw GroupGameError.invalidRecord
        }
        return value
    }

    private func isDigest(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension GroupRepository {
    func games(for group: GroupSummary, account: String) -> GroupGameStore {
        let roster = self.roster(for: group, account: account)
        return GroupGameStore(
            groupID: group.id, root: roster.root, store: cloudStore(for: group, account: account),
            authorize: roster.authorize, verifyAccount: roster.verifyAccount, loadPlayers: { try await roster.players() },
            loadOwnerAuthority: {
                let share = try await gameManagementShare(for: group, account: account)
                let keys = Self.eligibleScorekeepers(in: share).map { Self.scorekeeperKey(for: $0, group: group) }
                return GroupGameOwnerAuthority(share: GroupStoredRecord(share), eligibleKeys: Set(keys))
            }
        )
    }

    func gameHistory(for group: GroupSummary, account: String) async throws -> [GroupGameHeader] {
        let cloud = cloudStore(for: group, account: account)
        return try await games(for: group, account: account).list {
            try await cloud.gameHeaderRecords()
        }
    }

    func gameScorekeeperNames(for group: GroupSummary, account: String) async -> [String: String] {
        let viewerKey = GroupRosterAccess(role: .reader, groupID: group.id, account: account).creatorKey
        var names = [viewerKey: "You"]
        guard let liveDetails = try? await details(for: group) else { return names }
        let details = await loadMemberDisplayNames(in: liveDetails, account: account)
        for participant in [details.share.owner] + details.members {
            let isOwner = participant.role == .owner
            guard isOwner || participant.acceptanceStatus == .accepted else { continue }
            let isYou = details.isCurrentUser(participant)
            let name = isYou ? "You" : details.displayName(for: participant) ?? (isOwner ? "Group owner" : "Group member")
            names[Self.scorekeeperKey(for: participant, group: group)] = name
            guard !isYou else { continue }
            let userID = isOwner ? group.zoneOwner : participant.userIdentity.userRecordID?.recordName
            guard let userID, userID != CKCurrentUserDefaultName, userID != account else { continue }
            let key = GroupRosterAccess(role: .reader, groupID: group.id, account: userID).creatorKey
            names[key] = name
        }
        return names
    }

    func gameScorekeeperCandidates(for group: GroupSummary, account: String) async throws -> [GroupGameScorekeeperCandidate] {
        let share = try await gameManagementShare(for: group, account: account)
        let details = await loadMemberDisplayNames(
            in: GroupDetails(group: group, share: share, invitationURL: nil), account: account
        )
        return Self.eligibleScorekeepers(in: share).enumerated().map { index, participant in
            let name = details.isCurrentUser(participant)
                ? "You (Group owner)"
                : details.displayName(for: participant) ?? "Group member \(index)"
            return GroupGameScorekeeperCandidate(id: Self.scorekeeperKey(for: participant, group: group), name: name)
        }
    }

    private static func eligibleScorekeepers(in share: CKShare) -> [CKShare.Participant] {
        [share.owner] + share.participants.filter {
            $0.role != .owner && $0.acceptanceStatus == .accepted && $0.permission == .readWrite
        }
    }

    private static func scorekeeperKey(for participant: CKShare.Participant, group: GroupSummary) -> String {
        GroupRosterAccess.scorekeeperKey(groupID: group.id, participantID: participant.participantID)
    }
}

extension GroupCloudStore: GroupGameRecordStore {
    func gameChildren(of game: CKRecord.ID) async throws -> [GroupStoredRecord] {
        guard game.zoneID == zoneID, let id = GroupGameStore.gameUUID(game) else {
            throw GroupGameError.invalidRecord
        }
        var children: [CKRecord.ID: GroupStoredRecord] = [:]
        var token: CKServerChangeToken?
        while true {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: ["revision"])
            for (recordID, result) in page.modificationResultsByID {
                let knownChild = recordID.recordName.hasPrefix("game-round-\(id.uuidString)-") ||
                    recordID.recordName.hasPrefix("game-op-\(id.uuidString)-")
                if case .success(let change) = result, change.record.parent?.recordID == game {
                    guard change.record.recordID == recordID else { throw GroupGameError.invalidRecord }
                    children[recordID] = GroupStoredRecord(change.record)
                } else if knownChild {
                    _ = try result.get()
                    throw GroupGameError.invalidRecord
                }
            }
            for deletion in page.deletions { children.removeValue(forKey: deletion.recordID) }
            guard page.moreComing else { return Array(children.values) }
            token = page.changeToken
        }
    }
}

private extension GroupCloudStore {
    func gameHeaderRecords() async throws -> [GroupStoredRecord] {
        var headers: [CKRecord.ID: GroupStoredRecord] = [:]
        var token: CKServerChangeToken?
        let keys = ["participants", "creatorKey", "scorekeeperKey", "revision", "roundCount", "completedAt",
                    "cancelledAt", "deletedAt"]
        while true {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: keys)
            for (id, result) in page.modificationResultsByID {
                if case .success(let change) = result, change.record.recordType == GroupRecordTypes.game {
                    guard change.record.recordID == id else { throw GroupGameError.invalidRecord }
                    headers[id] = GroupStoredRecord(change.record)
                } else if GroupGameStore.gameUUID(id) != nil {
                    _ = try result.get()
                    throw GroupGameError.invalidRecord
                }
            }
            for deletion in page.deletions { headers.removeValue(forKey: deletion.recordID) }
            guard page.moreComing else { return Array(headers.values) }
            token = page.changeToken
        }
    }
}
#endif
