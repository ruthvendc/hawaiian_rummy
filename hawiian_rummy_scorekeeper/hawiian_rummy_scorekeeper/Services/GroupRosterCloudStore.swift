#if DEBUG
import CloudKit
import Foundation

struct GroupRosterCloudStore: GroupRosterStore {
    let database: CKDatabase
    let root: CKRecord.ID
    let verifyAccount: () async throws -> Void
    private var zoneID: CKRecordZone.ID { root.zoneID }

    func record(for id: CKRecord.ID) async throws -> GroupRosterRecord? {
        guard id.zoneID == zoneID else { throw GroupRosterError.wrongGroup }
        do {
            return GroupRosterRecord(try await database.record(for: id))
        } catch let error as CKError where error.code == .unknownItem {
            // Only the requested child may be missing. Verify the share separately.
            return nil
        }
    }

    func records() async throws -> [GroupRosterRecord] {
        var records: [CKRecord.ID: GroupRosterRecord] = [:]
        var token: CKServerChangeToken?
        while true {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in page.modificationResultsByID {
                if case .success(let change) = result {
                    let record = change.record
                    if id.recordName.hasPrefix(GroupRoster.playerPrefix) ||
                        record.recordType == GroupRecordTypes.player || record.recordType == GroupRecordTypes.playerName {
                        guard record.recordID == id else { throw GroupRosterError.invalidRecord }
                        records[id] = GroupRosterRecord(record)
                    }
                } else if id.recordName.hasPrefix(GroupRoster.playerPrefix) {
                    _ = try result.get()
                }
            }
            for deletion in page.deletions { records.removeValue(forKey: deletion.recordID) }
            guard page.moreComing else { return Array(records.values) }
            token = page.changeToken
        }
    }

    func saveAtomically(_ records: [GroupRosterRecord]) async throws -> [CKRecord.ID: GroupRosterRecord] {
        let updates = records.map(\.record)
        guard updates.allSatisfy({ $0.recordID.zoneID == zoneID }) else { throw GroupRosterError.wrongGroup }
        guard !records.isEmpty, records.allSatisfy({ entry in
            let record = entry.record
            return record.parent?.recordID == root && entry.changeTag == record.recordChangeTag &&
                [GroupRecordTypes.player, GroupRecordTypes.playerName].contains(record.recordType)
        }) else { throw GroupRosterError.invalidRecord }
        let zone = try await database.recordZone(for: zoneID)
        guard zone.zoneID == zoneID, zone.capabilities.contains(.atomic) else {
            throw GroupRosterError.atomicUnavailable
        }
        try await verifyAccount()
        try Task.checkCancellation()
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.modifyRecords(
                saving: updates, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
            ).saveResults
        } catch {
            let partial = (error as? CKError)?.partialErrorsByItemID
            throw Self.writeFailure(partial.map { Array($0.values) } ?? [error])
        }
        let errors = results.values.compactMap { result -> (any Error)? in
            guard case .failure(let error) = result else { return nil }
            return error
        }
        if !errors.isEmpty { throw Self.writeFailure(errors) }
        var saved: [CKRecord.ID: GroupRosterRecord] = [:]
        for record in updates {
            guard let result = results[record.recordID] else {
                throw GroupRosterWriteError.unconfirmed(GroupRosterError.invalidRecord)
            }
            let confirmed = GroupRosterRecord(try result.get())
            guard confirmed.changeTag != nil else {
                throw GroupRosterWriteError.unconfirmed(GroupRosterError.invalidRecord)
            }
            saved[record.recordID] = confirmed
        }
        return saved
    }

    static func writeFailure(_ errors: [any Error]) -> any Error {
        let causes = errors.filter { ($0 as? CKError)?.code != .batchRequestFailed }
        let conflicts: Set<CKError.Code> = [.serverRecordChanged, .constraintViolation, .unknownItem]
        if !causes.isEmpty, causes.allSatisfy({ error in
            (error as? CKError).map { conflicts.contains($0.code) } == true
        }) {
            return GroupRosterWriteError.conflict
        }
        let other = causes.first { error in
            (error as? CKError).map { !conflicts.contains($0.code) } ?? true
        } ?? errors.first ?? GroupRosterError.invalidRecord
        if let cloud = other as? CKError,
           [.permissionFailure, .zoneNotFound, .participantMayNeedVerification, .notAuthenticated,
            .invalidArguments, .serverRejectedRequest, .quotaExceeded, .requestRateLimited,
            .limitExceeded, .referenceViolation, .missingEntitlement].contains(cloud.code) {
            return cloud
        }
        return GroupRosterWriteError.unconfirmed(other)
    }
}
#endif
