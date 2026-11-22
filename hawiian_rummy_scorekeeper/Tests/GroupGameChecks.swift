import CloudKit
import Foundation

@main
struct GroupGameChecks {
    static func main() async throws {
        try await identityAndLifecycle()
        try await scoringSession()
        try await scoringProgression()
        try await ownerReassignment()
        try await ownerCancellation()
        try await ownerDeletion()
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
        let advance = change(snapshot, .startNextRound)
        let advanced = try await member.perform(advance)
        try check(try await member.perform(advance) == advanced, "Retrying advancement returns its original receipt")
        try await expect(GroupGameError.staleGame, "A second advancement from the same revision cannot add a round") {
            _ = try await member.perform(change(snapshot, .startNextRound))
        }
        let next = try await owner.load(create.gameID)
        try check(next.rounds.map(\.id) == [.init(gameID: create.gameID, number: 1), .init(gameID: create.gameID, number: 2)] &&
                  next.rounds.first?.hands.count == LevelDefinition.all.count && next.rounds.last?.hands == [],
                  "Starting another round preserves prior scores and attaches exactly one new round")
        try check(next.header.participants == original.header.participants, "Retired participants can continue their existing game")
        let corrected = scored(1, points: 7, next)
        _ = try await member.perform(change(next, .saveHand(round: 1, hand: corrected)))
        let reviewed = try await owner.load(create.gameID)
        try check(reviewed.rounds.first?.hands.first == corrected && reviewed.rounds.last?.hands.isEmpty == true &&
                  reviewed.standings().map(\.total) == [25, 25] && reviewed.standings().map(\.rank) == [1, 1],
                  "A prior round can be corrected and tied players retain a shared first place")
    }

