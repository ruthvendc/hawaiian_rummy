#if DEBUG
import CloudKit
import SwiftUI

struct GroupsView: View {
    let model: GroupsModel
    @State private var path: [UUID] = []
    @State private var sheet: GroupSheet?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    SectionIntroCard(title: "Your Groups", subtitle: "Play with family and friends", icon: "person.3.fill")
                        .listRowBackground(Color.clear)
                    Button("Create Group", systemImage: "plus.circle") { sheet = .create }
                        .disabled(model.account == nil || model.isStale)
                    Button("Join Group", systemImage: "link") { sheet = .join }
                        .disabled(model.account == nil || model.isStale)
                }
                NavigationLink("Resume Group Game") { ResumableGroupGamesView(model: model) }
                NavigationLink("Account Diagnostic") {
                    GroupAccountDiagnosticView(model: model)
                }
                if let issue = model.refreshIssue {
                    Section {
                        Text(model.isStale ? "Couldn’t refresh iCloud. Showing saved groups." : issue)
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Refresh Groups") { Task { await model.refresh() } }
                    }
                }
                if model.isStale && model.refreshIssue == nil {
                    Text("Showing saved groups. Pull down to refresh.").foregroundStyle(.secondary)
                }
                if let issue = model.cacheIssue { Text(issue).foregroundStyle(.secondary) }
                if let issue = model.invitationIssue {
                    Text(issue).foregroundStyle(.secondary)
                } else if model.nativeInvitation != nil {
                    ProgressView("Finishing your invitation…")
                }
                PendingInvitationsSection(model: model)
                if model.isRefreshing && model.groups.isEmpty { ProgressView("Finding groups…") }
                if !model.groups.isEmpty {
                    Section("Groups") {
                        ForEach(model.groups) { group in
                            NavigationLink(value: group.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name)
                                    Text(group.isOwner ? "Owner" : "Member")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 6, for: .scrollContent)
            .background(Color.softPurpleBackground)
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refresh() }
            .navigationDestination(for: UUID.self) { id in
                if let group = model.groups.first(where: { $0.id == id }) {
                    GroupDetailView(group: group, model: model)
                } else {
                    ContentUnavailableView("Group Unavailable", systemImage: "person.3")
                }
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.account) { oldAccount, _ in
            if oldAccount != nil {
                path = []
                sheet = nil
            }
        }
        .sheet(item: $sheet, onDismiss: { model.actionIssue = nil }) { route in
            switch route {
            case .create: CreateGroupView(model: model)
            case .join: JoinGroupView(model: model)
            }
        }
    }
}

private struct ResumableGroupGamesView: View {
    private struct LoadKey: Equatable {
        let account: String?
        let scopes: Set<GroupSummary.Scope>
    }

    let model: GroupsModel
    @State private var items: [GroupGameJournal.ResumeItem] = []
    @State private var loadedAccount: String?
    @State private var loadFailed = false

