#if DEBUG
import CloudKit
import Observation
import UIKit

@MainActor
@Observable
final class CloudKitProbe {
    static let shared = CloudKitProbe()

    private static let zonePrefix = "RummyShareProbe-"
    private static let rootName = "probe-group"
    private let containerID = hawiian_rummy_scorekeeperApp.cloudKitContainerID
    @ObservationIgnored private lazy var container = CKContainer(identifier: containerID)

    var isPresented = false
    var inviteText = ""
    private(set) var status = "Ready"
    private(set) var isBusy = false
    private(set) var ownedShare: CKShare?
    private(set) var ownedRootID: CKRecord.ID?
    private(set) var joinedRootID: CKRecord.ID?
    private var deliveredInvitation: CKShare.Metadata?
    var hasOpenedInvitation: Bool { deliveredInvitation != nil }

    private init() {}

    func checkAccount() async {
        await run("Check iCloud") {
            let account = try await container.accountStatus()
            status = account == .available ? "iCloud account available" : "iCloud unavailable (status \(account.rawValue))"
        }
    }

    func createGroup() async {
        await run("Create private group") {
            let database = container.privateCloudDatabase
            let zone = CKRecordZone(zoneName: Self.zonePrefix + UUID().uuidString)
            let root = CKRecord(
                recordType: "RummyShareProbeGroup",
                recordID: CKRecord.ID(recordName: Self.rootName, zoneID: zone.zoneID)
            )
            root["message"] = "Owner created this test group"
            let share = CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = "Rummy sharing test"
            share.publicPermission = .none
            share.allowsAccessRequests = true

            _ = try await database.save(zone)
            ownedRootID = root.recordID
            let result = try await database.modifyRecords(saving: [root, share], deleting: [])
            guard let savedRoot = result.saveResults[root.recordID],
                  let savedShare = try result.saveResults[share.recordID]?.get() as? CKShare,
                  savedShare.url != nil, savedShare.publicPermission == .none, savedShare.allowsAccessRequests else {
                throw ProbeError("CloudKit did not return a private share with an access request link.")
            }
            _ = try savedRoot.get()
            ownedShare = savedShare
            status = "Private group created. Share its link to request access."
        }
    }

    func refreshOwnerShare() async {
        await run("Refresh requests and members") {
            guard let id = ownedShare?.recordID else { return }
            ownedShare = try await fetchShare(id)
            status = "Refreshed. Pending requests: \(ownedShare?.requesters.count ?? 0)."
        }
    }

    func approve(_ requester: CKShare.AccessRequester) async {
        await updateShare("Approve request", success: "Approved. The recipient can now accept the invitation.") { share in
            let lookup = requester.participantLookupInfo
            let results = try await container.shareParticipants(for: [lookup])
            guard let result = results[lookup] else { throw ProbeError("No participant returned for this requester.") }
            let participant = try result.get()
            participant.role = .privateUser
            participant.permission = .readWrite
            share.addParticipant(participant)
        }
    }

    func revoke(_ participant: CKShare.Participant) async {
        await updateShare("Revoke access", success: "Membership revoked. Test again from the other iPhone.") { share in
            share.removeParticipant(participant)
        }
    }

    func requestAccess() async {
        await run("Request access") {
            let url = try invitationURL()
            let results = try await container.requestShareAccess(for: [url])
            guard let result = results[url] else { throw ProbeError("CloudKit returned no request result.") }
            try result.get()
            status = "Request submitted. Ask the owner to refresh and approve it."
        }
    }

    func acceptPastedLink() async {
        await run("Accept pasted link") {
            let url = try invitationURL()
            let metadata = try await container.shareMetadata(for: url)
            try await accept(metadata, source: "Pasted link")
        }
    }

    func receive(_ metadata: CKShare.Metadata) {
        guard (try? probeRootID(for: metadata)) != nil else { return }
        deliveredInvitation = metadata
        isPresented = true
    }

    func acceptDeliveredInvitation() async {
        guard let metadata = deliveredInvitation else { return }
        await run("Accept opened invitation") {
            try await accept(metadata, source: "Opened link")
            deliveredInvitation = nil
        }
    }

    func readGroup(asOwner: Bool) async {
        await run(asOwner ? "Owner read" : "Member read") {
            let id = try rootID(asOwner: asOwner)
            let database = asOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
            let root = try await database.record(for: id)
            let message = root["message"] as? String ?? "(missing test message)"
            status = "CloudKit read succeeded. \(message)."
        }
    }

