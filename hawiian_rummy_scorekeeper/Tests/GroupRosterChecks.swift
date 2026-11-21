import CloudKit
import Foundation

@main
struct GroupRosterChecks {
    static func main() async throws {
        try await namesAndPermissions()
        try await atomicConflicts()
        try await ambiguousSaveAndAccessChange()
        try await recordMapping()
        print("Group roster checks passed (simulated CloudKit transport).")
    }

    private static func namesAndPermissions() async throws {
        let group = Fixture()
        let owner = group.roster(.owner, account: "owner")
        let editor = group.roster(.editor, account: "member")
        let reader = group.roster(.reader, account: "reader")
        let otherEditor = group.roster(.editor, account: "other")
        let otherGroup = Fixture().roster(.owner, account: "owner")
        try check(PlayerName.comparisonKey("  jOhN\n") == PlayerName.comparisonKey("John"), "Trim and fold case")
        try check(owner.reservationID(for: " ÉLise ") == owner.reservationID(for: "e\u{301}lise"),
                  "Canonical Unicode variants select the same reservation ID")
        try check(owner.reservationID(for: "John") != otherGroup.reservationID(for: "John"),
                  "Reservations are scoped to their group zones")
        try await expect(.invalidName, "Reject empty names") { _ = try await owner.add(draft(" \n ")) }

        let original = try await editor.add(draft("  John  "))
        try check(original.displayName == "John" && original.creatorKey != "member", "Store the trimmed name and opaque key")
        let ownerPlayer = try await owner.add(draft("Another"))
        let otherPlayer = try await otherGroup.add(draft("john"))
        try check(otherPlayer.groupID != original.groupID, "Unrelated groups can use the same name")
        try check(try await reader.players().count == 2, "Read-only accepted members can view")
        try await expect(.notAuthorized, "Read-only members cannot add") { _ = try await reader.add(draft("Read only")) }
        try await expect(.duplicateName, "Reject an equivalent name in the same group") {
            _ = try await owner.add(draft("JOHN\n"))
        }
        try await expect(.notAuthorized, "Another member cannot rename the creator’s player") {
            _ = try await otherEditor.rename(original, to: "Johnny")
        }
        try await expect(.notAuthorized, "Creator cannot retire") { _ = try await editor.setRetired(true, player: original) }
        try await expect(.wrongGroup, "Cannot edit a player from another group") {
            _ = try await otherGroup.rename(original, to: "Other")
        }

        let caseOnly = try await editor.rename(original, to: "JOHN")
        try check(caseOnly.id == original.id && caseOnly.creatorKey == original.creatorKey, "Case-only rename keeps identity")
        try check(group.store.lastBatch == [owner.playerID(original.id)], "Leave the reservation unchanged on a case-only rename")
        let retired = try await owner.setRetired(true, player: caseOnly)
        try check(retired.id == original.id && retired.retiredAt != nil && group.store.lastBatch.count == 1,
                  "Retirement preserves stable ID and reservation")
        try await expect(.duplicateName, "Retired name stays reserved") { _ = try await editor.add(draft("john")) }
        try await expect(.notAuthorized, "Creator cannot restore") { _ = try await editor.setRetired(false, player: retired) }
        let restored = try await owner.setRetired(false, player: retired)
        try check(restored.retiredAt == nil && restored.id == original.id, "Restore the same player")
        let ownerRename = try await owner.rename(restored, to: "Johnny")
        try await expect(.duplicateName, "Reject rename to another reserved name") {
            _ = try await editor.rename(ownerRename, to: ownerPlayer.displayName)
        }

        let sameAccountAfterRejoin = group.roster(.editor, account: "member")
        let rejoined = try await sameAccountAfterRejoin.rename(ownerRename, to: "John")
        try check(rejoined.id == original.id && rejoined.creatorKey == original.creatorKey, "Same account can rename after rejoin")
        let recycled = try await otherEditor.add(draft("Johnny"))
        try check(recycled.id != original.id, "Released name can belong to a different player")
        try check(try await editor.players().count == 3, "Released and reused reservations audit successfully")
    }