    private static func scoringSession() async throws {
        let fixture = Fixture()
        let member = fixture.games(.editor, account: "member")
        let owner = fixture.games(.owner, account: "owner")
        let create = fixture.creation()
        _ = try await member.perform(create)
        var submitted: [GroupGameOperation] = []
        var loseResponse = false
        var failLoad = false
        var revoked = false
        let access = try await member.authorize()
        let scoring = GroupGameScoring(hasGroup: { true }, load: {
            if failLoad { throw CKError(.networkUnavailable) }
            let game = try await member.load(create.gameID)
            return .init(game: game, access: access, scorekeeperName: "You")
        }, perform: { operation in
            submitted.append(operation)
            let authorized = fixture.games {
                if revoked { throw GroupRosterError.accessLost }
                return access
            }
            let receipt = try await authorized.perform(operation)
            if loseResponse { throw CKError(.networkFailure) }
            return receipt
        })
        scoring.online = true
        await scoring.refresh()
        guard let original = scoring.detail?.game else { throw Failure("No initial scoring snapshot") }
        let observer = GroupGameScoring.Detail(
            game: try await owner.load(create.gameID), access: try await owner.authorize(), scorekeeperName: "Member"
        )
        try check(scoring.canScore && scoring.managementHeader == nil && !observer.canScore,
                  "A member scorekeeper can edit scores and cannot see owner controls")
        scoring.beginScores(round: 1, hand: 1)
        let first = fixture.playerIDs[0], second = fixture.playerIDs[1]
        scoring.updateScore(for: first, value: "9")
        scoring.updateScore(for: second, value: "-1")
        try check(!scoring.canSaveDraft, "Every participant needs a non-negative score")
        scoring.updateScore(for: second, value: "10")
        scoring.online = false
        await scoring.saveDraft()
        try check(submitted.isEmpty && scoring.draft?.values[first] == "9", "Offline score entry stays in the form")
        scoring.online = true
        await scoring.refresh()

        let competingHand = scored(1, points: 3, original)
        _ = try await member.perform(change(original, .saveHand(round: 1, hand: competingHand)))
        await scoring.saveDraft()
        try check(scoring.pending == nil && scoring.draftNeedsReview && !scoring.canSaveDraft &&
                  scoring.draft?.values[first] == "9" && scoring.savedDraftHand == competingHand,
                  "Stale-write rejection loads the newer score and retains the entered score for review")
        await scoring.saveDraft()
        try check(submitted.count == 1, "A newer version requires explicit review")
        scoring.reviewDraft()
        loseResponse = true
        await scoring.saveDraft()
        guard let pending = scoring.pending else { throw Failure("The unconfirmed operation was lost") }
        try check(scoring.canRetry && !scoring.canSaveDraft && pending.id != submitted[0].id &&
                  pending.expectedVersion != submitted[0].expectedVersion,
                  "A deliberate resubmission uses a fresh ID and the reviewed version")
        scoring.updateScore(for: first, value: "99")
        try check(scoring.draft?.values[first] == "9", "An ambiguous write retains its original score entries")
        loseResponse = false
        failLoad = true
        await scoring.retry()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try check(try encoder.encode(submitted.last) == encoder.encode(pending) && fixture.transport.commits == 3 &&
                  scoring.pending == nil && scoring.draft == nil && scoring.awaitingReadback && !scoring.canScore,
                  "Retry replays the exact operation and a failed readback is distinguished from a failed write")
        failLoad = false
        await scoring.refresh()
        try check(scoring.detail?.game.standings().map(\.total) == [9, 10] && scoring.canScore &&
                  !scoring.awaitingReadback, "A successful refresh displays the acknowledged scores")

        scoring.beginScores(round: 1, hand: 2)
        scoring.updateScore(for: first, value: "6")
        scoring.updateScore(for: second, value: "0")
        revoked = true
        await scoring.saveDraft()
        try check(!scoring.canView && scoring.detail == nil && scoring.pending == nil &&
                  fixture.transport.commits == 3, "Live revocation removes the opened game and prevents submission")
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
            try check(transport.records[games.gameID(create.gameID)] == nil &&
                      transport.records[games.roundID(game: create.gameID, number: 1)] == nil &&
                      transport.records[games.receiptID(for: create)] == nil,
                      "Failed create leaves no header, round or receipt")
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
        try check(completed.revision == 4 && final.header.completedAt != nil &&
                  final.rounds.first?.hands == [newer], "Completion preserves saved scores from a partial round")
        for action in [GroupGameOperation.Action.saveHand(round: 1, hand: corrected), .startNextRound, .complete] {
            let mutation = change(final, action)
            try await expect(GroupGameError.invalidTransition, "Completed games reject all new mutations") {
                _ = try await member.perform(mutation)
            }
            try check(transport.records[member.receiptID(for: mutation)] == nil, "Rejected mutations leave no receipt")
        }
        let replayed = try await member.perform(original)
        let reloaded = try await member.load(create.gameID)
        try check(replayed == recovered && reloaded == final,
                  "Recovery can acknowledge an old receipt after completion without changing the game")

        var verifications = 0
        let editable = fixture.creation()
        _ = try await member.perform(editable)
        let editableGame = try await member.load(editable.gameID)
        let revoked = fixture.games(authorize: {
            verifications += 1
            guard verifications == 1 else { throw GroupRosterError.accessLost }
            return GroupRosterAccess(role: .editor, groupID: fixture.id, account: "member")
        })
        let pending = change(editableGame, .saveHand(round: 1, hand: newer))
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
        guard let ownerGame = UUID(uuidString: "3B010000-0000-4000-8000-000000000001"),
              let memberGame = UUID(uuidString: "3B010000-0000-4000-8000-000000000002") else {
            throw Failure("Invalid verification game UUID")
        }
        let member = fixture.games(.editor, account: "member")
        let owner = fixture.games(.owner, account: "owner")
        _ = try await owner.perform(.create(groupID: fixture.id, gameID: ownerGame, playerIDs: fixture.playerIDs))
        _ = try await member.perform(.create(groupID: fixture.id, gameID: memberGame, playerIDs: fixture.playerIDs))
        let beforeWrite = fixture.transport.commits
        let early = try await GroupGameVerification.run("retry-status", games: member, isOwner: false)
        try check(early.hasPrefix("BLOCKED") && early.contains("revision 1") && fixture.transport.commits == beforeWrite,
                  "Wrong revision is reported without a write")
        _ = try await GroupGameVerification.run("write", games: member, isOwner: false)
        let reopened = fixture.games(.editor, account: "member")
        let afterWrite = fixture.transport.commits
        let ready = try await GroupGameVerification.run("retry-status", games: reopened, isOwner: false)
        try check(ready.hasPrefix("READY") && ready.contains("verified/missing/missing") &&
                  fixture.transport.commits == afterWrite,
                  "A new store instance recognizes the first saved hand without a write")
        let differentMember = fixture.games(.editor, account: "other")
        let wrongActor = try await GroupGameVerification.run("retry-status", games: differentMember, isOwner: false)
        try check(wrongActor.hasPrefix("BLOCKED") && wrongActor.contains("Scorekeeper matches: no"),
                  "An approved member cannot resume another scorekeeper’s probe")

        _ = try await GroupGameVerification.run("retry", games: reopened, isOwner: false)
        let afterRetry = fixture.transport.commits
        let advanced = try await GroupGameVerification.run("retry-status", games: reopened, isOwner: false)
        try check(advanced.hasPrefix("BLOCKED") && advanced.contains("revision 4") &&
                  advanced.contains("verified/verified/verified") && afterRetry == afterWrite + 2,
                  "The read-only status reports both retry receipts once Test 6 has written")
        do {
            _ = try await GroupGameVerification.run("retry", games: reopened, isOwner: false)
            throw Failure("A second retry run should have been blocked")
        } catch {
            try check(error.localizedDescription.contains("BLOCKED for retry") && fixture.transport.commits == afterRetry,
                      "An advanced game rejects a repeated retry probe before writing")
        }
        _ = try await GroupGameVerification.run("rollback", games: member, isOwner: false)
        let final = try await owner.load(memberGame)
        try check(final.header.version.revision == 5 && final.header.completedAt != nil &&
                  final.rounds.first?.hands == [scored(1, points: 21, final)] && fixture.transport.commits == afterRetry + 1,
                  "The revised rollback probe completes the game and retains the recovered scores")
    }

