import CloudKit
import Foundation

@main
struct GroupGameChecks {
    static func main() async throws {
        try await identityAndLifecycle()
        try await staleAndFailedWrites()
        try await lostAcknowledgmentsAndAccess()
        try await retryVerificationPreflight()
        try await historyAndSelection()
        print("Group game checks passed (simulated CloudKit transport).")
    }

    private static func identityAndLifecycle() async throws {
        let fixture = Fixture()
        let owner = fixture.games(.owner, account: "owner")
        let member = fixture.games(.editor, account: "member")
        let reader = fixture.games(.reader, account: "reader")
        let create = fixture.creation()
        try await expect(GroupRosterError.notAuthorized, "Read-only members cannot create") {
            _ = try await reader.perform(create)
        }
        let first = try await member.perform(create)
        let original = try await owner.load(create.gameID)
        try check(first.revision == 1 && original.header.id == create.gameID &&
                  original.header.participants.map(\.playerID) == fixture.playerIDs, "Creation preserves IDs and participant order")
        let key = GroupRosterAccess(role: .editor, groupID: fixture.id, account: "member").creatorKey
        try check(original.header.creatorKey == key && original.header.scorekeeperKey == key, "Creator is the initial scorekeeper")
        try check(original.rounds.map(\.id) == [.init(gameID: create.gameID, number: 1)] &&
                  original.rounds.first?.hands == [], "Initial round is attached and empty")
        try check(try await reader.load(create.gameID) == original, "Approved read-only access can see the same game")

        try await expect(GroupGameError.notScorekeeper, "Group owner cannot change another scorekeeper’s game") {
            _ = try await owner.perform(change(original, .complete))
        }
        try await expect(GroupGameError.wrongGroup, "A different group cannot write an operation") {
            _ = try await Fixture().games(.owner, account: "owner").perform(create)
        }
        let firstPlayer = fixture.players[0]
        fixture.players[0] = GroupPlayerIdentity(
            id: firstPlayer.id, groupID: fixture.id, creatorKey: firstPlayer.creatorKey,
            displayName: "Renamed", retiredAt: .now, changeTag: "new"
        )
        try await expect(GroupGameError.invalidPlayers, "New games reject retired participants") {
            _ = try await owner.perform(fixture.creation())
        }
        try check(try await member.load(create.gameID) == original, "Existing game keeps frozen names and participants")
        try await expect(GroupGameError.invalidTransition, "An incomplete round cannot be skipped") {
            _ = try await member.perform(change(original, .startNextRound))
        }
        try await expect(GroupGameError.invalidScores, "Reject incomplete or invalid scores") {
            let invalid = GroupGameHand(number: 1, scores: [firstPlayer.id: -1])
            _ = try await member.perform(change(original, .saveHand(round: 1, hand: invalid)))
        }
        var snapshot = original
        for level in LevelDefinition.all {
            let hand = scored(level.number, points: 3, snapshot)
            _ = try await member.perform(change(snapshot, .saveHand(round: 1, hand: hand)))
            snapshot = try await member.load(create.gameID)
        }
        _ = try await member.perform(change(snapshot, .startNextRound))
        let next = try await owner.load(create.gameID)
        try check(next.rounds.map(\.id) == [.init(gameID: create.gameID, number: 1), .init(gameID: create.gameID, number: 2)] &&
                  next.rounds.first?.hands.count == LevelDefinition.all.count && next.rounds.last?.hands == [],
                  "Starting another round preserves prior scores and attaches exactly one new round")
        try check(next.header.participants == original.header.participants, "Retired participants can continue their existing game")
    }

