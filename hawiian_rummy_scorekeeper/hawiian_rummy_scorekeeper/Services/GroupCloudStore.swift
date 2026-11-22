#if DEBUG
import CloudKit
import Foundation

enum GroupCloudStoreError: LocalizedError {
    case wrongZone, invalidBatch, atomicUnavailable

    var errorDescription: String? {
        switch self {
        case .wrongZone: "The record belongs to a different group zone."
        case .invalidBatch: "The group write contains an invalid record."
        case .atomicUnavailable: "CloudKit does not report atomic write support for this group’s zone."
        }
    }
}

struct GroupStoredRecord {
    let record: CKRecord
    let changeTag: String?

    init(_ record: CKRecord, changeTag: String? = nil) {
        self.record = record
        self.changeTag = changeTag ?? record.recordChangeTag
    }
}

enum GroupAtomicWriteError: LocalizedError {
    case conflict
    case unconfirmed(any Error)

    var errorDescription: String? {
        switch self {
        case .conflict: "This data changed on another device. Refresh and review your change."
        case .unconfirmed(let error):
            "Couldn’t confirm the save. Refresh before trying again. \(error.localizedDescription)"
        }
    }
}

protocol GroupRecordStore {
    func record(for id: CKRecord.ID) async throws -> GroupStoredRecord?
    func saveAtomically(_ records: [GroupStoredRecord]) async throws -> [CKRecord.ID: GroupStoredRecord]
}

/// Same-zone conditional transport. The caller validates the record types and parent hierarchy.
struct GroupCloudStore: GroupRecordStore {
    let database: CKDatabase
    let zoneID: CKRecordZone.ID
    let verifyAccount: () async throws -> Void

    func record(for id: CKRecord.ID) async throws -> GroupStoredRecord? {
        guard id.zoneID == zoneID else { throw GroupCloudStoreError.wrongZone }
        do {
            return GroupStoredRecord(try await database.record(for: id))
        } catch let error as CKError where error.code == .unknownItem {
            // Only the requested child may be missing. Verify the share separately.
            return nil
        }
    }

    func saveAtomically(_ records: [GroupStoredRecord]) async throws -> [CKRecord.ID: GroupStoredRecord] {
        try await modifyAtomically(records, deleting: [], checking: nil)
    }

    func saveManagement(
        _ records: [GroupStoredRecord], deleting ids: [CKRecord.ID], checking share: GroupStoredRecord
    ) async throws -> [CKRecord.ID: GroupStoredRecord] {
        guard database.databaseScope == .private,
              let shareRecord = share.record as? CKShare, shareRecord.currentUserParticipant?.role == .owner,
              shareRecord.publicPermission == .none,
              share.changeTag != nil else { throw GroupRosterError.notAuthorized }
        return try await modifyAtomically(records, deleting: ids, checking: share)
    }

    private func modifyAtomically(
        _ records: [GroupStoredRecord], deleting ids: [CKRecord.ID], checking share: GroupStoredRecord?
    ) async throws -> [CKRecord.ID: GroupStoredRecord] {
        let entries = records + (share.map { [$0] } ?? [])
        let updates = entries.map(\.record)
        let changedIDs = updates.map(\.recordID) + ids
        guard changedIDs.allSatisfy({ $0.zoneID == zoneID }) else { throw GroupCloudStoreError.wrongZone }
        guard !records.isEmpty, Set(changedIDs).count == changedIDs.count,
              records.allSatisfy({ $0.record.parent?.recordID.zoneID == zoneID }),
              entries.allSatisfy({ $0.changeTag == $0.record.recordChangeTag }) else {
            throw GroupCloudStoreError.invalidBatch
        }
        let zone = try await database.recordZone(for: zoneID)
        guard zone.zoneID == zoneID, zone.capabilities.contains(.atomic) else {
            throw GroupCloudStoreError.atomicUnavailable
        }
        try await verifyAccount()
        try Task.checkCancellation()
        let saves: [CKRecord.ID: Result<CKRecord, any Error>]
        let deletions: [CKRecord.ID: Result<Void, any Error>]
        do {
            (saves, deletions) = try await database.modifyRecords(
                saving: updates, deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: true
            )
        } catch {
            let partial = (error as? CKError)?.partialErrorsByItemID
            throw Self.writeFailure(partial.map { Array($0.values) } ?? [error])
        }
        let errors = saves.values.compactMap(Self.failure) + deletions.values.compactMap(Self.failure)
        if !errors.isEmpty { throw Self.writeFailure(errors) }
        guard ids.allSatisfy({ deletions[$0] != nil }) else {
            throw GroupAtomicWriteError.unconfirmed(GroupCloudStoreError.invalidBatch)
        }
        var saved: [CKRecord.ID: GroupStoredRecord] = [:]
        for record in updates {
            guard let result = saves[record.recordID] else {
                throw GroupAtomicWriteError.unconfirmed(GroupCloudStoreError.invalidBatch)
            }
            let confirmed = GroupStoredRecord(try result.get())
            guard confirmed.changeTag != nil else {
                throw GroupAtomicWriteError.unconfirmed(GroupCloudStoreError.invalidBatch)
            }
            saved[record.recordID] = confirmed
        }
        return saved
    }

    private static func failure<Value>(_ result: Result<Value, any Error>) -> (any Error)? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    static func writeFailure(_ errors: [any Error]) -> any Error {
        let causes = errors.filter { ($0 as? CKError)?.code != .batchRequestFailed }
        let conflicts: Set<CKError.Code> = [.serverRecordChanged, .constraintViolation, .unknownItem]
        if !causes.isEmpty, causes.allSatisfy({ error in
            (error as? CKError).map { conflicts.contains($0.code) } == true
        }) {
            return GroupAtomicWriteError.conflict
        }
        let other = causes.first { error in
            (error as? CKError).map { !conflicts.contains($0.code) } ?? true
        } ?? errors.first ?? GroupCloudStoreError.invalidBatch
        if let cloud = other as? CKError,
           [.permissionFailure, .zoneNotFound, .participantMayNeedVerification, .notAuthenticated,
            .invalidArguments, .serverRejectedRequest, .quotaExceeded, .requestRateLimited,
            .limitExceeded, .referenceViolation, .missingEntitlement].contains(cloud.code) {
            return cloud
        }
        return GroupAtomicWriteError.unconfirmed(other)
    }
}
#endif