    private static func scoringProgression() async throws {
        let fixture = Fixture()
        let games = fixture.games(.owner, account: "owner")
        let create = fixture.creation()
        _ = try await games.perform(create)
        let scoring = GroupGameScoring(hasGroup: { true }, load: {
            let (game, access) = try await games.loadWithAccess(create.gameID)
            return .init(game: game, access: access, scorekeeperName: "You")
        }, perform: games.perform)
        scoring.online = true
        await scoring.refresh()
        guard let initial = scoring.detail?.game.header.version else { throw Failure("No initial revision") }
        await scoring.advance(from: initial)
        try check(fixture.transport.commits == 1, "Advancement is unavailable before all seven hands are saved")
        for level in LevelDefinition.all {
            scoring.beginScores(round: 1, hand: level.number)
            for id in fixture.playerIDs { scoring.updateScore(for: id, value: "3") }
            await scoring.saveDraft()
        }
        guard let version = scoring.detail?.game.header.version else { throw Failure("No scored revision") }
        await scoring.advance(from: version)
        await scoring.advance(from: version)
        try check(scoring.detail?.game.rounds.map(\.hands.count) == [7, 0] && fixture.transport.commits == 9,
                  "The freshly loaded second round blocks a duplicate advancement")
        await scoring.complete(from: version)
        try check(scoring.detail?.game.header.completedAt == nil && fixture.transport.commits == 9,
                  "A completion confirmation uses the version the scorekeeper reviewed")
        guard let current = scoring.detail?.game.header.version else { throw Failure("No advanced revision") }
        await scoring.complete(from: current)
        try check(scoring.detail?.game.header.completedAt != nil && !scoring.canScore && fixture.transport.commits == 10,
                  "A successful completion reloads the final scores and disables editing")
    }

