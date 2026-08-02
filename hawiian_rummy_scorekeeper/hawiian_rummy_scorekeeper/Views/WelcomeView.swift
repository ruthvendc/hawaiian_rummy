import SwiftUI

struct WelcomeView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.grammyPurple, .purple.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            WelcomeCardBackground()
            VStack(spacing: 24) {
                Text("Hawaiian Rummy Scorekeeper")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Image(systemName: "suit.club.fill")
                    Image(systemName: "suit.diamond.fill")
                    Image(systemName: "suit.heart.fill")
                    Image(systemName: "suit.spade.fill")
                }
                .font(.title3)
                .foregroundStyle(Color.warmGold)
                Text("A family tradition created by Purple Grammy")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Button("Begin") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.warmGold)
                    .accessibilityHint("Open the scorekeeper")
            }
            .foregroundStyle(.white)
            .padding(32)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.96)
        }
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { appeared = true } }
    }
}

private struct WelcomeCardBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WelcomeCard(suit: "suit.heart.fill", tint: .warmGold)
                    .rotationEffect(.degrees(-20))
                    .position(x: 54, y: 120)
                WelcomeCard(suit: "suit.spade.fill", tint: .grammyLavender)
                    .rotationEffect(.degrees(18))
                    .position(x: proxy.size.width - 42, y: 175)
                WelcomeCard(suit: "suit.diamond.fill", tint: .warmGold)
                    .rotationEffect(.degrees(26))
                    .position(x: 50, y: proxy.size.height - 155)
                WelcomeCard(suit: "suit.club.fill", tint: .grammyLavender)
                    .rotationEffect(.degrees(-16))
                    .position(x: proxy.size.width - 50, y: proxy.size.height - 105)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WelcomeCard: View {
    let suit: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.12))
            .frame(width: 92, height: 128)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
            }
            .overlay {
                Image(systemName: suit)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(tint.opacity(0.65))
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}
