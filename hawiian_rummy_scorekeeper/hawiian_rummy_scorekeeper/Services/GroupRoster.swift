#if DEBUG
import CloudKit
import CryptoKit
import Foundation

enum GroupRosterError: LocalizedError, Equatable {
    case accessLost, notAuthorized, wrongGroup, invalidName, duplicateName
    case playerNotFound, stalePlayer, invalidRecord, reservationMismatch, reusedDraft, atomicUnavailable
    case writeInProgress

    var errorDescription: String? {
        switch self {
        case .accessLost: "You no longer have access to this group."
        case .notAuthorized: "You don’t have permission to make that roster change."
        case .wrongGroup: "This player belongs to a different group."
        case .invalidName: "Enter a name for this group player."
        case .duplicateName: "An active or retired player in this group already has that name."
        case .playerNotFound: "This group player is no longer available."
        case .stalePlayer: "The roster changed on another device. Refresh and review your change."
        case .invalidRecord: "The group roster contains a record with an unexpected format."
        case .reservationMismatch: "A group player and its name reservation are inconsistent."
        case .reusedDraft: "This add request already belongs to a different player or name. Refresh the roster."
        case .atomicUnavailable: "CloudKit does not report atomic write support for this group’s zone."
        case .writeInProgress: "A roster change is already being saved. Try again in a moment."
        }
    }
}

struct GroupRosterAccess: Equatable {
    enum Role { case owner, editor, reader }

    let role: Role
    let creatorKey: String

    init(role: Role, groupID: UUID, account: String) {
        self.role = role
        creatorKey = GroupRoster.digest("creator-v1:\(groupID.uuidString):\(account)")
    }

    var canAdd: Bool { role != .reader }

    func canRename(_ player: GroupPlayerIdentity) -> Bool {
        role == .owner || (role == .editor && creatorKey == player.creatorKey)
    }

    func requireAdd() throws {
        guard canAdd else { throw GroupRosterError.notAuthorized }
    }

    func requireRename(_ player: GroupPlayerIdentity) throws {
        guard canRename(player) else {
            throw GroupRosterError.notAuthorized
        }
    }

    func requireOwner() throws {
        guard role == .owner else { throw GroupRosterError.notAuthorized }
    }
}

struct GroupRosterContents {
    let access: GroupRosterAccess
    let players: [GroupPlayerIdentity]
}

protocol GroupRosterStore: GroupRecordStore {
    func records() async throws -> [GroupStoredRecord]
}

struct GroupRoster {
    static let playerPrefix = "player-"
    static let reservationPrefix = "player-name-"

    let groupID: UUID
    let root: CKRecord.ID
    let store: any GroupRosterStore
    let authorize: () async throws -> GroupRosterAccess
    let verifyAccount: () async throws -> Void

    func players() async throws -> [GroupPlayerIdentity] {
        try await contents().players
    }

    func contents() async throws -> GroupRosterContents {
        let access = try await authorize()
        let records = try await store.records()
        var players: [GroupPlayerIdentity] = []
        var reservations: [CKRecord.ID: UUID] = [:]
        for entry in records {
            if entry.record.recordType == GroupRecordTypes.player {
                players.append(try player(from: entry))
            } else if let owner = try reservationOwner(entry, id: entry.record.recordID) {
                reservations[entry.record.recordID] = owner
            }
        }
        for player in players {
            let key = reservationID(for: player.displayName)
            guard reservations.removeValue(forKey: key) == player.id else {
                throw GroupRosterError.reservationMismatch
            }
        }
        guard reservations.isEmpty else { throw GroupRosterError.reservationMismatch }
        try await verifyAccount()
        let sorted = players.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        return GroupRosterContents(access: access, players: sorted)
    }

