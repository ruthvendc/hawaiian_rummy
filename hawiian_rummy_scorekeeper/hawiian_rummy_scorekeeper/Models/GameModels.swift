import Foundation
import SwiftData

@Model
final class PlayerProfile {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    var retiredAt: Date?
    var displayOrder: Int?
    @Relationship(inverse: \Game.players) var games: [Game]?
    @Relationship(inverse: \RoundParticipant.player) var roundParticipants: [RoundParticipant]?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.displayOrder = nil
    }

    var isRetired: Bool { retiredAt != nil }

    static func orderedActivePlayers(_ players: [PlayerProfile]) -> [PlayerProfile] {
        players.filter { !$0.isRetired }.sorted { left, right in
            let leftOrder = left.displayOrder ?? Int.max
            let rightOrder = right.displayOrder ?? Int.max
            return leftOrder == rightOrder ? left.name < right.name : leftOrder < rightOrder
        }
    }
}

@Model
final class Game {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var completedAt: Date?
    var title: String = ""
    var players: [PlayerProfile]?
    @Relationship(deleteRule: .cascade, inverse: \GameRound.game) var rounds: [GameRound]?

    init(title: String, players: [PlayerProfile]) {
        self.id = UUID()
        self.createdAt = .now
        self.title = title
        self.players = players
        self.rounds = []
    }

    var isComplete: Bool { completedAt != nil }
    var sortedRounds: [GameRound] { (rounds ?? []).sorted { $0.number < $1.number } }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter.string(from: date)
    }

    static func nextDefaultTitle(for date: Date, existingTitles: [String]) -> String {
        let baseTitle = defaultTitle(for: date)
        let numberedPrefix = "\(baseTitle) · Game "
        let highestNumber = existingTitles.compactMap { title -> Int? in
            if title == baseTitle { return 1 }
            guard title.hasPrefix(numberedPrefix),
                  let number = Int(title.dropFirst(numberedPrefix.count)),
                  number >= 2 else { return nil }
            return number
        }.max()

        guard let highestNumber else { return baseTitle }
        return "\(numberedPrefix)\(highestNumber + 1)"
    }
}

@Model
final class GameRound {
    var id: UUID = UUID()
    var number: Int = 0
    var createdAt: Date = Date.now
    var completedAt: Date?
    var game: Game?
    @Relationship(deleteRule: .cascade, inverse: \RoundParticipant.round) var participants: [RoundParticipant]?
    @Relationship(deleteRule: .cascade, inverse: \LevelResult.round) var levels: [LevelResult]?

    init(number: Int, game: Game, players: [PlayerProfile]) {
        self.id = UUID()
        self.number = number
        self.createdAt = .now
        self.game = game
        self.participants = players.enumerated().map { index, player in
            RoundParticipant(player: player, displayOrder: index)
        }
        self.levels = []
        self.participants?.forEach { $0.round = self }
    }

    var isComplete: Bool { completedAt != nil }
    var sortedLevels: [LevelResult] { (levels ?? []).sorted { $0.levelNumber < $1.levelNumber } }
    var orderedParticipants: [RoundParticipant] {
        (participants ?? []).sorted {
            let leftOrder = $0.displayOrder ?? Int.max
            let rightOrder = $1.displayOrder ?? Int.max
            return leftOrder == rightOrder ? $0.displayName < $1.displayName : leftOrder < rightOrder
        }
    }
}

@Model
final class RoundParticipant {
    var id: UUID = UUID()
    var displayName: String = ""
    var displayOrder: Int?
    var player: PlayerProfile?
    var round: GameRound?
    @Relationship(inverse: \ScoreEntry.participant) var scoreEntries: [ScoreEntry]?

    init(player: PlayerProfile, displayOrder: Int) {
        self.id = UUID()
        self.displayName = player.name
        self.displayOrder = displayOrder
        self.player = player
    }
}

@Model
final class LevelResult {
    var id: UUID = UUID()
    var levelNumber: Int = 0
    var round: GameRound?
    @Relationship(deleteRule: .cascade, inverse: \ScoreEntry.level) var entries: [ScoreEntry]?

    init(levelNumber: Int) {
        self.id = UUID()
        self.levelNumber = levelNumber
        self.entries = []
    }
}

@Model
final class ScoreEntry {
    var id: UUID = UUID()
    var score: Int = 0
    var participant: RoundParticipant?
    var level: LevelResult?

    init(score: Int, participant: RoundParticipant) {
        self.id = UUID()
        self.score = score
        self.participant = participant
    }
}