    private static func staleAndFailedWrites() async throws {
        let fixture = Fixture()
        let games = fixture.games(.owner, account: "owner")
        let create = fixture.creation()
        let transport = fixture.transport
        transport.beforeSave = { throw CKError(.permissionFailure) }
        do {
            _ = try await games.perform(create)
            throw Failure("Expected atomic create to fail")
        } catch let error as CKError where error.code == .permissionFailure {
            try check(transport.records.isEmpty, "Failed create leaves no header, round or receipt")
        }
        _ = try await games.perform(create)
        let initial = try await games.load(create.gameID)
        let lose = change(initial, .saveHand(round: 1, hand: scored(1, points: 9, initial)))
        let win = change(initial, .complete)
        transport.beforeSave = { _ = try await games.perform(win) }
        try await expect(GroupGameError.staleGame, "The header change tag rejects an already prepared stale batch") {
            _ = try await games.perform(lose)
        }
        let actual = try await games.load(create.gameID)
        try check(actual.header.completedAt != nil && actual.rounds == initial.rounds &&
                  transport.records[games.receiptID(for: lose)] == nil,
                  "Atomic rejection leaves the valid round and receipt writes unapplied")
        try await expect(GroupGameError.staleGame, "Replaying a rejected mutation cannot supersede a newer version") {
            _ = try await games.perform(lose)
        }
        try await expect(GroupGameError.invalidTransition, "Completion prevents new hands") {
            _ = try await games.perform(change(actual, .saveHand(round: 1, hand: scored(1, points: 2, actual))))
        }
        let roundID = games.roundID(game: create.gameID, number: 1)
        if let entry = transport.records[roundID] {
            entry.record.setParent(games.gameID(UUID()))
        }
        try await expect(GroupGameError.invalidRecord, "Reject a round associated with another game") {
            _ = try await games.load(create.gameID)
        }
    }

    private static func lostAcknowledgmentsAndAccess() async throws {
        let fixture = Fixture()
        let member = fixture.games(.editor, account: "member")
        let transport = fixture.transport
        let create = fixture.creation()
        transport.afterSave = { throw GroupAtomicWriteError.unconfirmed(CKError(.networkFailure)) }
        let created = try await member.perform(create)
        try check(created == (try await member.perform(create)) && transport.commits == 1,
                  "Lost create response recovers one game and round")
        try await expect(GroupGameError.reusedOperation, "Changing the creation payload cannot reuse the operation ID") {
            _ = try await member.perform(.create(
                groupID: fixture.id, gameID: create.gameID, playerIDs: Array(fixture.playerIDs.reversed())
            ))
        }
        let before = try await member.load(create.gameID)
        let original = change(before, .saveHand(round: 1, hand: scored(1, points: 7, before)))
        let newer = scored(1, points: 21, before)
        transport.afterSave = {
            let committed = try await member.load(create.gameID)
            _ = try await member.perform(change(committed, .saveHand(round: 1, hand: newer)))
            throw GroupAtomicWriteError.unconfirmed(CKError(.networkFailure))
        }
        let recovered = try await member.perform(original)
        let retry = try await member.perform(original)
        let latest = try await member.load(create.gameID)
        try check(recovered == retry && recovered.revision == 2 && latest.header.version.revision == 3 &&
                  latest.rounds.first?.hands == [newer] && transport.commits == 3,
                  "A delayed acknowledgment returns the earlier receipt and keeps the newer score untouched")
        let completed = try await member.perform(change(latest, .complete))
        let final = try await member.load(create.gameID)
        let corrected = scored(1, points: 23, final)
        _ = try await member.perform(change(final, .saveHand(round: 1, hand: corrected)))
        let reviewed = try await member.load(create.gameID)
        try check(reviewed.header.completedAt == final.header.completedAt &&
                  reviewed.header.version.revision == completed.revision + 1 && reviewed.rounds.first?.hands == [corrected],
                  "A scorekeeper can correct a recorded hand without reopening the game")

        var verifications = 0
        let revoked = fixture.games(authorize: {
            verifications += 1
            guard verifications == 1 else { throw GroupRosterError.accessLost }
            return GroupRosterAccess(role: .editor, groupID: fixture.id, account: "member")
        })
        let pending = change(reviewed, .saveHand(round: 1, hand: newer))
        try await expect(GroupRosterError.accessLost, "Revocation between preparation and save stops the request") {
            _ = try await revoked.perform(pending)
        }
        try check(transport.commits == 5 && transport.records[member.receiptID(for: pending)] == nil,
                  "A revoked operation reaches no write")
        try await expect(GroupRosterError.accessLost, "Cached history cannot authorize replay of a receipt") {
            _ = try await revoked.perform(original)
        }
        let switched = fixture.games(
            authorize: { GroupRosterAccess(role: .editor, groupID: fixture.id, account: "member") },
            verifyAccount: { throw GroupRepositoryError.accountChanged }
        )
        try await expect(GroupRepositoryError.accountChanged, "Old-account receipt cannot be returned after an account change") {
            _ = try await switched.perform(original)
        }
    }