    private static func atomicConflicts() async throws {
        let group = Fixture()
        let owner = group.roster(.owner, account: "owner")
        let editor = group.roster(.editor, account: "member")
        let losing = draft("Case Race")
        let winning = draft("  case race  ")
        group.store.beforeSave = { _ = try await editor.add(winning) }
        try await expect(.duplicateName, "Conditional creation loses to competing claim") {
            _ = try await owner.add(losing)
        }
        try check(group.store.rows[owner.playerID(losing.id)] == nil, "Losing atomic add leaves no orphan player")
        try check(try await owner.players().map(\.id) == [winning.id], "Winner keeps its reservation")

        let first = try await owner.add(draft("Original"))
        let reused = draft("Original")
        let rejected = "Stale Destination"
        group.store.beforeSave = {
            _ = try await owner.rename(first, to: "Edited Elsewhere")
            _ = try await editor.add(reused)
        }
        try await expect(.stalePlayer, "Stale rename cannot release a reservation that was reassigned") {
            _ = try await owner.rename(first, to: rejected)
        }
        try check(group.store.rows[owner.reservationID(for: rejected)] == nil, "Failed rename leaves no new reservation")
        let rows = try await owner.players()
        try check(rows.contains { $0.id == first.id && $0.displayName == "Edited Elsewhere" } &&
                  rows.contains { $0.id == reused.id && $0.displayName == "Original" }, "Both valid reservations remain intact")

        let contested = draft("Contested Destination")
        guard let current = rows.first(where: { $0.id == first.id }) else { throw Failure("Missing original player") }
        group.store.beforeSave = { _ = try await editor.add(contested) }
        try await expect(.duplicateName, "Rename detects a reservation acquired after preflight") {
            _ = try await owner.rename(current, to: contested.displayName)
        }
        try check(try await owner.players().contains(current), "Conflicting rename keeps the original player and name")

        group.store.atomic = false
        try await expect(.atomicUnavailable, "Reject writes to a zone without atomic support") {
            _ = try await owner.add(draft("No atomic support"))
        }
    }

    private static func ambiguousSaveAndAccessChange() async throws {
        let group = Fixture()
        let editor = group.roster(.editor, account: "member")
        let original = draft("Retry Same Request")
        group.store.loseResponse = true
        let recovered = try await editor.add(original)
        let replayed = try await editor.add(original)
        try check(recovered == replayed && recovered.id == original.id && group.store.successfulWrites == 1,
                  "A lost response and retry recover one committed pair")
        try await expect(.reusedDraft, "An add retry cannot claim another name under the same ID") {
            _ = try await editor.add(GroupPlayerDraft(id: original.id, displayName: "Another name"))
        }
        let missing = GroupPlayerIdentity(
            id: UUID(), groupID: group.id, creatorKey: recovered.creatorKey, displayName: "Missing",
            retiredAt: nil, changeTag: recovered.changeTag
        )
        try await expect(.playerNotFound, "Missing child remains a player error") {
            _ = try await editor.rename(missing, to: "Unused")
        }

        var checks = 0
        let revoked = group.roster(authorize: {
            checks += 1
            guard checks == 1 else { throw GroupRosterError.accessLost }
            return GroupRosterAccess(role: .editor, groupID: group.id, account: "member")
        })
        try await expect(.accessLost, "Revocation between preparation and save stops the write") {
            _ = try await revoked.add(draft("Reject Revoked"))
        }
        try await expect(.accessLost, "Revoked member cannot view") { _ = try await revoked.players() }
        try check(group.store.successfulWrites == 1, "Revoked operations reached no saves")

        let changedAccount = group.roster(
            authorize: { GroupRosterAccess(role: .editor, groupID: group.id, account: "member") },
            verifyAccount: { throw AccountChanged() }
        )
        do {
            _ = try await changedAccount.add(original)
            throw Failure("A changed account received an old account’s result")
        } catch is AccountChanged {}
    }

