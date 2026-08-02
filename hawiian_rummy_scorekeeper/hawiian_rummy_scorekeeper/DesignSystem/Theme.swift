import SwiftUI
import UIKit

extension Color {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let grammyPurple = adaptive(
        light: UIColor(red: 0.34, green: 0.16, blue: 0.50, alpha: 1),
        dark: UIColor(red: 0.80, green: 0.65, blue: 0.96, alpha: 1)
    )
    static let grammyLavender = adaptive(
        light: UIColor(red: 0.90, green: 0.84, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.31, green: 0.22, blue: 0.40, alpha: 1)
    )
    static let warmGold = adaptive(
        light: UIColor(red: 0.82, green: 0.58, blue: 0.20, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.71, blue: 0.32, alpha: 1)
    )
    static let softPurpleBackground = adaptive(
        light: UIColor(red: 0.82, green: 0.71, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.22, green: 0.15, blue: 0.31, alpha: 1)
    )
    static let grammySurface = adaptive(
        light: UIColor(white: 1, alpha: 0.68),
        dark: UIColor(red: 0.20, green: 0.14, blue: 0.27, alpha: 1)
    )
    static let grammyDecorativeSurface = adaptive(
        light: UIColor(white: 1, alpha: 0.18),
        dark: UIColor(red: 0.37, green: 0.27, blue: 0.47, alpha: 0.50)
    )
}

struct LeaderBadge: View {
    var body: some View {
        Label("Leading", systemImage: "crown.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.grammyPurple)
            .accessibilityLabel("Current leader")
    }
}

struct SectionIntroCard: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.grammyPurple)
                .frame(width: 48, height: 48)
                .background(Color.grammyLavender.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.grammySurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.grammyPurple.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
