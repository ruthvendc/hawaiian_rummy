import UIKit
import Combine

@MainActor
final class GameNightCoordinator: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "keepScreenOn")
            apply()
        }
    }
    private var isSceneActive = true

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "keepScreenOn")
        apply()
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        apply()
    }

    private func apply() { UIApplication.shared.isIdleTimerDisabled = isEnabled && isSceneActive }
}
