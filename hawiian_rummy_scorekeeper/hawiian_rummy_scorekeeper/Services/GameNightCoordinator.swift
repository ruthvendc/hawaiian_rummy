import UIKit
import Combine

@MainActor
final class GameNightCoordinator: ObservableObject {
    @Published var isEnabled = false { didSet { apply() } }

    func deactivate() { isEnabled = false }
    private func apply() { UIApplication.shared.isIdleTimerDisabled = isEnabled }
}
