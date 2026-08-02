import Foundation
import SwiftData

@Model
final class PlayerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var retiredAt: Date?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
    }

    var isRetired: Bool { retiredAt != nil }
}

@Model
final class Game {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var completedAt: Date?
    var title: String
    var players: [PlayerProfile]
    @Relationship(deleteRule: .cascade, inverse: \GameRound.game) var rounds: [GameRound]

    init(title: String, players: [PlayerProfile]) {
        self.id = UUID()
        self.createdAt = .now
        self.title = title
        self.players = players
        self.rounds = []
    }

    var isComplete: Bool { completedAt != nil }
    var sortedRounds: [GameRound] { rounds.sorted { $0.number < $1.number } }
}

@Model
final class GameRound {
    @Attribute(.unique) var id: UUID
    var number: Int
    var createdAt: Date
    var completedAt: Date?
    var game: Game?
    @Relationship(deleteRule: .cascade, inverse: \RoundParticipant.round) var participants: [RoundParticipant]
    @Relationship(deleteRule: .cascade, inverse: \LevelResult.round) var levels: [LevelResult]

    init(number: Int, game: Game, players: [PlayerProfile]) {
        self.id = UUID()
        self.number = number
        self.createdAt = .now
        self.game = game
        self.participants = players.enumerated().map { index, player in
            RoundParticipant(player: player, displayOrder: index)
        }
        self.levels = []
    }

    var isComplete: Bool { completedAt != nil }
    var sortedLevels: [LevelResult] { levels.sorted { $0.levelNumber < $1.levelNumber } }
    var orderedParticipants: [RoundParticipant] {
        participants.sorted {
            let leftOrder = $0.displayOrder ?? Int.max
            let rightOrder = $1.displayOrder ?? Int.max
            return leftOrder == rightOrder ? $0.displayName < $1.displayName : leftOrder < rightOrder
        }
    }
}

@Model
final class RoundParticipant {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var displayOrder: Int?
    var player: PlayerProfile?
    var round: GameRound?

    init(player: PlayerProfile, displayOrder: Int) {
        self.id = UUID()
        self.displayName = player.name
        self.displayOrder = displayOrder
        self.player = player
    }
}

@Model
final class LevelResult {
    @Attribute(.unique) var id: UUID
    var levelNumber: Int
    var round: GameRound?
    @Relationship(deleteRule: .cascade, inverse: \ScoreEntry.level) var entries: [ScoreEntry]

    init(levelNumber: Int) {
        self.id = UUID()
        self.levelNumber = levelNumber
        self.entries = []
    }
}

@Model
final class ScoreEntry {
    @Attribute(.unique) var id: UUID
    var score: Int
    var participant: RoundParticipant?
    var level: LevelResult?

    init(score: Int, participant: RoundParticipant) {
        self.id = UUID()
        self.score = score
        self.participant = participant
    }
}
