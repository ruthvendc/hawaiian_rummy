#if DEBUG
import CloudKit
import Foundation

enum GroupGameError: LocalizedError, Equatable {
    case wrongGroup, notScorekeeper, gameNotFound, invalidRecord, invalidPlayers
    case invalidScores, invalidTransition, staleGame, reusedOperation

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
        }
    }
}

struct GroupGameStore {
    let groupID: UUID
    let root: CKRecord.ID
    let store: any GroupRecordStore
    let authorize: () async throws -> GroupRosterAccess
    let verifyAccount: () async throws -> Void
    let loadPlayers: () async throws -> [GroupPlayerIdentity]

    func list(fetchHeaders: () async throws -> [GroupStoredRecord]) async throws -> [GroupGameHeader] {
        _ = try await authorize()
        let headers = try await fetchHeaders().map { entry in
            guard let id = Self.gameUUID(entry.record.recordID) else { throw GroupGameError.invalidRecord }
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
        _ = try await authorize()
        let (_, header) = try await fetchHeader(gameID)
        var rounds: [GroupGameRound] = []
        for number in 1...header.roundCount {
            let (_, round) = try await fetchRound(number, header: header)
            guard number == header.roundCount || round.hands.count == LevelDefinition.all.count else {
                throw GroupGameError.invalidRecord
            }
            rounds.append(round)
        }
        let (_, current) = try await fetchHeader(gameID)
        guard current.version == header.version else { throw GroupGameError.staleGame }
        try await verifyAccount()
        return GroupGameSnapshot(header: header, rounds: rounds)
    }

    func perform(_ operation: GroupGameOperation) async throws -> GroupGameReceipt {
        guard operation.groupID == groupID else { throw GroupGameError.wrongGroup }
        let access = try await authorize()
        try access.requireAdd()
        let revision = try resultRevision(for: operation)
        let fingerprint = GroupRoster.digest("game-operation-v1:" + String(decoding: try encode(operation), as: UTF8.self))
        if let receipt = try await findReceipt(for: operation, revision: revision, key: access.creatorKey, fingerprint: fingerprint) {
            return receipt
        }

        let receiptID = receiptID(for: operation)
        do {
            var changes = try await changes(for: operation, revision: revision, access: access)
            let acknowledgment = newRecord(GroupRecordTypes.gameOperation, id: receiptID, parent: gameID(operation.gameID))
            acknowledgment.record["actorKey"] = access.creatorKey
            acknowledgment.record["fingerprint"] = fingerprint
            acknowledgment.record["revision"] = revision
            changes.append(acknowledgment)

            guard try await authorize() == access else { throw GroupRosterError.notAuthorized }
            try Task.checkCancellation()
            let saved = try await store.saveAtomically(changes)
            try await verifyAccount()
            guard let stored = saved[receiptID] else {
                throw GroupAtomicWriteError.unconfirmed(GroupGameError.invalidRecord)
            }
            return try decodeReceipt(stored, operation: operation, revision: revision,
                                     key: access.creatorKey, fingerprint: fingerprint)
        } catch let error where error is GroupAtomicWriteError || (error as? GroupGameError) == .staleGame {
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
    ) async throws -> [GroupStoredRecord] {
        let game = operation.gameID
        if case .create(let playerIDs) = operation.action {
            return try await createRecords(id: game, playerIDs: playerIDs, key: access.creatorKey)
        }
        let (entry, header) = try await fetchHeader(game)
        guard header.scorekeeperKey == access.creatorKey else { throw GroupGameError.notScorekeeper }
        guard header.version == operation.expectedVersion else { throw GroupGameError.staleGame }
        entry.record["revision"] = revision

        switch operation.action {
        case .create:
            throw GroupGameError.invalidTransition
        case .saveHand(let number, let hand):
            guard (1...header.roundCount).contains(number) else { throw GroupGameError.invalidTransition }
            try validate(hand, participants: header.participants)
            let (roundEntry, round) = try await fetchRound(number, header: header)
            var hands = round.hands
            if hand.number <= hands.count {
                hands[hand.number - 1] = hand
            } else {
                guard header.completedAt == nil, number == header.roundCount, hand.number == hands.count + 1 else {
                    throw GroupGameError.invalidTransition
                }
                hands.append(hand)
            }
            roundEntry.record["hands"] = try encode(hands)
            return [entry, roundEntry]
        case .startNextRound:
            guard header.completedAt == nil, header.roundCount < Int.max else {
                throw GroupGameError.invalidTransition
            }
            let (_, current) = try await fetchRound(header.roundCount, header: header)
            guard current.hands.count == LevelDefinition.all.count else { throw GroupGameError.invalidTransition }
            let next = header.roundCount + 1
            entry.record["roundCount"] = next
            return [entry, try newRound(game: game, number: next)]
        case .complete:
            guard header.completedAt == nil else { throw GroupGameError.invalidTransition }
            entry.record["completedAt"] = Date.now
            return [entry]
        }
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
        return (entry, try decodeHeader(entry, game: game))
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
        guard record["completedAt"] == nil || completed != nil else { throw GroupGameError.invalidRecord }
        return GroupGameHeader(
            id: game, groupID: groupID, participants: participants, creatorKey: creator, scorekeeperKey: scorekeeper,
            roundCount: roundCount, completedAt: completed, createdAt: record.creationDate,
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
            do { try validate(hand, participants: header.participants) }
            catch { throw GroupGameError.invalidRecord }
        }
        return (entry, GroupGameRound(id: .init(gameID: header.id, number: number), hands: hands))
    }

    private func validate(_ hand: GroupGameHand, participants: [GroupGameParticipant]) throws {
        guard (1...LevelDefinition.all.count).contains(hand.number), hand.scores.count == participants.count,
              Set(hand.scores.map(\.playerID)) == Set(participants.map(\.playerID)),
              hand.scores.allSatisfy({ $0.points >= 0 }) else { throw GroupGameError.invalidScores }
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
            authorize: roster.authorize, verifyAccount: roster.verifyAccount, loadPlayers: { try await roster.players() }
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
        for participant in [details.share.owner] + details.members where !details.isCurrentUser(participant) {
            let isOwner = participant.role == .owner
            guard isOwner || participant.acceptanceStatus == .accepted else { continue }
            let userID = isOwner ? group.zoneOwner : participant.userIdentity.userRecordID?.recordName
            guard let userID, userID != CKCurrentUserDefaultName, userID != account else { continue }
            let key = GroupRosterAccess(role: .reader, groupID: group.id, account: userID).creatorKey
            names[key] = details.displayName(for: participant) ?? (isOwner ? "Group owner" : "Group member")
        }
        return names
    }
}

private extension GroupCloudStore {
    func gameHeaderRecords() async throws -> [GroupStoredRecord] {
        var headers: [CKRecord.ID: GroupStoredRecord] = [:]
        var token: CKServerChangeToken?
        let keys = ["participants", "creatorKey", "scorekeeperKey", "revision", "roundCount", "completedAt"]
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
