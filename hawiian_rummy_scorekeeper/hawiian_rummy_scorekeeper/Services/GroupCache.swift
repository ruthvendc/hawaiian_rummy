#if DEBUG
import Foundation
import SwiftData

struct GroupCacheSnapshot: Codable, Equatable {
    var groups: [GroupSummary] = []
    var pendingLinks: [URL] = []
    // Optional so previously saved snapshots decode without a migration.
    var memberNameDrafts: [UUID: String]?
    var groupDetails: [UUID: CachedGroupDetails]?
    var groupRosters: [UUID: CachedGroupRoster]?
}

struct CachedGroupRoster: Codable, Equatable {
    struct Player: Codable, Equatable, Identifiable {
        let id: UUID
        let displayName: String
        let isRetired: Bool

        init(_ player: GroupPlayerIdentity) {
            id = player.id
            displayName = player.displayName
            isRetired = player.retiredAt != nil
        }
    }

    let zoneOwner: String
    var players: [Player]
}

// Display-only data. Cached membership never supplies CloudKit authorization or actions.
struct CachedGroupDetails: Codable, Equatable {
    struct Member: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let role: String?
    }

    let members: [Member]
    let savedAt: Date
}

@Model
final class GroupAccountCache {
    var accountID: String
    var payload: Data

    init(accountID: String, payload: Data) {
        self.accountID = accountID
        self.payload = payload
    }
}

struct GroupCache {
    private let container: ModelContainer

    init(url: URL? = nil) throws {
        let schema = Schema([GroupAccountCache.self])
        let configuration = if let url {
            ModelConfiguration("GroupsCache", schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            ModelConfiguration("GroupsCache", schema: schema, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: configuration)
    }

    func load(account: String) throws -> GroupCacheSnapshot {
        let context = ModelContext(container)
        guard let entry = try entry(for: account, in: context) else { return GroupCacheSnapshot() }
        return try JSONDecoder().decode(GroupCacheSnapshot.self, from: entry.payload)
    }

    func save(_ snapshot: GroupCacheSnapshot, account: String) throws {
        let context = ModelContext(container)
        let data = try JSONEncoder().encode(snapshot)
        if let entry = try entry(for: account, in: context) {
            entry.payload = data
        } else {
            context.insert(GroupAccountCache(accountID: account, payload: data))
        }
        try context.save()
    }

    private func entry(for account: String, in context: ModelContext) throws -> GroupAccountCache? {
        var descriptor = FetchDescriptor<GroupAccountCache>(predicate: #Predicate { $0.accountID == account })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
#endif
