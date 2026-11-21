#if DEBUG
import CloudKit
import Foundation

// Opt-in, console-only checks for a disposable Development group.
enum GroupRosterVerification {
    private static var started = false
    private static let ownerDraft = draft(1, "Roster Owner Example")
    private static let memberDraft = draft(2, "Roster Member Example")

    static func runIfRequested(containerIdentifier: String) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, let flag = arguments.firstIndex(of: "-VerifySharedRoster") else { return }
        started = true
        let options = Array(arguments.dropFirst(flag + 1).prefix(3))
        guard options.count >= 2, options[0].hasPrefix("Roster-Verification-") else {
            print("[Roster verification] FAIL Use: -VerifySharedRoster Roster-Verification-<unique> <step>")
            return
        }
        let step = options[1]
        do {
            let repository = GroupRepository(containerIdentifier: containerIdentifier)
            let account = try await repository.accountID()
            let matches = try await repository.discover().filter { $0.name == options[0] }
            guard matches.count == 1, let group = matches.first else {
                throw Failure("Expected exactly one accessible group with the disposable group name.")
            }
            let roster = repository.roster(for: group, account: account)
            let outcome = try await run(step, options: options, group: group, roster: roster)
            let scope = group.isOwner ? "owner private database" : "member shared database"
            print("[Roster verification] PASS \(step) (\(scope)): \(outcome)")
        } catch {
            let failure = error as NSError
            print("[Roster verification] FAIL \(step): \(failure.localizedDescription) (\(failure.domain) \(failure.code))")
        }
    }

    private static func run(
        _ step: String, options: [String], group: GroupSummary, roster: GroupRoster
    ) async throws -> String {
        switch step {
        case "owner-create", "member-create":
            let ownerStep = step == "owner-create"
            try require(group.isOwner == ownerStep, "Run this step under the matching owner or member account.")
            let example = ownerStep ? ownerDraft : memberDraft
            let saved = try await roster.add(example)
            let players = try await roster.players()
            try require(players.contains(saved), "The saved player or its reservation could not be read back.")
            return "Player and reservation verified for \(saved.id)."
        case "read":
            let players = try await roster.players()
            for example in [ownerDraft, memberDraft] {
                try require(players.contains { $0.id == example.id && $0.displayName == example.displayName },
                            "The roster did not contain both seeded players and their reservations.")
            }
            return "Both seeded player/reservation pairs are visible."
        case "race":
            guard options.count == 3, let epoch = Double(options[2]), epoch.isFinite else {
                throw Failure("Use the same future Unix timestamp in seconds on both phones.")
            }
            let deadline = Date(timeIntervalSince1970: epoch)
            let contender = group.isOwner ? draft(3, "Roster Race") : draft(4, "  ROSTER RACE  ")
            var prepared = false
            let racing = intercept(roster, beforeSave: {
                let delay = deadline.timeIntervalSinceNow
                try require((2...300).contains(delay), "Start both runs 2–300 seconds before the agreed time.")
                prepared = true
                print("[Roster verification] READY race: prepared a conditional write for \(contender.id).")
                try await Task.sleep(for: .seconds(delay))
            })
            do {
                let saved = try await racing.add(contender)
                try require(prepared, "Use a fresh disposable group. This race player already exists.")
                return "Committed \(saved.id). Run race-read on both phones to confirm the single winner."
            } catch GroupRosterError.duplicateName {
                try require(prepared, "The name was taken before this phone prepared its write. Repeat in a fresh disposable group.")
                return "Duplicate rejected for \(contender.id). Run race-read on both phones to confirm the single winner."
            }
        case "race-read":
            let players = try await roster.players()
            let contenders = players.filter { [draft(3, "").id, draft(4, "").id].contains($0.id) }
            try require(contenders.count == 1 &&
                        contenders.first.map { PlayerName.comparisonKey($0.displayName) } == "roster race",
                        "Expected one race winner with its reservation and no orphaned player.")
            return "Exactly one race player and its reservation are present."
        case "rollback":
            try require(!group.isOwner, "Run rollback as the approved member.")
            try await verifyRollback(roster)
            return "Rejected batches preserved the records. A released name was reassigned to a new player."
        case "retry":
            try require(!group.isOwner, "Run retry as the approved member.")
            let example = draft(7, "Roster Retry")
            let key = roster.playerID(example.id)
            let existing = try await roster.store.record(for: key)
            try require(existing == nil, "Use a fresh disposable group for the first retry check.")
            let interrupted = intercept(roster, afterSave: { throw GroupRosterWriteError.unconfirmed(CKError(.networkFailure)) })
            let recovered = try await interrupted.add(example)
            let retried = try await roster.add(example)
            let matching = try await roster.players().filter { $0.id == example.id }
            try require(recovered == retried && matching == [retried], "Retry did not recover the original committed player.")
            return "Recovered a real committed write with a simulated lost response and reused \(retried.id)."
        default:
            throw Failure("Unknown verification step.")
        }
    }

    private static func verifyRollback(_ roster: GroupRoster) async throws {
        let original = try await roster.add(memberDraft)
        let rejectedName = "Roster Rejected Reservation"
        let key = roster.reservationID(for: rejectedName)
        let existing = try await roster.store.record(for: key)
        try require(existing == nil, "The rollback test’s unused name already has a reservation.")
        let collision = roster.newChild(GroupRecordTypes.player, id: roster.playerID(original.id))
        collision.record["displayName"] = rejectedName
        collision.record["creatorKey"] = original.creatorKey
        let orphan = roster.newChild(GroupRecordTypes.playerName, id: key)
        orphan.record["playerID"] = original.id.uuidString
        try await roster.authorize().requireAdd()
        do {
            _ = try await roster.store.saveAtomically([collision, orphan])
            throw Failure("CloudKit unexpectedly accepted a conditional create for an existing player ID.")
        } catch GroupRosterWriteError.conflict {
            let record = try await roster.store.record(for: key)
            try require(record == nil, "The rejected player write left an orphaned name reservation.")
        }

        let competitor = draft(6, "Roster Rename Conflict")
        let renewal = roster.reservationID(for: competitor.displayName)
        let existingCompetitor = try await roster.store.record(for: renewal)
        try require(existingCompetitor == nil, "Use a fresh disposable group for the rename collision check.")
        let conflicting = intercept(roster, beforeSave: { _ = try await roster.add(competitor) })
        do {
            _ = try await conflicting.rename(original, to: competitor.displayName)
            throw Failure("CloudKit accepted the rename after another player reserved the new name.")
        } catch GroupRosterError.duplicateName {
            let players = try await roster.players()
            guard players.contains(original), let holder = players.first(where: {
                $0.id == competitor.id && $0.displayName == competitor.displayName
            }) else { throw Failure("The rejected rename changed a player or its reservation.") }
            let renamed = try await roster.rename(holder, to: "Roster Renamed Competitor")
            let reused = try await roster.add(draft(8, competitor.displayName))
            let reloaded = try await roster.players()
            try require(renamed.id == competitor.id && reused.id != renamed.id &&
                        reloaded.contains(renamed) && reloaded.contains(reused),
                        "The transferred reservation did not stay with the new holder.")
        }
    }

    private static func draft(_ number: UInt8, _ name: String) -> GroupPlayerDraft {
        GroupPlayerDraft(id: UUID(uuid: (0x3A, 2, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, number)), displayName: name)
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
        _ roster: GroupRoster, beforeSave: @escaping () async throws -> Void = {},
        afterSave: @escaping () throws -> Void = {}
    ) -> GroupRoster {
        GroupRoster(
            groupID: roster.groupID, root: roster.root,
            store: InterceptedStore(base: roster.store, beforeSave: beforeSave, afterSave: afterSave),
            authorize: roster.authorize, verifyAccount: roster.verifyAccount
        )
    }

    private struct InterceptedStore: GroupRosterStore {
        let base: any GroupRosterStore
        let beforeSave: () async throws -> Void
        let afterSave: () throws -> Void

        func record(for id: CKRecord.ID) async throws -> GroupRosterRecord? { try await base.record(for: id) }
        func records() async throws -> [GroupRosterRecord] { try await base.records() }

        func saveAtomically(_ records: [GroupRosterRecord]) async throws -> [CKRecord.ID: GroupRosterRecord] {
            try await beforeSave()
            let saved = try await base.saveAtomically(records)
            try afterSave()
            return saved
        }
    }
}
#endif
