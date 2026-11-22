//
//  hawiian_rummy_scorekeeperApp.swift
//  hawiian_rummy_scorekeeper
//
//  Created by David Ruthven on 7/31/26.
//

import SwiftUI
import SwiftData
#if DEBUG
import CoreData
#endif

@main
struct hawiian_rummy_scorekeeperApp: App {
    static let cloudKitContainerID = "iCloud.com.davidruthven.hawiian-rummy-scorekeeper"
    private let modelContainer: ModelContainer?
    #if DEBUG
    @UIApplicationDelegateAdaptor(CloudKitProbeAppDelegate.self) private var probeDelegate
    @State private var probe = CloudKitProbe.shared
    #endif

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-InitializeCloudKitSchema") {
            do {
                try Self.initializeCloudKitSchema()
                print("Hawaiian Rummy: CloudKit schema initialized.")
                exit(EXIT_SUCCESS)
            } catch {
                print("Hawaiian Rummy: Could not initialize CloudKit schema: \(error)")
                exit(EXIT_FAILURE)
            }
        }
        #endif
        let schema = Schema([
            PlayerProfile.self, Game.self, GameRound.self,
            RoundParticipant.self, LevelResult.self, ScoreEntry.self, PersonalDeletionReceipt.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(Self.cloudKitContainerID)
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            modelContainer = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            appContent
                .sheet(isPresented: $probe.isPresented) {
                    CloudKitProbeView(probe: probe)
                }
                .task {
                    await GroupRosterVerification.runIfRequested(containerIdentifier: Self.cloudKitContainerID)
                    await GroupGameVerification.runIfRequested(containerIdentifier: Self.cloudKitContainerID)
                }
            #else
            appContent
            #endif
        }
    }

    private var appContent: some View {
        Group {
            if let modelContainer {
                PersonalDeletionMonitor { ContentView() }
                    .modelContainer(modelContainer)
            } else {
                ContentUnavailableView(
                    "Couldn't Open Saved Games",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Your saved games could not be loaded. Please close and reopen the app.")
                )
            }
        }
    }

    #if DEBUG
    private static func initializeCloudKitSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try autoreleasepool {
            let description = NSPersistentStoreDescription(url: directory.appending(path: "schema.sqlite"))
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudKitContainerID
            )
            description.shouldAddStoreAsynchronously = false
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [
                PlayerProfile.self, Game.self, GameRound.self,
                RoundParticipant.self, LevelResult.self, ScoreEntry.self, PersonalDeletionReceipt.self
            ]) else {
                throw CocoaError(.coderInvalidValue)
            }
            let container = NSPersistentCloudKitContainer(name: "Scorekeeper", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }
            try container.initializeCloudKitSchema()
            if let store = container.persistentStoreCoordinator.persistentStores.first {
                try container.persistentStoreCoordinator.remove(store)
            }
        }
    }
    #endif
}
