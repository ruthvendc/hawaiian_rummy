#if DEBUG
import Foundation

struct GroupGameParticipant: Codable, Equatable {
    let playerID: UUID
    let displayName: String
}

struct GroupGameHand: Codable, Equatable {
    struct Score: Codable, Equatable {
        let playerID: UUID
        let points: Int
    }

    let number: Int
    let scores: [Score]

    init(number: Int, scores: [UUID: Int]) {
        self.number = number
        self.scores = scores.map { Score(playerID: $0.key, points: $0.value) }
            .sorted { $0.playerID.uuidString < $1.playerID.uuidString }
    }
}

struct GroupGameVersion: Codable, Equatable {
    let revision: Int
    let changeTag: String
}

struct GroupGameHeader: Equatable, Identifiable {
    let id: UUID
    let groupID: UUID
    let participants: [GroupGameParticipant]
    let creatorKey: String
    let scorekeeperKey: String
    let roundCount: Int
    let completedAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let version: GroupGameVersion
}

struct GroupGameRound: Equatable, Identifiable {
    struct ID: Hashable {
        let gameID: UUID
        let number: Int
    }

    let id: ID
    let hands: [GroupGameHand]
}

struct GroupGameSnapshot: Equatable {
    let header: GroupGameHeader
    let rounds: [GroupGameRound]
}

// Keep the entire command, including its original version and ID, for retries.
struct GroupGameOperation: Codable {
    enum Action: Codable {
        case create(playerIDs: [UUID])
        case saveHand(round: Int, hand: GroupGameHand)
        case startNextRound
        case complete
    }

    let id: UUID
    let groupID: UUID
    let gameID: UUID
    let expectedVersion: GroupGameVersion?
    let action: Action

    static func create(groupID: UUID, gameID: UUID, playerIDs: [UUID]) -> Self {
        Self(id: gameID, groupID: groupID, gameID: gameID, expectedVersion: nil, action: .create(playerIDs: playerIDs))
    }
}

// A receipt confirms one operation. Fetch a fresh snapshot to display current scores.
struct GroupGameReceipt: Equatable {
    let operationID: UUID
    let gameID: UUID
    let revision: Int
}
#endif
