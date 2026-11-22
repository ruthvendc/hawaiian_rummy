import SwiftUI
import SwiftData

struct ScoreEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let round: GameRound
    let levelNumber: Int
    @State private var values: [UUID: String] = [:]
    @State private var showingSaveError = false

    private var definition: LevelDefinition { LevelDefinition.definition(for: levelNumber) }
    private var isEditingExistingLevel: Bool { (round.levels ?? []).contains { $0.levelNumber == levelNumber } }
    private var parsedScores: [UUID: Int]? {
        GameRules.parsedScores(for: round.orderedParticipants.map(\.id), values: values)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Level \(levelNumber): \(definition.goal)").font(.headline)
                }
                Section("Scores") {
                    ForEach(round.orderedParticipants) { participant in
                        PlayerScoreField(name: participant.displayName, score: scoreBinding(for: participant))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle(isEditingExistingLevel ? "Edit Scores" : "Enter Scores")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveScores() }
                        .disabled(parsedScores == nil)
                }
            }
            .onAppear(perform: populateExistingScores)
            .alert("Couldn't save scores", isPresented: $showingSaveError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Your entries are still here. Please try saving again.")
            }
        }
    }

    private func scoreBinding(for participant: RoundParticipant) -> Binding<String> {
        Binding(get: { values[participant.id, default: ""] }, set: { values[participant.id] = $0 })
    }

    private func populateExistingScores() {
        guard let level = round.levels?.first(where: { $0.levelNumber == levelNumber }) else { return }
        for entry in level.entries ?? [] {
            if let participant = entry.participant {
                values[participant.id] = String(entry.score)
            }
        }
    }

    private func saveScores() {
        guard let parsedScores else { return }
        do {
            try GameRules.save(scores: parsedScores, for: levelNumber, in: round, context: context)
            dismiss()
        } catch {
            context.rollback()
            showingSaveError = true
        }
    }
}

struct PlayerScoreField: View {
    let name: String
    @Binding var score: String

    var body: some View {
        HStack {
            Text(name)
            TextField("Score", text: $score)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Score for \(name)")
        }
    }
}