    private static func ownerReassignment() async throws {
        let fixture = Fixture()
        let owner = fixture.games(.owner, account: "owner", participantID: "owner-participant")
        let member = fixture.games(.editor, account: "member", participantID: "member-participant")
        let other = fixture.games(.editor, account: "account-not-visible-to-owner", participantID: "other-participant")
        let create = fixture.creation()
        _ = try await member.perform(create)
        let initial = try await member.load(create.gameID)
        let firstHand = scored(1, points: 7, initial)
        _ = try await member.perform(change(initial, .saveHand(round: 1, hand: firstHand)))
        let before = try await owner.load(create.gameID)
        let ownerKey = fixture.scorekeeperKey("owner-participant")
        let memberKey = fixture.scorekeeperKey("member-participant")
        let otherKey = fixture.scorekeeperKey("other-participant")
        func openAsOwner(scorekeeperName: String?) async -> GroupGameScoring {
            let scoring = GroupGameScoring(hasGroup: { true }, load: {
                let (game, access) = try await owner.loadWithAccess(create.gameID)
                let name = access.isScorekeeper(game.header.scorekeeperKey) ? "You" : scorekeeperName
                return .init(game: game, access: access, scorekeeperName: name)
            }, perform: owner.perform)
            scoring.online = true
            await scoring.refresh()
            return scoring
        }
        let active = await openAsOwner(scorekeeperName: "Member")
        try check(active.managementHeader == before.header && active.canManage && !active.canScore,
                  "The owner's Manage Game row is available while an active member keeps score")
        let reassign = change(before, .reassignScorekeeper(participantKey: ownerKey))
        try await expect(GroupRosterError.notAuthorized, "A member cannot reassign even their own game") {
            _ = try await member.perform(reassign)
        }
        try await expect(GroupGameError.notScorekeeper, "The owner has no implicit scoring access") {
            _ = try await owner.perform(change(before, .saveHand(round: 1, hand: firstHand)))
        }
        fixture.setEligibleParticipants(["owner-participant", "other-participant"], version: "revoked")
        let scoring = await openAsOwner(scorekeeperName: nil)
        guard let abandoned = scoring.managementHeader else {
            throw Failure("Manage Game must be visible when the owner opens an abandoned game")
        }
        try check(abandoned.version == before.header.version && scoring.detail?.scorekeeperName == nil &&
                  scoring.canManage && !scoring.canScore,
                  "The revoked scorekeeper's missing name leaves owner management available and scores read-only")
        try await expect(GroupGameError.scorekeeperUnavailable, "The owner cannot assign a revoked participant") {
            _ = try await owner.perform(change(before, .reassignScorekeeper(participantKey: memberKey)))
        }
        await scoring.reassignScorekeeper(ownerKey, from: abandoned.version)
        let recovered = try await owner.load(create.gameID)
        try check(recovered.header.scorekeeperKey == ownerKey && recovered.header.creatorKey == before.header.creatorKey &&
                  recovered.header.participants == before.header.participants && recovered.rounds == before.rounds &&
                  scoring.detail?.game == recovered && scoring.canScore,
                  "Reassigning from Manage Game preserves history and enables scoring after reloading")
        let secondHand = scored(2, points: 5, recovered)
        _ = try await owner.perform(change(recovered, .saveHand(round: 1, hand: secondHand)))
        let continued = try await owner.load(create.gameID)
        let newAssignment = change(continued, .reassignScorekeeper(participantKey: otherKey))

        fixture.transport.beforeSave = {
            fixture.setEligibleParticipants(["owner-participant"], version: "revoked-during-reassignment")
        }
        try await expect(GroupGameError.staleGame, "Revocation after validation invalidates the share change tag") {
            _ = try await owner.perform(newAssignment)
        }
        try check(try await owner.load(create.gameID) == continued &&
                  fixture.transport.records[owner.receiptID(for: newAssignment)] == nil,
                  "A race against revocation changes neither the game nor its receipts")
        try await expect(GroupGameError.scorekeeperUnavailable, "Retry revalidates the target’s live eligibility") {
            _ = try await owner.perform(newAssignment)
        }
        fixture.setEligibleParticipants(["owner-participant", "other-participant"], version: "approved-again")
        let lateScore = change(continued, .saveHand(round: 1, hand: scored(3, points: 11, continued)))
        fixture.transport.beforeSave = { _ = try await owner.perform(newAssignment) }
        try await expect(GroupGameError.staleGame, "Reassignment wins against a prepared prior-scorekeeper write") {
            _ = try await owner.perform(lateScore)
        }
        let reassigned = try await other.load(create.gameID)
        try check(reassigned.header.scorekeeperKey == otherKey && reassigned.rounds == continued.rounds &&
                  fixture.transport.records[owner.receiptID(for: lateScore)] == nil,
                  "Reassign while an existing scorekeeper is active and leave that scorekeeper’s pending write unapplied")
        try await expect(GroupGameError.notScorekeeper, "Former scorekeeper loses scoring permissions even at the latest revision") {
            _ = try await owner.perform(change(reassigned, .saveHand(round: 1, hand: secondHand)))
        }
        let thirdHand = scored(3, points: 9, reassigned)
        _ = try await other.perform(change(reassigned, .saveHand(round: 1, hand: thirdHand)))
        let latest = try await owner.load(create.gameID)
        try check(latest.rounds.first?.hands == [firstHand, secondHand, thirdHand],
                  "The approved recipient can continue using the share participant ID despite account aliases")
    }

