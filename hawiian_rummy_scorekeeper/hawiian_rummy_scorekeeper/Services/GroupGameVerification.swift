#if DEBUG
import CloudKit
import Foundation

// Opt-in console checks. Device results must come from the Development environment.
enum GroupGameVerification {
    private static var started = false
    private static let ownerGame = id(1)
    private static let memberGame = id(2)
    private static let playerNames = ["Storage Player One", "Storage Player Two"]

    static func runIfRequested(containerIdentifier: String) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, let flag = arguments.firstIndex(of: "-VerifySharedGame") else { return }
        started = true
        let options = Array(arguments.dropFirst(flag + 1).prefix(2))
        guard options.count == 2, options[0].hasPrefix("Game-Verification-") else {
            print("[Game verification] FAIL Use -VerifySharedGame Game-Verification-<unique> <step>")
            return
        }
        let step = options[1]
        do {
            let repository = GroupRepository(containerIdentifier: containerIdentifier)
            let account = try await repository.accountID()
            let matches = try await repository.discover().filter { $0.name == options[0] }
            if step == "revoked" {
                try require(matches.isEmpty, "This account still sees the verification group.")
                print("[Game verification] PASS revoked: this account can no longer discover the group.")
                return
            }
            guard matches.count == 1, let group = matches.first else {
                throw Failure("Expected exactly one accessible disposable verification group.")
            }
            let games = repository.games(for: group, account: account)
            let result = try await run(step, games: games, isOwner: group.isOwner)
            let scope = group.isOwner ? "owner private database" : "member shared database"
            let outcome = step == "retry-status" ? "STATUS" : "PASS"
            print("[Game verification] \(outcome) \(step) (\(scope)): \(result)")
        } catch {
            let failure = error as NSError
            print("[Game verification] FAIL \(step): \(failure.localizedDescription) (\(failure.domain) \(failure.code))")
        }
    }

    static func run(_ step: String, games: GroupGameStore, isOwner: Bool) async throws -> String {
        let ownGame = isOwner ? ownerGame : memberGame
        switch step {
        case "owner-create", "member-create":
            try require(isOwner == (step == "owner-create"), "Run this step under the indicated account.")
            let players = try await games.loadPlayers()
            let ids = try playerNames.map { name in
                guard let player = players.first(where: { $0.displayName == name && $0.retiredAt == nil }) else {
                    throw Failure("Add both active storage players through Group Players first.")
                }
                return player.id
            }
            let operation = GroupGameOperation.create(groupID: games.groupID, gameID: ownGame, playerIDs: ids)
            let receipt = try await games.perform(operation)
            let snapshot = try await games.load(ownGame)
            try require(receipt.revision == 1 && snapshot.header.version.revision == 1 &&
                        snapshot.header.participants.map(\.playerID) == ids &&
                        snapshot.header.creatorKey == snapshot.header.scorekeeperKey &&
                        snapshot.rounds.count == 1 && snapshot.rounds.first?.id.number == 1 &&
                        snapshot.rounds.first?.hands == [], "Game header, initial round, or creation receipt did not match.")
            return "Header, first round and receipt verified for \(ownGame)."
        case "read":
            let owner = try await games.load(ownerGame)
            let member = try await games.load(memberGame)
            try require(owner.header.participants == member.header.participants &&
                        owner.header.participants.map(\.displayName) == playerNames &&
                        owner.header.creatorKey != member.header.creatorKey,
                        "The two games did not retain the expected participant order and distinct creators.")
            return "Read both games. Owner: \(summary(owner)). Member: \(summary(member))."
        case "write":
            let snapshot = try await games.load(ownGame)
            try require(snapshot.header.version.revision == 1, "Run write once per account, just after creation.")
            let wanted = hand(1, points: 3, header: snapshot.header)
            let save = operation(3, header: snapshot.header, action: .saveHand(round: 1, hand: wanted))
            let receipt = try await games.perform(save)
            let updated = try await games.load(ownGame)
            try require(receipt.revision == 2 && updated.header.version.revision == 2 &&
                        updated.rounds.first?.hands == [wanted], "Score, round and acknowledgment did not match.")
            let other = try await games.load(isOwner ? memberGame : ownerGame)
            do {
                _ = try await games.perform(operation(4, header: other.header, action: .complete))
                throw Failure("A different account unexpectedly changed the game.")
            } catch GroupGameError.notScorekeeper {}
            return "Saved a hand and verified that a non-scorekeeper cannot complete the other game."
        case "rollback":
            try require(!isOwner, "Run rollback as the member.")
            let before = try await games.load(ownGame)
            try require(before.header.version.revision == 4 && before.header.completedAt == nil &&
                        before.rounds.first?.hands == [hand(1, points: 21, header: before.header)],
                        "Run rollback after the member's retry check.")
            let competing = operation(5, header: before.header, action: .complete)
            let stale = operation(6, header: before.header,
                                  action: .saveHand(round: 1, hand: hand(2, points: 7, header: before.header)))
            let intercepted = intercept(games, beforeSave: { _ = try await games.perform(competing) })
            do {
                _ = try await intercepted.perform(stale)
                throw Failure("CloudKit accepted a batch with a stale game header.")
            } catch GroupGameError.staleGame {
                let after = try await games.load(ownGame)
                let missingReceipt = try await games.store.record(for: games.receiptID(for: stale))
                try require(after.header.version.revision == 5 && after.header.completedAt != nil &&
                            after.rounds == before.rounds && missingReceipt == nil,
                            "CloudKit left a score change or receipt from the rejected batch.")
            }
            return "Completion won. The stale batch left neither a new hand nor a receipt."
        case "retry-status", "retry":
            try require(!isOwner, "Run \(step) as the member.")
            let before = try await games.load(memberGame)
            let readiness = try await retryReadiness(before, games: games)
            if step == "retry-status" { return readiness.message }
            try require(readiness.isReady, readiness.message)
            let original = operation(7, header: before.header,
                                     action: .saveHand(round: 1, hand: hand(1, points: 11, header: before.header)))
            let newer = hand(1, points: 21, header: before.header)
            let interrupted = intercept(games, afterSave: {
                let committed = try await games.load(ownGame)
                _ = try await games.perform(operation(8, header: committed.header, action: .saveHand(round: 1, hand: newer)))
                throw GroupAtomicWriteError.unconfirmed(CKError(.networkFailure))
            })
            let recovered = try await interrupted.perform(original)
            let retried = try await games.perform(original)
            let latest = try await games.load(ownGame)
            try require(recovered == retried && recovered.revision == 3 && latest.header.version.revision == 4 &&
                        latest.header.completedAt == nil &&
                        latest.rounds.first?.hands == [newer], "Retry did not recover the original receipt and preserve the newer scores.")
            return "Recovered revision 3 from its receipt after a simulated lost response. Revision 4 and its scores were preserved."
        default:
            throw Failure("Unknown verification step.")
        }
    }

    private static func retryReadiness(
        _ snapshot: GroupGameSnapshot, games: GroupGameStore
    ) async throws -> (isReady: Bool, message: String) {
        let header = snapshot.header
        let access = try await games.authorize()
        let isScorekeeper = access.role == .editor && access.creatorKey == header.scorekeeperKey
        let initial = try await receiptStatus(3, revision: 2, header: header, games: games)
        let firstRetry = try await receiptStatus(7, revision: 3, header: header, games: games)
        let newerRetry = try await receiptStatus(8, revision: 4, header: header, games: games)
        try await games.verifyAccount()

        let originalHand = hand(1, points: 3, header: header)
        let isReady = header.version.revision == 2 && header.completedAt == nil &&
            snapshot.rounds.count == 1 && snapshot.rounds.first?.hands == [originalHand] &&
            isScorekeeper && initial == .verified && firstRetry == .missing && newerRetry == .missing
        let state = isReady ? "READY" : "BLOCKED"
        let hands = snapshot.rounds.first?.hands.count ?? 0
        let scorekeeper = isScorekeeper ? "yes" : "no"
        let message = "\(state) for retry. Member game \(header.id): \(summary(snapshot)), \(hands) hand(s) in round 1. " +
            "Scorekeeper matches: \(scorekeeper). Receipts 03/07/08: " +
            "\(initial.rawValue)/\(firstRetry.rawValue)/\(newerRetry.rawValue)."
        return (isReady, message)
    }

    private enum ReceiptStatus: String {
        case missing, verified, unexpected
    }

    private static func receiptStatus(
        _ number: UInt8, revision: Int, header: GroupGameHeader, games: GroupGameStore
    ) async throws -> ReceiptStatus {
        let recordID = games.receiptID(game: header.id, operationID: id(number))
        guard let entry = try await games.store.record(for: recordID) else { return .missing }
        let record = entry.record
        guard entry.changeTag != nil, record.recordID == recordID,
              record.recordType == GroupRecordTypes.gameOperation,
              record.parent?.recordID == games.gameID(header.id),
              record["actorKey"] as? String == header.scorekeeperKey,
              record["revision"] as? Int == revision,
              let fingerprint = record["fingerprint"] as? String, !fingerprint.isEmpty else { return .unexpected }
        return .verified
    }

    private static func summary(_ game: GroupGameSnapshot) -> String {
        let scores = game.rounds.first?.hands.first?.scores.map { String($0.points) }.joined(separator: ", ") ?? "none"
        let state = game.header.completedAt == nil ? "in progress" : "complete"
        return "revision \(game.header.version.revision), \(game.rounds.count) round(s), \(state), first hand \(scores)"
    }

    private static func hand(_ number: Int, points: Int, header: GroupGameHeader) -> GroupGameHand {
        let scores = Dictionary(uniqueKeysWithValues: header.participants.map { ($0.playerID, points) })
        return GroupGameHand(number: number, scores: scores)
    }

    private static func operation(
        _ number: UInt8, header: GroupGameHeader, action: GroupGameOperation.Action
    ) -> GroupGameOperation {
        GroupGameOperation(id: id(number), groupID: header.groupID, gameID: header.id,
                           expectedVersion: header.version, action: action)
    }

    private static func id(_ number: UInt8) -> UUID {
        UUID(uuid: (0x3B, 1, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, number))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func intercept(
        _ games: GroupGameStore, beforeSave: @escaping () async throws -> Void = {},
        afterSave: @escaping () async throws -> Void = {}
    ) -> GroupGameStore {
        GroupGameStore(
            groupID: games.groupID, root: games.root,
            store: InterceptedStore(base: games.store, beforeSave: beforeSave, afterSave: afterSave),
            authorize: games.authorize, verifyAccount: games.verifyAccount, loadPlayers: games.loadPlayers,
            loadOwnerAuthority: games.loadOwnerAuthority
        )
    }

    private struct InterceptedStore: GroupGameRecordStore {
        let base: any GroupGameRecordStore
        let beforeSave: () async throws -> Void
        let afterSave: () async throws -> Void

        func record(for id: CKRecord.ID) async throws -> GroupStoredRecord? { try await base.record(for: id) }

        func gameChildren(of game: CKRecord.ID) async throws -> [GroupStoredRecord] {
            try await base.gameChildren(of: game)
        }

        func saveManagement(
            _ records: [GroupStoredRecord], deleting ids: [CKRecord.ID], checking share: GroupStoredRecord
        ) async throws -> [CKRecord.ID: GroupStoredRecord] {
            try await base.saveManagement(records, deleting: ids, checking: share)
        }

        func saveAtomically(_ records: [GroupStoredRecord]) async throws -> [CKRecord.ID: GroupStoredRecord] {
            try await beforeSave()
            let saved = try await base.saveAtomically(records)
            try await afterSave()
            return saved
        }
    }
}
#endif