    func writeAsMember() async {
        await run("Member write") {
            let id = try rootID(asOwner: false)
            let child = CKRecord(
                recordType: "RummyShareProbeWrite",
                recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: id.zoneID)
            )
            child.setParent(id)
            child["message"] = "Member wrote to the shared group"
            let saved = try await container.sharedCloudDatabase.save(child)
            status = "CloudKit write succeeded. Record ID: \(saved.recordID.recordName)"
        }
    }

    func readMemberWrite(_ recordName: String) async {
        await run("Owner read member write") {
            let root = try rootID(asOwner: true)
            let name = recordName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: name) else { throw ProbeError("Paste the member’s write record ID.") }
            let id = CKRecord.ID(recordName: uuid.uuidString, zoneID: root.zoneID)
            let record = try await container.privateCloudDatabase.record(for: id)
            guard record.recordType == "RummyShareProbeWrite", record.parent?.recordID == root else {
                throw ProbeError("The record is outside this probe group.")
            }
            let message = record["message"] as? String ?? "(missing test message)"
            status = "CloudKit read succeeded. \(message)."
        }
    }

    func deleteGroup() async {
        await run("Delete test group") {
            let id = try rootID(asOwner: true)
            _ = try await container.privateCloudDatabase.deleteRecordZone(withID: id.zoneID)
            ownedShare = nil
            ownedRootID = nil
            status = "Deleted the test zone."
        }
    }

    private func accept(_ metadata: CKShare.Metadata, source: String) async throws {
        let id = try probeRootID(for: metadata)
        switch metadata.participantStatus {
        case .pending:
            _ = try await container.accept(metadata)
        case .accepted:
            break
        default:
            throw ProbeError("This iCloud account has no invitation to accept. Ask the owner to approve the request.")
        }
        joinedRootID = id
        status = "\(source): share accepted. Tap Read Group as Member to verify access."
    }

    private func probeRootID(for metadata: CKShare.Metadata) throws -> CKRecord.ID {
        guard metadata.containerIdentifier == containerID, let id = metadata.hierarchicalRootRecordID,
              id.zoneID.zoneName.hasPrefix(Self.zonePrefix), id.recordName == Self.rootName else {
            throw ProbeError("The link does not belong to this CloudKit probe.")
        }
        return id
    }

    private func rootID(asOwner: Bool) throws -> CKRecord.ID {
        guard let id = asOwner ? ownedRootID : joinedRootID else {
            throw ProbeError("Create or accept the test group first.")
        }
        return id
    }

    private func invitationURL() throws -> URL {
        let text = inviteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else {
            throw ProbeError("Paste the HTTPS CloudKit invitation link.")
        }
        return url
    }

    private func fetchShare(_ id: CKRecord.ID) async throws -> CKShare {
        guard let share = try await container.privateCloudDatabase.record(for: id) as? CKShare else {
            throw ProbeError("The CloudKit record was not a share.")
        }
        return share
    }

    private func updateShare(
        _ action: String, success: String, change: (CKShare) async throws -> Void
    ) async {
        await run(action) {
            guard let snapshot = ownedShare, let share = snapshot.copy() as? CKShare else { return }
            try await change(share)
            guard let saved = try await container.privateCloudDatabase.save(share) as? CKShare else {
                throw ProbeError("CloudKit did not return the saved share. Refresh before retrying.")
            }
            ownedShare = saved
            status = success
        }
    }

    private func run(_ action: String, operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = "\(action)…"
        do {
            try await operation()
        } catch let error as CKError {
            let itemCodes = Set((error.partialErrorsByItemID ?? [:]).values.compactMap { ($0 as? CKError)?.code.rawValue })
            let details = itemCodes.isEmpty ? "" : " Item CKError codes: \(itemCodes.sorted().map(String.init).joined(separator: ", "))."
            status = "\(action) failed (CKError \(error.code.rawValue)). \(error.localizedDescription)\(details)"
        } catch {
            status = "\(action) failed. \(error.localizedDescription)"
        }
    }
}

private struct ProbeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class CloudKitProbeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = CloudKitProbeSceneDelegate.self
        return configuration
    }
}

final class CloudKitProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { receive(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        receive(metadata)
    }

    private func receive(_ metadata: CKShare.Metadata) {
        if !GroupsModel.shared.receive(metadata) {
            CloudKitProbe.shared.receive(metadata)
        }
    }
}
#endif