    private static func ownerCancellation() async throws {
        let fixture = Fixture()
        let owner = fixture.games(.owner, account: "owner")
        let member = fixture.games(.editor, account: "member")
        let create = fixture.creation()
        _ = try await member.perform(create)
        let original = try await member.load(create.gameID)
        let hand = scored(1, points: 4, original)
        _ = try await member.perform(change(original, .saveHand(round: 1, hand: hand)))
        let before = try await member.load(create.gameID)
        let cancel = change(before, .cancel)
        try await expect(GroupRosterError.notAuthorized, "A scorekeeper without ownership cannot cancel") {
            _ = try await member.perform(cancel)
        }
        let pendingScore = change(before, .saveHand(round: 1, hand: scored(2, points: 9, before)))
        fixture.transport.beforeSave = { _ = try await owner.perform(cancel) }
        try await expect(GroupGameError.staleGame, "Cancellation atomically invalidates a prepared scoring write") {
            _ = try await member.perform(pendingScore)
        }
        let cancelled = try await member.load(create.gameID)
        try check(cancelled.header.status == .cancelled && cancelled.header.completedAt == nil &&
                  cancelled.rounds == before.rounds && cancelled.header.participants == before.header.participants,
                  "Cancellation is a distinct status and preserves saved scores and snapshots")
        let acknowledged = try await owner.perform(cancel)
        try check(acknowledged.revision == cancelled.header.version.revision && fixture.transport.commits == 3,
                  "Cancellation retry reuses its receipt")
        for action in [GroupGameOperation.Action.saveHand(round: 1, hand: hand), .startNextRound, .complete] {
            try await expect(GroupGameError.invalidTransition, "A cancelled game rejects scoring and progression") {
                _ = try await member.perform(change(cancelled, action))
            }
        }
        try await expect(GroupGameError.invalidTransition, "A cancelled game cannot be reassigned") {
            _ = try await owner.perform(change(cancelled, .reassignScorekeeper(participantKey: fixture.scorekeeperKey("owner-participant"))))
        }
        let finished = fixture.creation()
        _ = try await owner.perform(finished)
        let active = try await owner.load(finished.gameID)
        _ = try await owner.perform(change(active, .complete))
        let completed = try await owner.load(finished.gameID)
        for action in [GroupGameOperation.Action.cancel, .reassignScorekeeper(participantKey: fixture.scorekeeperKey("other-participant"))] {
            try await expect(GroupGameError.invalidTransition, "Completed games cannot be cancelled or reassigned") {
                _ = try await owner.perform(change(completed, action))
            }
        }
        _ = try await owner.perform(change(completed, .delete))
        _ = try await owner.perform(change(cancelled, .delete))
        let headers = fixture.transport.records.values.filter { GroupGameStore.gameUUID($0.record.recordID) != nil }
        try check(try await owner.list { Array(headers) }.isEmpty, "The owner can permanently delete completed and cancelled games")
    }

