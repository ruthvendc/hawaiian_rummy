import SwiftUI

extension Color {
    static let grammyPurple = Color(red: 0.34, green: 0.16, blue: 0.50)
    static let grammyLavender = Color(red: 0.90, green: 0.84, blue: 0.96)
    static let warmGold = Color(red: 0.82, green: 0.58, blue: 0.20)
    static let softPurpleBackground = Color(red: 0.85, green: 0.76, blue: 0.92)
}

struct LeaderBadge: View {
    var body: some View {
        Label("Leading", systemImage: "crown.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.grammyPurple)
            .accessibilityLabel("Current leader")
    }
}