    private static func retryVerificationPreflight() async throws {
        let fixture = Fixture()
        guard let memberGame = UUID(uuidString: "3B010000-0000-4000-8000-000000000002") else {
            throw Failure("Invalid verification game UUID")
        }
        let member = fixture.games(.editor, account: "member")
        let owner = fixture.games(.owner, account: "owner")
        let ownerGame = fixture.creation()
        _ = try await owner.perform(ownerGame)
        _ = try await member.perform(.create(groupID: fixture.id, gameID: memberGame, playerIDs: fixture.playerIDs))
        let initial = try await member.load(memberGame)
        _ = try await member.perform(change(initial, .saveHand(round: 1, hand: scored(1, points: 3, initial))))

        let beforeRollback = fixture.transport.commits
        let early = try await GroupGameVerification.run("retry-status", games: member, isOwner: false)
        try check(early.hasPrefix("BLOCKED") && early.contains("revision 2") && fixture.transport.commits == beforeRollback,
                  "Wrong revision is reported without a write")
        _ = try await GroupGameVerification.run("rollback", games: member, isOwner: false)
        let reopened = fixture.games(.editor, account: "member")
        let afterRollback = fixture.transport.commits
        let ready = try await GroupGameVerification.run("retry-status", games: reopened, isOwner: false)
        try check(ready.hasPrefix("READY") && ready.contains("verified/missing/missing/missing") &&
                  fixture.transport.commits == afterRollback,
                  "A new store instance recognizes the persisted rollback without a write")
        let differentMember = fixture.games(.editor, account: "other")
        let wrongActor = try await GroupGameVerification.run("retry-status", games: differentMember, isOwner: false)
        try check(wrongActor.hasPrefix("BLOCKED") && wrongActor.contains("Scorekeeper matches: no"),
                  "An approved member cannot resume another scorekeeper’s probe")

        _ = try await GroupGameVerification.run("retry", games: reopened, isOwner: false)
        let afterRetry = fixture.transport.commits
        let advanced = try await GroupGameVerification.run("retry-status", games: reopened, isOwner: false)
        try check(advanced.hasPrefix("BLOCKED") && advanced.contains("revision 5") &&
                  advanced.contains("verified/missing/verified/verified") && afterRetry == afterRollback + 2,
                  "The read-only status reports both retry receipts once Test 6 has written")
        do {
            _ = try await GroupGameVerification.run("retry", games: reopened, isOwner: false)
            throw Failure("A second retry run should have been blocked")
        } catch {
            try check(error.localizedDescription.contains("BLOCKED for retry") && fixture.transport.commits == afterRetry,
                      "An advanced game rejects a repeated retry probe before writing")
        }
    }

    private static func historyAndSelection() async throws {
        let fixture = Fixture()
        let owner = fixture.games(.owner, account: "owner")
        let member = fixture.games(.editor, account: "member")
        let ownerGame = fixture.creation()
        _ = try await owner.perform(ownerGame)

        var selection = GroupGameSelection()
        let first = fixture.playerIDs[0]
        let second = fixture.playerIDs[1]
        selection.select(second, isSelected: true)
        try check(!selection.canStart, "A group game needs at least two distinct players")
        selection.select(second, isSelected: true)
        selection.select(first, isSelected: true)
        try check(selection.canStart && selection.playerIDs == [second, first], "Selection follows tap order without duplicates")
        selection.select(second, isSelected: false)
        selection.select(second, isSelected: true)
        try check(selection.playerIDs == [first, second], "Reselecting moves the player to the end")
        selection.retainActivePlayers([fixture.players[0]])
        try check(selection.playerIDs == [second] && !selection.canStart, "Refreshing removes unavailable players")
        selection.select(first, isSelected: true)
        let memberGame = GroupGameOperation.create(
            groupID: fixture.id, gameID: UUID(), playerIDs: selection.playerIDs
        )
        _ = try await member.perform(memberGame)

        let headers = fixture.transport.records.values.filter { GroupGameStore.gameUUID($0.record.recordID) != nil }
        try check(headers.count == 2, "Game IDs exclude round and operation records")
        let listed = try await member.list { Array(headers) }
        let ownerListed = try await owner.list { Array(headers) }
        try check(listed == ownerListed && Set(listed.map(\.id)) == Set([ownerGame.gameID, memberGame.gameID]),
                  "Owner and member history both include games created by other members")
        try check(listed.first { $0.id == memberGame.gameID }?.participants.map(\.playerID) == [second, first],
                  "History preserves the selected seating order")
        let inaccessible = fixture.games(authorize: { throw GroupRosterError.accessLost })
        try await expect(GroupRosterError.accessLost, "Revoked membership cannot load game history") {
            _ = try await inaccessible.list { throw Failure("A denied request reached the fetch") }
        }
        let otherGroup = Fixture().games(.owner, account: "owner")
        try await expect(GroupGameError.invalidRecord, "History rejects headers from another group zone") {
            _ = try await otherGroup.list { Array(headers) }
        }
    }