    func add(_ draft: GroupPlayerDraft) async throws -> GroupPlayerIdentity {
        let access = try await authorize()
        try access.requireAdd()
        let name = try validatedName(draft.displayName)
        if let confirmed = try await findAddedPlayer(draft.id, name: name, access: access) {
            return confirmed
        }
        let key = reservationID(for: name)
        let entry: GroupStoredRecord
        do {
            entry = try await availableReservation(key, for: draft.id)
        } catch let error as GroupRosterError where [.duplicateName, .reservationMismatch].contains(error) {
            // A retry of the same draft may have committed after the player lookup.
            if let confirmed = try await findAddedPlayer(draft.id, name: name, access: access) {
                return confirmed
            }
            throw error
        }
        let player = newChild(GroupRecordTypes.player, id: playerID(draft.id))
        player.record["displayName"] = name
        player.record["creatorKey"] = access.creatorKey
        entry.record["playerID"] = draft.id.uuidString
        do {
            return try await save([player, entry], player: player.record.recordID, access: access)
        } catch let error as GroupAtomicWriteError {
            let current = try await authorize()
            try current.requireAdd()
            if let confirmed = try await findAddedPlayer(draft.id, name: name, access: current) {
                return confirmed
            }
            if let latest = try await store.record(for: key),
               let holder = try reservationOwner(latest, id: key) {
                if holder == draft.id { throw GroupRosterError.reservationMismatch }
                throw GroupRosterError.duplicateName
            }
            if case .conflict = error { throw GroupRosterError.stalePlayer }
            throw error
        }
    }

    func rename(_ original: GroupPlayerIdentity, to input: String) async throws -> GroupPlayerIdentity {
        let access = try await authorize()
        let (entry, current) = try await fetchForEdit(original)
        try access.requireRename(current)
        let name = try validatedName(input)
        let old = try await heldReservation(for: current)
        if current.displayName == name {
            try await verifyAccount()
            return current
        }
        let destination = reservationID(for: name)
        var changes = [entry]
        if old.record.recordID != destination {
            let replacement = try await availableReservation(destination, for: current.id)
            replacement.record["playerID"] = current.id.uuidString
            old.record["playerID"] = ""
            changes.append(contentsOf: [old, replacement])
        }
        entry.record["displayName"] = name
        do {
            return try await save(changes, player: entry.record.recordID, access: access)
        } catch GroupAtomicWriteError.conflict {
            _ = try await fetchForEdit(original)
            if old.record.recordID != destination {
                _ = try await availableReservation(destination, for: current.id)
            }
            throw GroupRosterError.stalePlayer
        }
    }

    func setRetired(_ retired: Bool, player original: GroupPlayerIdentity) async throws -> GroupPlayerIdentity {
        let access = try await authorize()
        try access.requireOwner()
        let (entry, current) = try await fetchForEdit(original)
        _ = try await heldReservation(for: current)
        if retired == (current.retiredAt != nil) {
            try await verifyAccount()
            return current
        }
        entry.record["retiredAt"] = retired ? Date.now : nil
        do {
            return try await save([entry], player: entry.record.recordID, access: access)
        } catch GroupAtomicWriteError.conflict {
            _ = try await fetchForEdit(original)
            throw GroupRosterError.stalePlayer
        }
    }

    // MARK: - Reads and conditional writes

    private func fetchForEdit(_ original: GroupPlayerIdentity) async throws -> (GroupStoredRecord, GroupPlayerIdentity) {
        guard original.groupID == groupID else { throw GroupRosterError.wrongGroup }
        let id = playerID(original.id)
        guard let entry = try await store.record(for: id) else { throw GroupRosterError.playerNotFound }
        let current = try player(from: entry)
        guard entry.record.recordID == id else { throw GroupRosterError.invalidRecord }
        guard current.changeTag == original.changeTag else { throw GroupRosterError.stalePlayer }
        return (entry, current)
    }

    private func findAddedPlayer(
        _ id: UUID, name: String, access: GroupRosterAccess
    ) async throws -> GroupPlayerIdentity? {
        let expected = playerID(id)
        guard let entry = try await store.record(for: expected) else { return nil }
        guard entry.record.recordID == expected else { throw GroupRosterError.invalidRecord }
        let current = try player(from: entry)
        guard current.creatorKey == access.creatorKey, current.displayName == name else {
            throw GroupRosterError.reusedDraft
        }
        _ = try await heldReservation(for: current)
        try await verifyAccount()
        return current
    }

