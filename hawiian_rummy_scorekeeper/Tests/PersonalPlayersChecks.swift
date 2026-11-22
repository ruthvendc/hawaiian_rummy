import Foundation
import SwiftData

@main
struct PersonalPlayersChecks {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([PlayerProfile.self, Game.self, GameRound.self, RoundParticipant.self,
                             LevelResult.self, ScoreEntry.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "players.store"),
                                               cloudKitDatabase: .none)
        let store = try ModelContainer(for: schema, configurations: configuration)
        let context = store.mainContext
        try checkPersonalScoring(schema)

        let original = try PersonalPlayers.add("  Wendy  ", in: context)
        let originalID = original.id
        let originalRecord = original.persistentModelID
        let other = try PersonalPlayers.add("David", in: context)
        try check(original.name == "Wendy", "New names are trimmed")
        try expect(.emptyName, "Reject whitespace-only names") { _ = try PersonalPlayers.add(" \n ", in: context) }
        try expect(.activeName, "Reject an active duplicate with different case and whitespace") {
            _ = try PersonalPlayers.add("  wEnDy\n", in: context)
        }
        try expect(.activeName, "Rename checks names on other active profiles") {
            try PersonalPlayers.rename(other, to: "wendy", in: context)
        }
        try PersonalPlayers.rename(other, to: "DAVID", in: context)
        try check(other.name == "DAVID", "A player can change the capitalization of their own unique name")

        let game = Game(title: "History", players: [original, other])
        context.insert(game)
        let round = GameRules.createRound(in: game)
        let scorer = try require(round.orderedParticipants.first, "Expected participant")
        try GameRules.save(scores: [scorer.id: 24], for: 1, in: round, context: context)
        game.completedAt = .now
        try context.save()
        let gameID = game.id

        try PersonalPlayers.retire(original, in: context)
        try check(original.isRetired && !PlayerProfile.orderedActivePlayers([original, other]).contains(original),
                  "Removal takes the player out of the active roster")
        try expect(.retiredName, "Adding a retired name routes the user to restoration") {
            _ = try PersonalPlayers.add("WENDY ", in: context)
        }
        try expect(.retiredName, "Rename checks retired profiles too") {
            try PersonalPlayers.rename(other, to: "wendy", in: context)
        }
        let restored = try PersonalPlayers.restore(original, in: context)
        try check(restored.id == originalID && restored.persistentModelID == originalRecord && !restored.isRetired,
                  "Restoration reactivates the original UUID and persistent record")

        let newContext = ModelContext(store)
        let savedGame = try require(try newContext.fetch(FetchDescriptor<Game>()).first, "Expected saved game")
        let savedPlayer = try require(savedGame.players?.first(where: { $0.id == originalID }), "Expected historical player")
        try check(savedGame.id == gameID && savedPlayer.persistentModelID == originalRecord &&
                  savedGame.sortedRounds.first?.orderedParticipants.first?.player?.id == originalID &&
                  GameRules.gameStandings(for: savedGame).contains(where: { $0.0.id == originalID && $0.1 == 24 }),
                  "Saved games, participant relationships and score totals survive removal and restoration")

        // Insert the same data a sync import or an older app can leave behind.
        let imported = PlayerProfile(name: "  wEndY ")
        newContext.insert(imported)
        try newContext.save()
        let withConflict = try newContext.fetch(FetchDescriptor<PlayerProfile>())
        try check(PersonalPlayers.conflictingNames(in: withConflict) == ["wendy"] &&
                  Set(withConflict.map(\.id)) == [originalID, imported.id, other.id],
                  "Detect an existing collision and keep both profile identities")
        try PersonalPlayers.retire(savedPlayer, in: newContext)
        try expect(.restoreConflict, "Block restoration while an active profile has the same name") {
            _ = try PersonalPlayers.restore(savedPlayer, in: newContext)
        }
        try expect(.activeName, "Prioritize the active match when an active and retired profile share a name") {
            _ = try PersonalPlayers.add("WENDY", in: newContext)
        }
        let retirementDate = savedPlayer.retiredAt
        try expect(.activeName, "Retired rename rejects an active name regardless of case or surrounding spaces") {
            try PersonalPlayers.rename(savedPlayer, to: "  david ", whileRetired: true, in: newContext)
        }
        try PersonalPlayers.rename(savedPlayer, to: "  Wendy Other  ", whileRetired: true, in: newContext)
        let savedParticipant = try require(savedGame.sortedRounds.first?.orderedParticipants.first,
                                           "Expected historical participant after rename")
        try check(savedPlayer.id == originalID && savedPlayer.persistentModelID == originalRecord &&
                  savedPlayer.retiredAt == retirementDate && savedPlayer.name == "Wendy Other" && imported.name == "  wEndY " &&
                  savedParticipant.player?.id == originalID && savedParticipant.displayName == "Wendy" &&
                  GameRules.gameStandings(for: savedGame).contains {
                      $0.0.id == originalID && $0.0.name == "Wendy Other" && $0.1 == 24
                  },
                  "Rename only the retired profile, preserve its history, and retain round names with current standings labels")
        _ = try PersonalPlayers.restore(savedPlayer, in: newContext)
        try expect(.alreadyRestored, "Reject a retired rename after the profile has been restored") {
            try PersonalPlayers.rename(savedPlayer, to: "Unexpected Edit", whileRetired: true, in: newContext)
        }
        let resolved = try newContext.fetch(FetchDescriptor<PlayerProfile>())
        try check(PersonalPlayers.conflictingNames(in: resolved).isEmpty && resolved.count == 3 &&
                  !savedPlayer.isRetired && GameRules.score(for: savedPlayer, in: savedGame) == 24,
                  "Manual rename resolves the conflict and restoration preserves the original score")

