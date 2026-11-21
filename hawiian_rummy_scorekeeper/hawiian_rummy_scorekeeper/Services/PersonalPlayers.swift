import Foundation
import SwiftData

@MainActor
enum PersonalPlayers {
    enum NameStatus {
        case empty, available, activeMatch, retiredMatch
    }

    enum Issue: LocalizedError {
        case emptyName, activeName, retiredName, restoreConflict, duplicateRestoreNames, missingPlayer, alreadyRestored

        var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a name for this player."
            case .activeName: "An active player already has this name. Choose a different name."
            case .retiredName: "A removed player already has this name. Restore that profile or choose a different name."
            case .restoreConflict:
                "An active player already has this name. In Players → Restore Players, use Rename Player on the retired profile, then try again."
            case .duplicateRestoreNames:
                "Selected players share a name. Rename the retired profiles to distinct names before restoring them together."
            case .missingPlayer: "This player is no longer available. Reopen Players and try again."
            case .alreadyRestored: "This player is already active."
            }
        }
    }

    static func nameKey(_ name: String) -> String {
        PlayerName.comparisonKey(name)
    }

    static func nameStatus(for name: String, in players: [PlayerProfile]) -> NameStatus {
        let key = nameKey(name)
        guard !key.isEmpty else { return .empty }
        let matches = players.filter { nameKey($0.name) == key }
        if matches.contains(where: { !$0.isRetired }) { return .activeMatch }
        return matches.isEmpty ? .available : .retiredMatch
    }

    static func conflictingNames(in players: [PlayerProfile]) -> Set<String> {
        let byName = Dictionary(grouping: players) { nameKey($0.name) }
        return Set(byName.keys.filter { !$0.isEmpty && (byName[$0]?.count ?? 0) > 1 })
    }

    static func add(_ name: String, in context: ModelContext) throws -> PlayerProfile {
        try validate(name, against: roster(in: context))
        let player = PlayerProfile(name: PlayerName.trimmed(name))
        context.insert(player)
        do {
            try context.save()
            return player
        } catch {
            context.delete(player)
            throw error
        }
    }

    static func rename(_ player: PlayerProfile, to name: String, whileRetired: Bool = false, in context: ModelContext) throws {
        let players = try roster(in: context)
        let profile = try currentProfile(player, in: players)
        if whileRetired && !profile.isRetired { throw Issue.alreadyRestored }
        let newName = PlayerName.trimmed(name)
        guard profile.name != newName else { return }
        try validate(newName, against: players.filter { $0.persistentModelID != profile.persistentModelID })
        let previous = profile.name
        profile.name = newName
        do {
            try context.save()
        } catch {
            profile.name = previous
            throw error
        }
    }

    static func retire(_ player: PlayerProfile, in context: ModelContext) throws {
        let profile = try currentProfile(player, in: roster(in: context))
        guard !profile.isRetired else { return }
        try setRetirement(.now, for: profile, in: context)
    }

    static func restore(_ player: PlayerProfile, in context: ModelContext) throws -> PlayerProfile {
        let players = try roster(in: context)
        let profile = try currentProfile(player, in: players)
        try restoreProfiles([profile], from: players, in: context)
        return profile
    }

    static func restore(_ selection: [PlayerProfile], in context: ModelContext) throws -> [PlayerProfile] {
        let players = try roster(in: context)
        let profiles = try selection.map { try currentProfile($0, in: players) }
        try restoreProfiles(profiles, from: players, in: context)
        return profiles
    }

    private static func restoreProfiles(_ profiles: [PlayerProfile], from players: [PlayerProfile], in context: ModelContext) throws {
        guard !profiles.isEmpty else { return }
        let activeNames = Set(players.filter { !$0.isRetired }.map { nameKey($0.name) })
        var selectedNames: Set<String> = []
        for profile in profiles {
            guard profile.isRetired else { throw Issue.alreadyRestored }
            let key = nameKey(profile.name)
            guard !key.isEmpty else { throw Issue.emptyName }
            guard !activeNames.contains(key) else { throw Issue.restoreConflict }
            guard selectedNames.insert(key).inserted else { throw Issue.duplicateRestoreNames }
        }
        let previous = profiles.map { ($0, $0.retiredAt) }
        profiles.forEach { $0.retiredAt = nil }
        do {
            try context.save()
        } catch {
            for (profile, date) in previous { profile.retiredAt = date }
            throw error
        }
    }

    private static func validate(_ name: String, against players: [PlayerProfile]) throws {
        switch nameStatus(for: name, in: players) {
        case .empty: throw Issue.emptyName
        case .activeMatch: throw Issue.activeName
        case .retiredMatch: throw Issue.retiredName
        case .available: break
        }
    }

    private static func roster(in context: ModelContext) throws -> [PlayerProfile] {
        try context.fetch(FetchDescriptor<PlayerProfile>())
    }

    private static func currentProfile(_ player: PlayerProfile, in roster: [PlayerProfile]) throws -> PlayerProfile {
        guard let profile = roster.first(where: { $0.persistentModelID == player.persistentModelID }) else {
            throw Issue.missingPlayer
        }
        return profile
    }

    private static func setRetirement(_ date: Date?, for player: PlayerProfile, in context: ModelContext) throws {
        let previous = player.retiredAt
        player.retiredAt = date
        do {
            try context.save()
        } catch {
            player.retiredAt = previous
            throw error
        }
    }
}