    private static func ownerDeletion() async throws {
        let fixture = Fixture()
        let owner = fixture.games(.owner, account: "owner")
        let member = fixture.games(.editor, account: "member")
        let create = fixture.creation()
        _ = try await member.perform(create)
        let unrelated = fixture.creation()
        _ = try await owner.perform(unrelated)
        let untouched = try await owner.load(unrelated.gameID)
        let before = try await member.load(create.gameID)
        let score = change(before, .saveHand(round: 1, hand: scored(1, points: 3, before)))
        fixture.transport.beforeSave = { _ = try await member.perform(score) }
        try await expect(GroupGameError.staleGame, "A stale deletion cannot remove a newly scored game") {
            _ = try await owner.perform(change(before, .delete))
        }
        let current = try await member.load(create.gameID)
        let delete = change(current, .delete)
        try await expect(GroupRosterError.notAuthorized, "A member cannot delete even their own game") {
            _ = try await member.perform(delete)
        }
        fixture.transport.beforeSave = { throw CKError(.limitExceeded) }
        try await expect(GroupGameError.deletionTooLarge, "CloudKit batch limits fail without partially deleting the game") {
            _ = try await owner.perform(delete)
        }
        try check(try await member.load(create.gameID) == current &&
                  fixture.transport.records[owner.receiptID(for: delete)] == nil,
                  "A rejected delete preserves the header, scores, and previous receipts")

        let lateScore = change(current, .saveHand(round: 1, hand: scored(2, points: 6, current)))
        fixture.transport.beforeSave = {
            fixture.transport.afterSave = { throw GroupAtomicWriteError.unconfirmed(CKError(.networkFailure)) }
            _ = try await owner.perform(delete)
        }
        try await expect(GroupGameError.staleGame, "Deletion invalidates a pending write before its atomic commit") {
            _ = try await member.perform(lateScore)
        }
        let recovered = try await owner.perform(delete)
        let ids = try await fixture.transport.gameChildren(of: owner.gameID(create.gameID)).map(\.record.recordID)
        try check(recovered.revision == current.header.version.revision + 1 &&
                  ids == [owner.receiptID(for: delete)] && fixture.transport.commits == 4,
                  "An ambiguous deletion keeps one receipt and deletes all previous rounds and receipts atomically")
        let tombstone = fixture.transport.records[owner.gameID(create.gameID)]?.record
        try check(tombstone?["deletedAt"] is Date && tombstone?["participants"] == nil &&
                  tombstone?["scorekeeperKey"] == nil, "The durable marker contains no players or scorekeeper identity")
        let headers = fixture.transport.records.values.filter { GroupGameStore.gameUUID($0.record.recordID) != nil }
        try check(try await member.list { Array(headers) } == [untouched.header], "Fresh history omits deleted games")
        try check(try await owner.load(unrelated.gameID) == untouched, "Deletion leaves other games alone")
        try await expect(GroupGameError.gameDeleted, "The old game route cannot reopen the game") {
            _ = try await member.load(create.gameID)
        }
        for operation in [create, score, lateScore] {
            try await expect(GroupGameError.gameDeleted, "A stale device cannot recreate or modify the deleted game") {
                _ = try await member.perform(operation)
            }
        }
        try await expect(GroupGameError.gameDeleted, "A different delete operation cannot delete the tombstone") {
            _ = try await owner.perform(change(current, .delete))
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
        private var shareID: CKRecord.ID {
            CKRecord.ID(recordName: "test-share", zoneID: zone)
        }
        private var zone: CKRecordZone.ID {
            CKRecordZone.ID(zoneName: "RummyGroup-\(id.uuidString)", ownerName: "owner")
        }
        private var eligibleParticipantIDs = ["owner-participant", "member-participant", "other-participant"]

        init() {
            let key = GroupRosterAccess(role: .owner, groupID: id, account: "owner").creatorKey
            players = playerIDs.enumerated().reversed().map {
                GroupPlayerIdentity(id: $0.element, groupID: id, creatorKey: key,
                                    displayName: "Player \($0.offset)", retiredAt: nil, changeTag: "player")
            }
            setEligibleParticipants(eligibleParticipantIDs, version: "share-1")
        }

        func setEligibleParticipants(_ ids: [String], version: String) {
            eligibleParticipantIDs = ids
            let share = CKRecord(recordType: "TestShare", recordID: shareID)
            transport.records[shareID] = GroupStoredRecord(share, changeTag: version)
        }

        func scorekeeperKey(_ participantID: String) -> String {
            GroupRosterAccess.scorekeeperKey(groupID: id, participantID: participantID)
        }

        func creation() -> GroupGameOperation {
            GroupGameOperation.create(groupID: id, gameID: UUID(), playerIDs: playerIDs)
        }

        func games(_ role: GroupRosterAccess.Role, account: String, participantID: String? = nil) -> GroupGameStore {
            games(authorize: {
                GroupRosterAccess(role: role, groupID: self.id, account: account, participantID: participantID)
            })
        }

        func games(
            authorize: @escaping () async throws -> GroupRosterAccess,
            verifyAccount: @escaping () async throws -> Void = {}
        ) -> GroupGameStore {
            return GroupGameStore(groupID: id, root: CKRecord.ID(recordName: "group", zoneID: zone), store: transport,
                                  authorize: authorize, verifyAccount: verifyAccount, loadPlayers: { self.players },
                                  loadOwnerAuthority: {
                guard let share = try await self.transport.record(for: self.shareID) else {
                    throw Failure("Missing mock share")
                }
                return GroupGameOwnerAuthority(share: share, eligibleKeys: Set(self.eligibleParticipantIDs.map {
                    self.scorekeeperKey($0)
                }))
            })
        }
    }

    private final class MemoryStore: GroupGameRecordStore {
        var records: [CKRecord.ID: GroupStoredRecord] = [:]
        var beforeSave: (() async throws -> Void)?
        var afterSave: (() async throws -> Void)?
        private(set) var commits = 0

        func record(for id: CKRecord.ID) async throws -> GroupStoredRecord? {
            try records[id].map { try copy($0, tag: $0.changeTag) }
        }

        func gameChildren(of game: CKRecord.ID) async throws -> [GroupStoredRecord] {
            try records.values.filter { $0.record.parent?.recordID == game }.map { try copy($0, tag: $0.changeTag) }
        }

        func saveAtomically(_ values: [GroupStoredRecord]) async throws -> [CKRecord.ID: GroupStoredRecord] {
            try await modify(values, deleting: [])
        }

        func saveManagement(
            _ values: [GroupStoredRecord], deleting ids: [CKRecord.ID], checking share: GroupStoredRecord
        ) async throws -> [CKRecord.ID: GroupStoredRecord] {
            try await modify(values + [share], deleting: ids)
        }

        private func modify(
            _ values: [GroupStoredRecord], deleting ids: [CKRecord.ID]
        ) async throws -> [CKRecord.ID: GroupStoredRecord] {
            let before = beforeSave
            beforeSave = nil
            try await before?()
            guard values.allSatisfy({ records[$0.record.recordID]?.changeTag == $0.changeTag }),
                  ids.allSatisfy({ records[$0] != nil }) else {
                throw GroupAtomicWriteError.conflict
            }
            let revision = commits + 1
            let saved = try Dictionary(uniqueKeysWithValues: values.map { entry in
                (entry.record.recordID, try copy(entry, tag: String(revision)))
            })
            let output = try saved.mapValues { try copy($0, tag: $0.changeTag) }
            for id in ids { records.removeValue(forKey: id) }
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
