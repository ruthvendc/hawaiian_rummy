#if DEBUG
import CloudKit
import Foundation

struct GroupRosterCloudStore: GroupRosterStore {
    let database: CKDatabase
    let root: CKRecord.ID
    let verifyAccount: () async throws -> Void
    private var zoneID: CKRecordZone.ID { root.zoneID }

    private var cloud: GroupCloudStore {
        GroupCloudStore(database: database, zoneID: zoneID, verifyAccount: verifyAccount)
    }

    func record(for id: CKRecord.ID) async throws -> GroupStoredRecord? {
        guard id.zoneID == zoneID else { throw GroupRosterError.wrongGroup }
        return try await cloud.record(for: id)
    }

    func records() async throws -> [GroupStoredRecord] {
        var records: [CKRecord.ID: GroupStoredRecord] = [:]
        var token: CKServerChangeToken?
        while true {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in page.modificationResultsByID {
                if case .success(let change) = result {
                    let record = change.record
                    if id.recordName.hasPrefix(GroupRoster.playerPrefix) ||
                        record.recordType == GroupRecordTypes.player || record.recordType == GroupRecordTypes.playerName {
                        guard record.recordID == id else { throw GroupRosterError.invalidRecord }
                        records[id] = GroupStoredRecord(record)
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

    func saveAtomically(_ records: [GroupStoredRecord]) async throws -> [CKRecord.ID: GroupStoredRecord] {
        guard records.allSatisfy({ $0.record.recordID.zoneID == zoneID }) else { throw GroupRosterError.wrongGroup }
        guard records.allSatisfy({ entry in
            entry.record.parent?.recordID == root &&
                [GroupRecordTypes.player, GroupRecordTypes.playerName].contains(entry.record.recordType)
        }) else { throw GroupRosterError.invalidRecord }
        do {
            return try await cloud.saveAtomically(records)
        } catch GroupCloudStoreError.atomicUnavailable {
            throw GroupRosterError.atomicUnavailable
        } catch GroupCloudStoreError.invalidBatch {
            throw GroupRosterError.invalidRecord
        }
    }
}
#endif