    private func heldReservation(for player: GroupPlayerIdentity) async throws -> GroupStoredRecord {
        let key = reservationID(for: player.displayName)
        if let entry = try await store.record(for: key), try reservationOwner(entry, id: key) == player.id {
            return entry
        }
        // A different rename may have committed between the player and reservation reads.
        guard let current = try await store.record(for: playerID(player.id)) else {
            throw GroupRosterError.playerNotFound
        }
        guard current.changeTag == player.changeTag else { throw GroupRosterError.stalePlayer }
        throw GroupRosterError.reservationMismatch
    }

    private func availableReservation(_ key: CKRecord.ID, for player: UUID) async throws -> GroupStoredRecord {
        guard let entry = try await store.record(for: key) else {
            return newChild(GroupRecordTypes.playerName, id: key)
        }
        if let current = try reservationOwner(entry, id: key) {
            guard current != player else { throw GroupRosterError.reservationMismatch }
            throw GroupRosterError.duplicateName
        }
        return entry
    }

    private func save(
        _ batch: [GroupStoredRecord], player id: CKRecord.ID, access initial: GroupRosterAccess
    ) async throws -> GroupPlayerIdentity {
        guard try await authorize() == initial else { throw GroupRosterError.notAuthorized }
        try Task.checkCancellation()
        let saved = try await store.saveAtomically(batch)
        try await verifyAccount()
        guard let entry = saved[id], entry.record.recordID == id else {
            throw GroupAtomicWriteError.unconfirmed(GroupRosterError.invalidRecord)
        }
        return try player(from: entry)
    }

    // MARK: - Record mapping

    func playerID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.playerPrefix + id.uuidString, zoneID: root.zoneID)
    }

    func reservationID(for name: String) -> CKRecord.ID {
        let key = PlayerName.comparisonKey(name).precomposedStringWithCanonicalMapping
        return CKRecord.ID(recordName: Self.reservationPrefix + Self.digest(key), zoneID: root.zoneID)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validatedName(_ input: String) throws -> String {
        let name = PlayerName.trimmed(input)
        guard !name.isEmpty else { throw GroupRosterError.invalidName }
        return name
    }

    func newChild(_ type: String, id: CKRecord.ID) -> GroupStoredRecord {
        let record = CKRecord(recordType: type, recordID: id)
        record.setParent(root)
        return GroupStoredRecord(record)
    }

    private func isChild(_ record: CKRecord, type: String) -> Bool {
        record.recordType == type && record.recordID.zoneID == root.zoneID && record.parent?.recordID == root
    }

    func player(from entry: GroupStoredRecord) throws -> GroupPlayerIdentity {
        let record = entry.record
        guard isChild(record, type: GroupRecordTypes.player),
              let id = UUID(uuidString: String(record.recordID.recordName.dropFirst(Self.playerPrefix.count))),
              record.recordID == playerID(id),
              let name = record["displayName"] as? String, !name.isEmpty, name == PlayerName.trimmed(name),
              let creator = record["creatorKey"] as? String, Self.isDigest(creator),
              let changeTag = entry.changeTag else { throw GroupRosterError.invalidRecord }
        let retirement = record["retiredAt"] as? Date
        guard record["retiredAt"] == nil || retirement != nil else { throw GroupRosterError.invalidRecord }
        return GroupPlayerIdentity(
            id: id, groupID: groupID, creatorKey: creator, displayName: name, retiredAt: retirement, changeTag: changeTag
        )
    }

    func reservationOwner(_ entry: GroupStoredRecord, id: CKRecord.ID) throws -> UUID? {
        let record = entry.record
        let name = id.recordName
        guard isChild(record, type: GroupRecordTypes.playerName), record.recordID == id, entry.changeTag != nil,
              name.hasPrefix(Self.reservationPrefix),
              Self.isDigest(String(name.dropFirst(Self.reservationPrefix.count))),
              let value = record["playerID"] as? String else { throw GroupRosterError.invalidRecord }
        if value.isEmpty { return nil }
        guard let owner = UUID(uuidString: value) else { throw GroupRosterError.invalidRecord }
        return owner
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
#endif
