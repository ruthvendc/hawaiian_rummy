import Combine
import CoreData
import OSLog
import SwiftData
import SwiftUI

extension EnvironmentValues {
    @Entry var personalDeletionTargets = PersonalDeletionTargets()
    @Entry var personalDeletionIssue: String?
}

struct PersonalDeletionMonitor<Content: View>: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var receipts: [PersonalDeletionReceipt]
    @State private var targets = PersonalDeletionTargets()
    @State private var issue: String?
    @State private var syncIssues: [NSPersistentCloudKitContainer.EventType: String] = [:]
    @ViewBuilder var content: () -> Content

    private static var logger: Logger {
        Logger(subsystem: "com.davidruthven.hawiian-rummy-scorekeeper", category: "PersonalCloudSync")
    }

    private var displayedIssue: String? {
        issue ?? syncIssues[.setup] ?? syncIssues[.import] ?? syncIssues[.export]
    }

    var body: some View {
        content()
            .environment(\.personalDeletionTargets, targets)
            .environment(\.personalDeletionIssue, displayedIssue)
            .task(id: receipts.map(\.payload)) { reconcile() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reconcile() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: RunLoop.main)) { _ in
                reconcile()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
                .receive(on: RunLoop.main)) { notification in
                if let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event {
                    handleCloudEvent(event)
                }
            }
    }

    private func reconcile() {
        do {
            // A remote store import can finish before SwiftUI's receipt query updates.
            targets = try PersonalHistoryDeletion.visibleTargets(in: context.container)
            try PersonalHistoryDeletion.reconcile(in: context.container)
            issue = nil
        } catch {
            issue = (error as? PersonalHistoryDeletion.Issue)?.errorDescription
                ?? "Couldn’t finish a synced deletion. Reopen the app to retry."
        }
    }

    private func handleCloudEvent(_ event: NSPersistentCloudKitContainer.Event) {
        guard event.endDate != nil else { return }
        if event.succeeded {
            syncIssues[event.type] = nil
            if event.type == .import { reconcile() }
            return
        }
        guard let error = event.error as NSError? else { return }
        Self.logger.error("Personal iCloud sync event \(event.type.rawValue, privacy: .public) failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        if error.domain == NSCocoaErrorDomain && error.code == 134417 { return } // A matching request is already queued.
        switch event.type {
        case .setup, .import:
            syncIssues[event.type] = "Couldn’t receive personal iCloud updates. If your data stays out of date, reopen the app while online."
        case .export:
            syncIssues[event.type] = "Some personal changes haven’t uploaded to iCloud. If they don’t sync, reopen the app while online."
        @unknown default:
            break
        }
    }
}
