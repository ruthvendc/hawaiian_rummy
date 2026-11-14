#if DEBUG
import CloudKit
import SwiftUI

struct CloudKitProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var probe: CloudKitProbe
    @State private var memberRecordID = ""
    @State private var showingDeleteConfirmation = false
    @State private var memberToRevoke: CKShare.Participant?

    var body: some View {
        NavigationStack {
            Form {
                Section("Result") {
                    Text(probe.status).textSelection(.enabled)
                    action("Check iCloud", probe.checkAccount)
                }
                ownerSection
                Section("Recipient") {
                    TextField("Paste invitation link", text: $probe.inviteText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    action("Request Access", probe.requestAccess)
                    action("Accept Pasted Link", probe.acceptPastedLink)
                    if probe.hasOpenedInvitation {
                        action("Accept Opened Invitation", probe.acceptDeliveredInvitation)
                    }
                    if probe.joinedRootID != nil {
                        action("Read Group as Member") { await probe.readGroup(asOwner: false) }
                        action("Write Test Record as Member", probe.writeAsMember)
                    }
                }
            }
            .disabled(probe.isBusy)
            .navigationTitle("CloudKit Sharing Probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete the test group?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) { Task { await probe.deleteGroup() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the test share and all records in its test zone.")
            }
            .alert("Revoke test membership?", isPresented: Binding(
                get: { memberToRevoke != nil },
                set: { if !$0 { memberToRevoke = nil } }
            ), presenting: memberToRevoke) { participant in
                Button("Revoke", role: .destructive) { Task { await probe.revoke(participant) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var ownerSection: some View {
        Section("Owner") {
            if probe.ownedRootID == nil {
                action("Create Private Test Group", probe.createGroup)
            }
            if let share = probe.ownedShare {
                if let url = share.url { ShareLink(item: url) }
                action("Refresh Requests and Members", probe.refreshOwnerShare)
                ForEach(Array(share.requesters.enumerated()), id: \.offset) { _, requester in
                    let name = displayName(requester.userIdentity)
                    action("Approve \(name)") { await probe.approve(requester) }
                }
                ForEach(share.participants.filter { $0.role != .owner }, id: \.participantID) { participant in
                    Button("Revoke \(displayName(participant.userIdentity))", role: .destructive) {
                        memberToRevoke = participant
                    }
                }
                action("Read Group as Owner") { await probe.readGroup(asOwner: true) }
                TextField("Paste member write record ID", text: $memberRecordID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                action("Read Member’s Test Record") { await probe.readMemberWrite(memberRecordID) }
            }
            if probe.ownedRootID != nil {
                Button("Delete Test Group", role: .destructive) { showingDeleteConfirmation = true }
            }
        }
    }

    private func action(_ title: String, _ job: @escaping () async -> Void) -> some View {
        Button(title) { Task { await job() } }
    }

    private func displayName(_ identity: CKUserIdentity) -> String {
        let name = identity.nameComponents?.formatted() ?? ""
        return name.isEmpty ? identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber ?? "iCloud user" : name
    }
}
#endif