    var body: some View {
        let visible = items.filter { model.containsGroup($0.route.group) }
        List {
            if model.scoringAccount == nil {
                Text("Verify your iCloud account to resume saved group scoring.")
            } else if loadedAccount != model.scoringAccount {
                ProgressView("Loading saved games…")
            } else if loadFailed {
                Text("Couldn’t open saved scoring on this iPhone.")
            } else if visible.isEmpty {
                Text("No group games saved for offline scoring.")
            } else {
                ForEach(visible) { item in
                    NavigationLink {
                        GroupGameDetailView(route: item.route, model: model)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.route.group.name).font(.headline)
                            GroupGameSummary(header: item.header, scorekeeper: "You")
                            Text(item.syncStatus).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Resume Group Game")
        .task(id: LoadKey(account: model.scoringAccount, scopes: Set(model.groups.map(\.scope)))) { load() }
        .refreshable { load() }
        .onChange(of: visibilityTrace(visible), initial: true) { _, message in
            if let message { GroupAccountLaunchDiagnostic.activeTrace?.record(message) }
        }
    }

    private func visibilityTrace(_ visible: [GroupGameJournal.ResumeItem]) -> String? {
        guard let trace = GroupAccountLaunchDiagnostic.activeTrace else { return nil }
        guard model.scoringAccount != nil else { return "Resume screen · scoring identity unresolved" }
        guard loadedAccount == model.scoringAccount else { return "Resume screen · waiting for the current account’s journals" }
        guard !loadFailed else { return "Resume screen · local store read failed" }
        let testInResults = items.contains { trace.isTarget($0.route.group.id) }
        let testVisible = visible.contains { trace.isTarget($0.route.group.id) }
        let outcome = if testVisible { "visible" } else if testInResults { "excluded by screen · group scope no longer matches memory" } else { "absent from the last journal scan" }
        return "Resume screen · showing \(visible.count) of \(items.count) loaded row(s) · test group \(outcome) · memory \(GroupAccountLaunchDiagnostic.groupSummary(model.groups))"
    }

    private func load() {
        do {
            items = try model.resumableGames()
            loadFailed = false
        } catch {
            items = []
            loadFailed = true
        }
        loadedAccount = model.scoringAccount
    }
}

private struct GroupAccountDiagnosticView: View {
    let model: GroupsModel
    @AppStorage(GroupAccountLaunchDiagnostic.nextLaunchModeKey)
    private var nextLaunchMode: GroupAccountLaunchDiagnostic.Mode = .off
    private let diagnostic = GroupAccountLaunchDiagnostic.shared
    @State private var diskCacheSummary = "Checking…"

    var body: some View {
        List {
            Section("This Launch") {
                LabeledContent("Diagnostic Mode", value: diagnostic.mode.title)
                lookup(.accountStatus, title: "CloudKit Account Status")
                lookup(.userRecordID, title: "User Record ID Lookup")
                LabeledContent("Online Baseline", value: diagnostic.baselineStatus)
                LabeledContent("Account Comparison", value: diagnostic.comparison)
                LabeledContent("Groups Cache", value: diagnostic.cacheResult?.title ?? "Not checked yet")
            }
            if diagnostic.mode != .off {
                Section("Current Groups State") {
                    LabeledContent("In Memory", value: GroupAccountLaunchDiagnostic.groupSummary(model.groups))
                    LabeledContent("Disk Cache on Read", value: diskCacheSummary)
                }
                Section {
                    ForEach(diagnostic.traceEvents) { event in
                        Text("\(event.id). \(event.text)").font(.footnote).textSelection(.enabled)
                    }
                } header: {
                    Text("Groups and Journal Trace")
                } footer: {
                    Text("Open Resume Group Game to capture the journal scan. The trace follows Game-Verification-3B1 and resets on relaunch.")
                }
            }
            Section {
                Picker("Mode", selection: $nextLaunchMode) {
                    ForEach(GroupAccountLaunchDiagnostic.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Next Launch")
            } footer: {
                Text(diagnostic.usesLaunchEnvironment
                     ? "Xcode set the mode for this launch. To use the selected mode, fully close the app and reopen it from the Home Screen."
                     : "Fully close the app and reopen it to use the selected mode.")
            }
        }
        .navigationTitle("Account Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.scoringAccount) {
            if diagnostic.mode != .off { diskCacheSummary = model.diagnosticDiskCacheSummary() }
        }
        .onChange(of: model.groups) { _, _ in
            if diagnostic.mode != .off { diskCacheSummary = model.diagnosticDiskCacheSummary() }
        }
    }

    @ViewBuilder private func lookup(_ stage: GroupAccountLaunchDiagnostic.Lookup, title: String) -> some View {
        let result = diagnostic.lookups[stage]
        LabeledContent(title, value: result?.summary ?? "Not started")
        if let elapsed = result?.elapsedMs {
            LabeledContent("\(title) Duration", value: "\(elapsed) ms")
        }
        if let error = result?.error {
            LabeledContent("\(title) Error", value: error)
        }
    }
}

private enum GroupSheet: String, Identifiable {
    case create, join
    var id: String { rawValue }
}

private struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var displayName = ""
    @State private var groupID = UUID()
    @State private var attempted = false
    let model: GroupsModel
    private var trimmedDisplayName: String { GroupMemberDisplayName.trimmed(displayName) }
    private var isDisplayNameValid: Bool {
        trimmedDisplayName.isEmpty || GroupMemberDisplayName.visibleName(trimmedDisplayName) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                    .textInputAutocapitalization(.words)
                    .disabled(attempted)
                TextField("Your display name (optional)", text: $displayName)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.words)
                    .disabled(attempted)
                if !isDisplayNameValid {
                    Text("Use one line of up to \(GroupMemberDisplayName.maximumLength) characters.")
                        .foregroundStyle(.secondary)
                }
                Text("New members can request to join. You approve each request.")
                    .foregroundStyle(.secondary)
                GroupActionStatus(model: model)
            }
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(attempted ? "Retry" : "Create") {
                        attempted = true
                        model.actionIssue = nil
                        Task {
                            if await model.create(name, displayName: displayName, id: groupID) { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              !isDisplayNameValid || model.isWorking || model.isRefreshing)
                }
            }
            .interactiveDismissDisabled(model.isWorking)
        }
    }
}

private struct JoinGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var submittedURL: URL?
    let model: GroupsModel

