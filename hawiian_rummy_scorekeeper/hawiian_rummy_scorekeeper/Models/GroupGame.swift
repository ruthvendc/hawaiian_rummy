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

enum GroupGameStatus {
    case inProgress, completed, cancelled

    var title: String {
        switch self {
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }

    var icon: String {
        switch self {
        case .inProgress: "clock"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}

struct GroupGameHeader: Equatable, Identifiable {
    let id: UUID
    let groupID: UUID
    let participants: [GroupGameParticipant]
    let creatorKey: String
    let scorekeeperKey: String
    let roundCount: Int
    let completedAt: Date?
    let cancelledAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let version: GroupGameVersion

    var status: GroupGameStatus {
        if cancelledAt != nil { return .cancelled }
        if completedAt != nil { return .completed }
        return .inProgress
    }
}

struct GroupGameScorekeeperCandidate: Identifiable {
    let id: String
    let name: String
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

    func standings(round: GroupGameRound? = nil) -> [(player: GroupGameParticipant, total: Int128, rank: Int)] {
        let hands = (round.map { [$0] } ?? rounds).flatMap(\.hands)
        let scoresByPlayer = Dictionary(grouping: hands.flatMap(\.scores), by: \.playerID)
        return GameRules.ranked(header.participants, name: \.displayName) {
            GameRules.total((scoresByPlayer[$0.playerID] ?? []).map { Int128($0.points) })
        }
    }
}

struct GroupGameRoute: Hashable {
    let group: GroupSummary
    let gameID: UUID
}

struct GroupGameSelection {
    static let minimumPlayers = 2
    private(set) var playerIDs: [UUID] = []

    var canStart: Bool { playerIDs.count >= Self.minimumPlayers }

    mutating func select(_ id: UUID, isSelected: Bool) {
        if isSelected {
            if !playerIDs.contains(id) { playerIDs.append(id) }
        } else {
            playerIDs.removeAll { $0 == id }
        }
    }

    mutating func retainActivePlayers(_ roster: [GroupPlayerIdentity]) {
        let active = Set(roster.filter { $0.retiredAt == nil }.map(\.id))
        playerIDs.removeAll { !active.contains($0) }
    }
}

// Keep the entire command, including its original version and ID, for retries.
struct GroupGameOperation: Codable {
    enum Action: Codable {
        case create(playerIDs: [UUID])
        case saveHand(round: Int, hand: GroupGameHand)
        case startNextRound
        case complete
        case reassignScorekeeper(participantKey: String)
        case cancel
        case delete

        var requiresOwner: Bool {
            switch self {
            case .reassignScorekeeper, .cancel, .delete: true
            case .create, .saveHand, .startNextRound, .complete: false
            }
        }
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