    private static func recordMapping() async throws {
        let group = Fixture()
        let owner = group.roster(.owner, account: "owner")
        let player = try await owner.add(draft("Fixture"))
        let playerID = owner.playerID(player.id)
        guard let stored = try await group.store.record(for: playerID) else { throw Failure("Missing stored player") }
        try check(try owner.player(from: stored) == player, "Player record round-trips with its change tag")
        let wrongZone = CKRecordZone.ID(zoneName: owner.root.zoneID.zoneName, ownerName: "different-owner")
        stored.record.setParent(CKRecord.ID(recordName: owner.root.recordName, zoneID: wrongZone))
        try await expect(.invalidRecord, "Reject a parent from an unrelated zone") { _ = try owner.player(from: stored) }

        let key = owner.reservationID(for: player.displayName)
        guard let reservation = try await group.store.record(for: key) else { throw Failure("Missing reservation") }
        try check(try owner.reservationOwner(reservation, id: key) == player.id, "Reservation maps to the stable player UUID")
        reservation.record["playerID"] = UUID().uuidString
        group.store.rows[key] = reservation
        try await expect(.reservationMismatch, "Roster flags a reservation assigned to the wrong identity") {
            _ = try await owner.players()
        }
        try await expect(.reservationMismatch, "Never release a different player’s reservation") {
            _ = try await owner.rename(player, to: "Another name")
        }
        let conflict = GroupRosterCloudStore.writeFailure([CKError(.batchRequestFailed), CKError(.serverRecordChanged)])
        guard case GroupRosterWriteError.conflict = conflict else { throw Failure("Batch conflict was misclassified") }
        let ambiguous = GroupRosterCloudStore.writeFailure([CKError(.networkFailure)])
        guard case GroupRosterWriteError.unconfirmed = ambiguous else { throw Failure("Lost response was misclassified") }
    }

    private static func draft(_ name: String) -> GroupPlayerDraft { GroupPlayerDraft(id: UUID(), displayName: name) }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private static func expect(
        _ issue: GroupRosterError, _ message: String, operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw Failure(message)
        } catch let actual as GroupRosterError {
            try check(actual == issue, "\(message): received \(actual), expected \(issue)")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private struct AccountChanged: Error {}

    private struct Fixture {
        let id = UUID()
        let store = MemoryStore()

        func roster(_ role: GroupRosterAccess.Role, account: String) -> GroupRoster {
            roster(authorize: { GroupRosterAccess(role: role, groupID: id, account: account) })
        }

        func roster(
            authorize: @escaping () async throws -> GroupRosterAccess,
            verifyAccount: @escaping () async throws -> Void = {}
        ) -> GroupRoster {
            let zone = CKRecordZone.ID(zoneName: "RummyGroup-\(id.uuidString)", ownerName: "owner")
            return GroupRoster(groupID: id, root: CKRecord.ID(recordName: "group", zoneID: zone), store: store,
                               authorize: authorize, verifyAccount: verifyAccount)
        }
    }

    private final class MemoryStore: GroupRosterStore {
        var rows: [CKRecord.ID: GroupRosterRecord] = [:]
        var beforeSave: (() async throws -> Void)?
        var loseResponse = false
        var atomic = true
        private(set) var successfulWrites = 0
        private(set) var lastBatch: [CKRecord.ID] = []

        func record(for id: CKRecord.ID) async throws -> GroupRosterRecord? {
            try rows[id].map { try copy($0, tag: $0.changeTag) }
        }

        func records() async throws -> [GroupRosterRecord] {
            try rows.values.map { try copy($0, tag: $0.changeTag) }
        }

        func saveAtomically(_ records: [GroupRosterRecord]) async throws -> [CKRecord.ID: GroupRosterRecord] {
            guard atomic else { throw GroupRosterError.atomicUnavailable }
            let interleave = beforeSave
            beforeSave = nil
            try await interleave?()
            guard records.allSatisfy({ rows[$0.record.recordID]?.changeTag == $0.changeTag }) else {
                throw GroupRosterWriteError.conflict
            }
            successfulWrites += 1
            lastBatch = records.map { $0.record.recordID }
            var result: [CKRecord.ID: GroupRosterRecord] = [:]
            for entry in records {
                let key = entry.record.recordID
                let stored = try copy(entry, tag: String(successfulWrites))
                rows[key] = stored
                result[key] = try copy(stored, tag: stored.changeTag)
            }
            if loseResponse {
                loseResponse = false
                throw GroupRosterWriteError.unconfirmed(CKError(.networkFailure))
            }
            return result
        }

        private func copy(_ entry: GroupRosterRecord, tag: String?) throws -> GroupRosterRecord {
            guard let record = entry.record.copy() as? CKRecord else { throw Failure("Couldn’t copy test record") }
            return GroupRosterRecord(record, changeTag: tag)
        }
    }
}