    private var didJoin: Bool {
        guard let submittedURL else { return false }
        return model.invitationState(for: submittedURL) == .joined
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invitation") {
                    TextField("Paste invitation link", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let url = GroupsModel.invitationURL(from: link) {
                        if !model.isPending(url) {
                            Button("Request to Join") {
                                model.actionIssue = nil
                                Task {
                                    if await model.requestAccess(to: url) {
                                        submittedURL = url
                                        link = ""
                                    }
                                }
                            }
                        }
                    } else if !link.isEmpty {
                        Text("Paste an iCloud invitation link.").foregroundStyle(.secondary)
                    }
                }
                PendingInvitationsSection(model: model, canForget: true)
                GroupActionStatus(model: model)
                if let issue = model.cacheIssue {
                    Text(issue).foregroundStyle(.secondary)
                }
                Text("If you used Apple’s Ask for Access screen, reopen the original invitation after the owner approves.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isWorking || model.isRefreshing)
            .navigationTitle("Join Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .interactiveDismissDisabled(model.isWorking)
        }
        .onChange(of: didJoin) { _, joined in
            if joined { dismiss() }
        }
    }
}

private struct PendingInvitationsSection: View {
    @Environment(\.openURL) private var openURL
    let model: GroupsModel
    var canForget = false

    var body: some View {
        if !model.snapshot.pendingLinks.isEmpty {
            Section("Pending Invitations") {
                ForEach(Array(model.snapshot.pendingLinks.enumerated()), id: \.element) { index, url in
                    let state = model.invitationState(for: url)
                    VStack(alignment: .leading, spacing: 8) {
                        if model.snapshot.pendingLinks.count > 1 {
                            Text("Invitation \(index + 1)").font(.headline)
                        }
                        Text(message(for: state)).foregroundStyle(.secondary)
                        if state == .needsVerification {
                            Button("Verify with Apple") {
                                model.willVerifyInvitation(url)
                                openURL(url)
                            }
                        }
                    }
                    .swipeActions {
                        if canForget {
                            Button("Forget", role: .destructive) { model.forgetLink(url) }
                        }
                    }
                }
            }
        }
    }

    private func message(for state: PendingInvitationState) -> LocalizedStringKey {
        switch state {
        case .waiting: "Waiting for approval. Your group will appear automatically once the owner approves your request."
        case .joining: "Approved. Your group will appear shortly."
        case .joined: "You joined the group."
        case .needsVerification: "Apple needs to verify your account before you can join."
        case .unavailable: "This invitation can’t be used. Ask the owner for a new link."
        case .retrying: "Couldn’t check this invitation. The app will try again."
        }
    }
}

struct GroupActionStatus: View {
    let model: GroupsModel

    var body: some View {
        if model.isWorking { ProgressView() }
        if let issue = model.actionIssue { Text(issue).foregroundStyle(.secondary) }
    }
}
#endif
