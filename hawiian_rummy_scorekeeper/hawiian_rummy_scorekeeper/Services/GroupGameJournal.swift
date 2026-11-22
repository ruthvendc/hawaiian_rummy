#if DEBUG
import Foundation
import SwiftData

@Model
final class GroupGameJournalRecord {
    @Attribute(.unique) var key: String
    var namespace: String
    var payload: Data

    init(key: String, namespace: String, payload: Data) {
        self.key = key
        self.namespace = namespace
        self.payload = payload
    }
}

enum GroupGameJournalError: LocalizedError, Equatable {
    case unavailable, staleEditor, invalidEntry

    var errorDescription: String? {
        switch self {
        case .unavailable: "Couldn’t open saved scoring on this iPhone."
        case .staleEditor: "This scorecard changed. Review the latest scores before saving."
        case .invalidEntry: "Couldn’t read saved scoring for this game."
        }
    }
}

@MainActor
final class GroupGameJournal {
    struct Namespace: Codable, Equatable {
        let account: String
        let container: String
        let environment: String
    }

    struct Scope: Codable, Equatable {
        let namespace: Namespace
        let groupID: UUID
        let zoneOwner: String
        let isOwner: Bool
        let gameID: UUID

        init(namespace: Namespace, route: GroupGameRoute) {
            self.namespace = namespace
            groupID = route.group.id
            zoneOwner = route.group.zoneOwner
            isOwner = route.group.isOwner
            gameID = route.gameID
        }

        func matches(_ group: GroupSummary) -> Bool {
            groupID == group.id && zoneOwner == group.zoneOwner && isOwner == group.isOwner
        }
    }

    struct Operation: Codable {
        enum State: Codable, Equatable {
            case pendingSync, pendingConfirmation, synced(revision: Int), needsReview
        }

        let request: GroupGameOperation
        let sequence: Int
        let roundNumber: Int
        let createdAt: Date
        var state: State
    }

    struct Entry: Codable {
        let scope: Scope
        var formatVersion = 1
        var confirmed: GroupGameSnapshot
        var access: GroupRosterAccess
        var isEligible: Bool
        var editID = UUID()
        var lastSequence = 0
        var operations: [Operation] = []

        var canResume: Bool { isEligible && (confirmed.header.status == .inProgress || !operations.isEmpty) }
        var needsReview: Bool { operations.contains { $0.state == .needsReview } }
        var syncStatus: String {
            if needsReview { return "Needs review · Local scores kept on this iPhone" }
            let pendingConfirmation = operations.first?.state == .pendingConfirmation
            if operations.contains(where: { $0.state == .pendingSync }) {
                return pendingConfirmation ? "Pending confirmation · More scores saved on this iPhone" : "Saved on this iPhone · Pending sync"
            }
            return pendingConfirmation ? "Saved on this iPhone · Pending confirmation" : "Synced"
        }

        func scorecard() throws -> GroupGameSnapshot {
            var projected = confirmed
            for operation in operations {
                try GroupGameScoringTransition.apply(operation.request.action, to: &projected, at: operation.createdAt)
            }
            return projected
        }

        mutating func flagUnsentOperations(preserveConfirmation: Bool = false) {
            for index in operations.indices {
                switch operations[index].state {
                case .pendingSync: operations[index].state = .needsReview
                case .pendingConfirmation where !preserveConfirmation: operations[index].state = .needsReview
                case .pendingConfirmation, .synced, .needsReview: break
                }
            }
        }
    }

    struct ResumeItem: Identifiable {
        let route: GroupGameRoute
        let header: GroupGameHeader
        let syncStatus: String

        var id: GroupGameRoute { route }
    }

    struct Game {
        let store: GroupGameJournal
        let scope: Scope

        func load() throws -> Entry? {
            try store.load(scope)
        }

        func recordConfirmed(_ snapshot: GroupGameSnapshot, access: GroupRosterAccess) throws -> Entry? {
            guard snapshot.header.id == scope.gameID, snapshot.header.groupID == scope.groupID else {
                throw GroupGameJournalError.invalidEntry
            }
            let assigned = access.canAdd && access.isScorekeeper(snapshot.header.scorekeeperKey)
            let eligible = snapshot.header.status == .inProgress && assigned
            return try store.update(scope) { previous in
                guard var entry = previous else {
                    return eligible ? Entry(scope: scope, confirmed: snapshot, access: access, isEligible: true) : nil
                }
                guard snapshot.header.version.revision >= entry.confirmed.header.version.revision else { return nil }
                if let head = entry.operations.first, case .synced(let revision) = head.state,
                   snapshot.header.version.revision >= revision {
                    if entry.operations.count == 1 || snapshot.header.version.revision == revision {
                        entry.operations.removeFirst()
                        entry.confirmed = snapshot
                    } else {
                        // Keep the original base and queued suffix if another writer advanced past the receipt.
                        entry.flagUnsentOperations()
                    }
                }
                if entry.operations.isEmpty {
                    if entry.confirmed == snapshot, entry.access == access, entry.isEligible == eligible,
                       previous?.operations.isEmpty == true { return nil }
                    entry.confirmed = snapshot
                    entry.access = access
                    entry.isEligible = eligible
                    return entry
                }
                let shouldFlag = !eligible || (entry.operations.first?.state == .pendingSync &&
                                               entry.confirmed.header.version != snapshot.header.version)
                if shouldFlag {
                    // A terminal snapshot can be the result of the very request we still need to confirm.
                    entry.flagUnsentOperations(preserveConfirmation: assigned)
                }
                entry.isEligible = eligible
                if previous?.isEligible == entry.isEligible, previous?.confirmed == entry.confirmed,
                   previous?.operations.map(\.state) == entry.operations.map(\.state) { return nil }
                return entry
            }
        }

