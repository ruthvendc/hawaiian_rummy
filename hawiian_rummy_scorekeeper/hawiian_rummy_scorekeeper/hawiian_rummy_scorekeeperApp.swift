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
        let schema = Schema([
            PlayerProfile.self, Game.self, GameRound.self,
            RoundParticipant.self, LevelResult.self, ScoreEntry.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(Self.cloudKitContainerID)
        )
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-InitializeCloudKitSchema") {
                try Self.initializeCloudKitSchema(at: configuration.url)
            }
            #endif
            modelContainer = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            modelContainer = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            appContent.sheet(isPresented: $probe.isPresented) {
                CloudKitProbeView(probe: probe)
            }
            #else
            appContent
            #endif
        }
    }

    private var appContent: some View {
        Group {
            if let modelContainer {
                ContentView()
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
    private static func initializeCloudKitSchema(at storeURL: URL) throws {
        try autoreleasepool {
            let description = NSPersistentStoreDescription(url: storeURL)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: cloudKitContainerID
            )
            description.shouldAddStoreAsynchronously = false
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [
                PlayerProfile.self, Game.self, GameRound.self,
                RoundParticipant.self, LevelResult.self, ScoreEntry.self
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
