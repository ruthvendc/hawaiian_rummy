import SwiftUI

struct WelcomeView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.grammyPurple, .purple.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(Color.grammyLavender)
                    .accessibilityLabel("Purple Grammy portrait placeholder")
                Text("Hawaiian Rummy")
                    .font(.largeTitle.bold())
                Text("A family tradition created by Purple Grammy")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                Button("Begin") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.warmGold)
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
