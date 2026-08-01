import SwiftUI
import SwiftData

struct ScoreEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let round: GameRound
    let levelNumber: Int
    @State private var values: [UUID: String] = [:]

    private var definition: LevelDefinition { LevelDefinition.definition(for: levelNumber) }
    private var parsedScores: [UUID: Int]? {
        var result: [UUID: Int] = [:]
        for participant in round.participants {
            guard let value = values[participant.id], let score = Int(value), score >= 0 else { return nil }
            result[participant.id] = score
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Level \(levelNumber): \(definition.goal)").font(.headline)
                }
                Section("Scores") {
                    ForEach(round.participants) { participant in
                        TextField(participant.displayName, text: scoreBinding(for: participant))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Score for \(participant.displayName)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.softPurpleBackground)
            .navigationTitle("Enter Scores")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveScores() }
                        .disabled(parsedScores == nil)
                }
            }
            .onAppear(perform: populateExistingScores)
        }
    }

    private func scoreBinding(for participant: RoundParticipant) -> Binding<String> {
        Binding(get: { values[participant.id, default: ""] }, set: { values[participant.id] = $0 })
    }

    private func populateExistingScores() {
        guard let level = round.levels.first(where: { $0.levelNumber == levelNumber }) else { return }
        for entry in level.entries where entry.participant != nil { values[entry.participant!.id] = String(entry.score) }
    }

    private func saveScores() {
        guard let parsedScores else { return }
        GameRules.save(scores: parsedScores, for: levelNumber, in: round, context: context)
        dismiss()
    }
}