    private static func change(_ snapshot: GroupGameSnapshot, _ action: GroupGameOperation.Action) -> GroupGameOperation {
        let header = snapshot.header
        return GroupGameOperation(id: UUID(), groupID: header.groupID, gameID: header.id,
                                  expectedVersion: header.version, action: action)
    }

    private static func scored(_ number: Int, points: Int, _ snapshot: GroupGameSnapshot) -> GroupGameHand {
        let scores = Dictionary(uniqueKeysWithValues: snapshot.header.participants.map { ($0.playerID, points) })
        return GroupGameHand(number: number, scores: scores)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private static func expect<Issue: Error & Equatable>(
        _ issue: Issue, _ message: String, operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw Failure(message)
        } catch let actual as Issue {
            try check(actual == issue, "\(message): received \(actual), expected \(issue)")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private final class Fixture {
        let id = UUID()
        let playerIDs = [UUID(), UUID()]
        let transport = MemoryStore()
        var players: [GroupPlayerIdentity] = []

        init() {
            let key = GroupRosterAccess(role: .owner, groupID: id, account: "owner").creatorKey
            players = playerIDs.enumerated().reversed().map {
                GroupPlayerIdentity(id: $0.element, groupID: id, creatorKey: key,
                                    displayName: "Player \($0.offset)", retiredAt: nil, changeTag: "player")
            }
        }

        func creation() -> GroupGameOperation {
            GroupGameOperation.create(groupID: id, gameID: UUID(), playerIDs: playerIDs)
        }

        func games(_ role: GroupRosterAccess.Role, account: String) -> GroupGameStore {
            games(authorize: { GroupRosterAccess(role: role, groupID: self.id, account: account) })
        }

        func games(
            authorize: @escaping () async throws -> GroupRosterAccess,
            verifyAccount: @escaping () async throws -> Void = {}
        ) -> GroupGameStore {
            let zone = CKRecordZone.ID(zoneName: "RummyGroup-\(id.uuidString)", ownerName: "owner")
            return GroupGameStore(groupID: id, root: CKRecord.ID(recordName: "group", zoneID: zone), store: transport,
                                  authorize: authorize, verifyAccount: verifyAccount, loadPlayers: { self.players })
        }
    }

    private final class MemoryStore: GroupRecordStore {
        var records: [CKRecord.ID: GroupStoredRecord] = [:]
        var beforeSave: (() async throws -> Void)?
        var afterSave: (() async throws -> Void)?
        private(set) var commits = 0

        func record(for id: CKRecord.ID) async throws -> GroupStoredRecord? {
            try records[id].map { try copy($0, tag: $0.changeTag) }
        }

        func saveAtomically(_ values: [GroupStoredRecord]) async throws -> [CKRecord.ID: GroupStoredRecord] {
            let before = beforeSave
            beforeSave = nil
            try await before?()
            guard values.allSatisfy({ records[$0.record.recordID]?.changeTag == $0.changeTag }) else {
                throw GroupAtomicWriteError.conflict
            }
            let revision = commits + 1
            let saved = try Dictionary(uniqueKeysWithValues: values.map { entry in
                (entry.record.recordID, try copy(entry, tag: String(revision)))
            })
            let output = try saved.mapValues { try copy($0, tag: $0.changeTag) }
            records.merge(saved) { _, new in new }
            commits = revision
            let after = afterSave
            afterSave = nil
            try await after?()
            return output
        }

        private func copy(_ entry: GroupStoredRecord, tag: String?) throws -> GroupStoredRecord {
            guard let record = entry.record.copy() as? CKRecord else { throw Failure("Couldn’t copy test record") }
            return GroupStoredRecord(record, changeTag: tag)
        }
    }
}
