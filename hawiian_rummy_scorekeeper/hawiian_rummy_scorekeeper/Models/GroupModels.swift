import Foundation

struct GroupSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let zoneOwner: String
    let name: String
    let isOwner: Bool
}

// CloudKit record types used by the group repository.
enum GroupRecordTypes {
    static let group = "GroupV1"
    static let player = "GroupPlayerV1"
    static let memberDisplayName = "GroupMemberDisplayNameV1"
}

enum GroupMemberDisplayName {
    static let maximumLength = 60

    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func visibleName(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= maximumLength,
              name.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let value = trimmed(name)
        return value.isEmpty ? nil : value
    }

    static func cloudKitName(_ formattedName: String?) -> String? {
        guard let formattedName else { return nil }
        let name = trimmed(formattedName)
        guard !name.contains("@"), name.rangeOfCharacter(from: .letters) != nil,
              name.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return name
    }

    static func preferredName(custom: String?, cloudKit: String?) -> String? {
        visibleName(custom) ?? cloudKitName(cloudKit)
    }

    static func matchesRecord(
        directMatch: Bool, account: String?, creator: String?, lastEditor: String?
    ) -> Bool {
        guard let account else { return directMatch }
        guard creator == nil || creator == account, lastEditor == nil || lastEditor == account else { return false }
        return directMatch || creator == account
    }
}

struct GroupPlayerIdentity: Codable, Identifiable {
    let id: UUID
    let groupID: UUID
    let creatorUserID: String
    var displayName: String
    var retiredAt: Date?
}
