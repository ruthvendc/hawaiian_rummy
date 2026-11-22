#if DEBUG
import CloudKit
import SwiftUI

struct GroupDetailView: View {
    let group: GroupSummary
    let model: GroupsModel
    @State private var details: GroupDetails?
    @State private var refreshIssue: String?
    @State private var isLoading = false
    @State private var reloadGeneration = 0
    @State private var confirmation: Confirmation?
    @State private var nameEditor: DisplayNameEditor?

    var body: some View {
        List {
            Section {
                SectionIntroCard(title: group.name, subtitle: group.isOwner ? "You own this group" : "You’re a member", icon: "person.3.fill")
                    .listRowBackground(Color.clear)
                if let url = details?.invitationURL {
                    ShareLink(item: url) { Label("Share Invitation Link", systemImage: "square.and.arrow.up") }
                    Text("The owner must approve anyone who requests access.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if details != nil {
                    Text("The invitation link is unavailable. Pull down to refresh.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink {
                    GroupPlayersView(group: group, model: model)
                } label: {
                    Label("Players", systemImage: "person.2.fill")
                }
                NavigationLink {
                    GroupGameHistoryView(group: group, model: model)
                } label: {
                    Label("Games", systemImage: "rectangle.stack")
                }
            }
            if let details {
                membersSection(details)
                if group.isOwner { requestsSection(details) }
                Section {
                    Button(group.isOwner ? "Delete Group" : "Leave Group", role: .destructive) {
                        confirmation = .removeGroup(isOwner: group.isOwner)
                    }
                }
            } else if let saved = model.cachedDetails(for: group) {
                Section("Members") {
                    ForEach(saved.members) { member in
                        GroupMemberLabel(name: member.name, role: member.role)
                    }
                    Text("Showing saved members. Connect and refresh for current membership.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Last updated \(saved.savedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Refresh Group") { Task { await reload() } }
                    .disabled(isLoading)
                if isLoading { ProgressView("Refreshing group…") }
                if let issue = refreshIssue {
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                }
            }
            GroupActionStatus(model: model)
        }
        .disabled(model.isWorking || model.isRefreshing)
        .scrollContentBackground(.hidden)
        .background(Color.softPurpleBackground)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: model.isRefreshing) { wasRefreshing, isRefreshing in
            if wasRefreshing && !isRefreshing && model.groups.contains(where: { $0.id == group.id }) {
                Task { await reload() }
            }
        }
        .sheet(item: $nameEditor, onDismiss: { model.actionIssue = nil }) { editor in
            EditGroupDisplayNameView(
                group: group, model: model, account: editor.account,
                currentName: editor.currentName, draft: editor.draft,
                onSave: { await reload(force: true) }
            )
        }
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { item in
            Button(item.button, role: .destructive) { Task { await confirm(item) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }

    private func membersSection(_ details: GroupDetails) -> some View {
        Section("Members") {
            let owner = details.share.owner
            memberRow(owner, role: "Owner", fallback: "Group Owner", in: details)
            ForEach(details.members, id: \.participantID) { member in
                let isAccepted = member.acceptanceStatus == .accepted
                let fallback = isAccepted ? "Member" : "Invited Member"
                HStack {
                    memberRow(member, role: isAccepted ? "Member" : "Invited", fallback: fallback, in: details)
                    if group.isOwner {
                        let name = details.displayName(for: member) ?? fallback
                        Menu {
                            Button("Remove Access", role: .destructive) {
                                confirmation = .revoke(member.participantID, name)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel("Manage \(name)")
                        }
                    }
                }
            }
            if details.memberNamesUnavailable {
                Text("Some display names could not be loaded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !group.isOwner && details.members.contains(where: { $0.acceptanceStatus == .unknown }) {
                Text("Some members may not be listed yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if details.canEditMyDisplayName, let account = model.account {
                Button("Edit My Display Name", systemImage: "pencil") {
                    model.actionIssue = nil
                    nameEditor = DisplayNameEditor(
                        account: account, currentName: details.myDisplayName ?? "",
                        draft: model.snapshot.memberNameDrafts?[group.id]
                    )
                }
            }
        }
    }

    private func requestsSection(_ details: GroupDetails) -> some View {
        Section("Access Requests") {
            Toggle("Allow Access Requests", isOn: Binding(
                get: { details.share.allowsAccessRequests },
                set: { enabled in Task { await change(.allowRequests(enabled)) } }
            ))
            if details.requests.isEmpty {
                Text("No pending requests").foregroundStyle(.secondary)
            }
            ForEach(Array(details.requests.enumerated()), id: \.offset) { _, requester in
                let lookup = requester.participantLookupInfo
                let name = GroupMemberDisplayName.cloudKitName(requester.userIdentity.nameComponents?.formatted())
                    ?? "Join request"
                Menu(name) {
                    Button("Approve") { Task { await change(.approve(lookup)) } }
                    Button("Decline", role: .destructive) { Task { await change(.deny(lookup)) } }
                    Button("Block", role: .destructive) {
                        confirmation = .block(lookup, name)
                    }
                }
            }
        }
    }

    private func memberRow(
        _ participant: CKShare.Participant, role: String, fallback: String, in details: GroupDetails
    ) -> some View {
        if details.memberNamesUnavailable,
           let saved = model.cachedDetails(for: group)?.members.first(where: { $0.id == participant.participantID }) {
            return GroupMemberLabel(name: saved.name, role: saved.role)
        }
        let isYou = details.isCurrentUser(participant)
        if let name = details.displayName(for: participant) {
            return GroupMemberLabel(name: isYou ? "\(name) (You)" : name, role: role)
        }
        return GroupMemberLabel(name: isYou ? "You" : fallback, role: isYou ? role : nil)
    }

    private struct DisplayNameEditor: Identifiable {
        let id = UUID()
        let account: String
        let currentName: String
        let draft: String?
    }

    private func reload(force: Bool = false) async {
        guard force || !isLoading else { return }
        reloadGeneration += 1
        let started = reloadGeneration
        isLoading = true
        defer { if started == reloadGeneration { isLoading = false } }
        do {
            let refreshed = try await model.details(for: group)
            guard started == reloadGeneration else { return }
            details = refreshed
            refreshIssue = nil
        } catch {
            guard started == reloadGeneration else { return }
            details = nil
            refreshIssue = GroupsModel.message(for: error)
            if GroupsModel.isAccessLoss(error) { await model.refresh() }
        }
    }

    private func change(_ action: GroupMembershipChange) async {
        model.actionIssue = nil
        if await model.changeMembership(action, group: group) { await reload(force: true) }
    }

    private func confirm(_ item: Confirmation) async {
        switch item {
        case .revoke(let id, _): await change(.revoke(id))
        case .block(let lookup, _): await change(.block(lookup))
        case .removeGroup: await model.remove(group)
        }
    }

    private enum Confirmation {
        case revoke(CKShare.Participant.ID, String)
        case block(CKUserIdentity.LookupInfo, String)
        case removeGroup(isOwner: Bool)

        var button: String {
            switch self {
            case .revoke: "Remove Access"
            case .block: "Block"
            case .removeGroup(let owner): owner ? "Delete Group" : "Leave Group"
            }
        }

        var title: String { button + "?" }

        var message: String {
            switch self {
            case .revoke(_, let name): "\(name) will lose access to this group."
            case .block(_, let name): "\(name) will no longer be able to request access to this group."
            case .removeGroup(let owner):
                owner ? "This permanently deletes the shared group, its players, and its games for everyone."
                    : "You’ll need the owner’s approval to rejoin."
            }
        }
    }
}
#endif
