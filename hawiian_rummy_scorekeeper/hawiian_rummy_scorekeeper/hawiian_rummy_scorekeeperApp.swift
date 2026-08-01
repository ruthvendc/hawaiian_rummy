//
//  hawiian_rummy_scorekeeperApp.swift
//  hawiian_rummy_scorekeeper
//
//  Created by David Ruthven on 7/31/26.
//

import SwiftUI
import SwiftData

@main
struct hawiian_rummy_scorekeeperApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([
            PlayerProfile.self, Game.self, GameRound.self,
            RoundParticipant.self, LevelResult.self, ScoreEntry.self
        ])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