        func append(_ action: GroupGameOperation.Action, editID: UUID, submitImmediately: Bool) throws -> Entry {
            let saved = try store.update(scope) { previous in
                guard var entry = previous, entry.editID == editID else { throw GroupGameJournalError.staleEditor }
                guard entry.canResume, !entry.needsReview else { throw GroupGameError.invalidTransition }
                let now = Date.now
                var projected = try entry.scorecard()
                try GroupGameScoringTransition.apply(action, to: &projected, at: now)
                let sendNow = submitImmediately && entry.operations.isEmpty
                entry.lastSequence += 1
                let request = GroupGameOperation(id: UUID(), groupID: scope.groupID, gameID: scope.gameID,
                                                 expectedVersion: sendNow ? entry.confirmed.header.version : nil,
                                                 action: action)
                let roundNumber: Int
                if case .saveHand(let target, _) = action { roundNumber = target } else { roundNumber = projected.header.roundCount }
                entry.operations.append(Operation(request: request, sequence: entry.lastSequence, roundNumber: roundNumber, createdAt: now,
                                                  state: sendNow ? .pendingConfirmation : .pendingSync))
                return entry
            }
            guard let saved else { throw GroupGameJournalError.invalidEntry }
            return saved
        }

        func acknowledge(_ receipt: GroupGameReceipt) throws -> Entry? {
            try store.update(scope) { previous in
                guard var entry = previous, let head = entry.operations.first, head.request.id == receipt.operationID,
                      receipt.gameID == scope.gameID, head.state == .pendingConfirmation,
                      let version = head.request.expectedVersion, receipt.revision > version.revision,
                      receipt.revision - version.revision == 1 else { return nil }
                entry.operations[0].state = .synced(revision: receipt.revision)
                return entry
            }
        }

        func flagForReview(operationID: UUID? = nil, hide: Bool = false) throws -> Entry? {
            try store.update(scope) { previous in
                guard var entry = previous else { return nil }
                if let operationID {
                    guard let head = entry.operations.first, head.request.id == operationID,
                          head.state == .pendingConfirmation else { return nil }
                }
                entry.flagUnsentOperations()
                if hide { entry.isEligible = false }
                if previous?.isEligible == entry.isEligible,
                   previous?.operations.map(\.state) == entry.operations.map(\.state) { return nil }
                return entry
            }
        }
    }

    private let container: ModelContainer
    private let save: (ModelContext) throws -> Void

    init(url: URL? = nil, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        let schema = Schema([GroupGameJournalRecord.self])
        let configuration = if let url {
            ModelConfiguration("GroupGameJournal", schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            ModelConfiguration("GroupGameJournal", schema: schema, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, configurations: configuration)
        self.save = save
    }

    func entries(in namespace: Namespace) throws -> [Entry] {
        let key = try Self.key(for: namespace)
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<GroupGameJournalRecord>(predicate: #Predicate { $0.namespace == key }))
        return try records.map { record in
            let entry = try JSONDecoder().decode(Entry.self, from: record.payload)
            guard entry.formatVersion == 1, entry.scope.namespace == namespace else { throw GroupGameJournalError.invalidEntry }
            return entry
        }
    }

    private func load(_ scope: Scope) throws -> Entry? {
        try decode(record(for: Self.key(for: scope), in: ModelContext(container)), scope: scope)
    }

    private func update(_ scope: Scope, apply: (Entry?) throws -> Entry?) throws -> Entry? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let key = try Self.key(for: scope)
        let record = try record(for: key, in: context)
        let previous = try decode(record, scope: scope)
        guard var entry = try apply(previous) else { return previous }
        entry.editID = UUID()
        let payload = try JSONEncoder().encode(entry)
        if let record {
            record.payload = payload
        } else {
            context.insert(GroupGameJournalRecord(key: key, namespace: try Self.key(for: scope.namespace), payload: payload))
        }
        try save(context)
        return entry
    }

    private func record(for key: String, in context: ModelContext) throws -> GroupGameJournalRecord? {
        var descriptor = FetchDescriptor<GroupGameJournalRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func decode(_ record: GroupGameJournalRecord?, scope: Scope) throws -> Entry? {
        guard let record else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: record.payload)
        guard entry.formatVersion == 1, entry.scope == scope, entry.confirmed.header.id == scope.gameID,
              entry.confirmed.header.groupID == scope.groupID else { throw GroupGameJournalError.invalidEntry }
        return entry
    }

    private static func key(for value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return GroupRoster.digest(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
#endif