        let firstRetired = PlayerProfile(name: "Jules")
        let secondRetired = PlayerProfile(name: " JULES ")
        for profile in [firstRetired, secondRetired] {
            profile.retiredAt = .now
            newContext.insert(profile)
        }
        try newContext.save()
        try expect(.retiredName, "Adding a name shared by multiple retired records requires choosing a profile") {
            _ = try PersonalPlayers.add("Jules", in: newContext)
        }
        let another = try PersonalPlayers.add("Taylor", in: newContext)
        try PersonalPlayers.retire(another, in: newContext)
        try expect(.retiredName, "Retired rename also rejects names held by another retired profile") {
            try PersonalPlayers.rename(another, to: "  jules ", whileRetired: true, in: newContext)
        }
        try expect(.duplicateRestoreNames, "Reject duplicate retired names within a bulk selection") {
            _ = try PersonalPlayers.restore([another, firstRetired, secondRetired], in: newContext)
        }
        try check([another, firstRetired, secondRetired].allSatisfy(\.isRetired),
                  "A duplicate selection leaves even the otherwise eligible player retired")
        let chosen = try PersonalPlayers.restore(secondRetired, in: newContext)
        try check(chosen.id == secondRetired.id && firstRetired.isRetired,
                  "Restore only the selected profile when multiple retired profiles share a name")
        try expect(.restoreConflict, "The other retired profile cannot create a second active match") {
            _ = try PersonalPlayers.restore(firstRetired, in: newContext)
        }
        try expect(.restoreConflict, "Reject a bulk restore that includes a conflict with an active player") {
            _ = try PersonalPlayers.restore([another, firstRetired], in: newContext)
        }
        try check(another.isRetired && firstRetired.isRetired, "An active-name conflict leaves the entire selection retired")
        try PersonalPlayers.rename(firstRetired, to: "Jules Family", whileRetired: true, in: newContext)
        let batch = try PersonalPlayers.restore([another, firstRetired], in: newContext)
        try check(batch.map(\.id) == [another.id, firstRetired.id] && batch.allSatisfy { !$0.isRetired },
                  "After renaming the retired profile, restore the entire selection with its original identities")
    }

    private static func expect(_ issue: PersonalPlayers.Issue, _ message: String, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let actual as PersonalPlayers.Issue where actual == issue {
            print("PASS: \(message)")
            return
        }
        throw Failure(message: message)
    }

    @MainActor
    private static func checkPersonalScoring(_ schema: Schema) throws {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let store = try ModelContainer(for: schema, configurations: configuration)
        let context = store.mainContext
        let first = PlayerProfile(name: "Zoe")
        let second = PlayerProfile(name: "Alex")
        let game = Game(title: "Personal scoring", players: [first, second])
        context.insert(game)
        let round = GameRules.createRound(in: game)
        try check(round.orderedParticipants.map(\.displayName) == ["Zoe", "Alex"], "Personal score entry keeps seating order")
        let firstID = try require(round.orderedParticipants.first?.id, "Expected first participant")
        let secondID = try require(round.orderedParticipants.last?.id, "Expected second participant")
        let ids = [firstID, secondID]
        try check(GameRules.parsedScores(for: ids, values: [firstID: "2", secondID: "-1"]) == nil,
                  "Personal entry still rejects negative scores")
        let scores = try require(GameRules.parsedScores(for: ids, values: [firstID: "2", secondID: "2"]), "Expected valid scores")
        for level in LevelDefinition.all {
            try GameRules.save(scores: scores, for: level.number, in: round, context: context)
        }
        try check(round.isComplete && GameRules.standings(for: round).map(\.rank) == [1, 1],
                  "Seven hands complete the round and tied players share first place")
        let next = GameRules.createRound(in: game)
        try check(GameRules.standings(for: next).map(\.total) == [0, 0], "The next personal round starts at zero")
        game.completedAt = .now
        try GameRules.save(scores: [firstID: 0, secondID: 2], for: 1, in: round, context: context)
        let standings = GameRules.gameStandings(for: game)
        try check(standings.map { $0.0.id } == [first.id, second.id] &&
                  standings.map { $0.1 } == [12, 14] && standings.map { $0.2 } == [1, 2],
                  "Correcting a completed Personal Game still replaces scores and ranks the lower total first")
    }

    private static func check(_ result: Bool, _ message: String) throws {
        guard result else { throw Failure(message: message) }
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
