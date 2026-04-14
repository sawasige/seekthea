import SwiftUI

struct OnboardingDoneView: View {
    let addedCount: Int
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false
    @State private var ringScale: CGFloat = 0.3
    @State private var ringOpacity: Double = 0.8
    @State private var textVisible = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.accentColor.opacity(0.15), Color.clear],
                center: .center,
                startRadius: 20,
                endRadius: 500
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    // 広がるリング
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 120, height: 120)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(Color.white, Color.accentColor)
                        .symbolEffect(.bounce, value: bounce)
                }
                .frame(height: 140)

                VStack(spacing: 10) {
                    Text("準備完了")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("\(addedCount)個のソースを追加しました\n記事を取得しています…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ProgressView()
                        .padding(.top, 8)
                }
                .opacity(textVisible ? 1 : 0)
                .offset(y: textVisible ? 0 : 12)

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        if reduceMotion {
            bounce.toggle()
            textVisible = true
        } else {
            bounce.toggle()
            withAnimation(.easeOut(duration: 0.8)) {
                ringScale = 2.0
                ringOpacity = 0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                textVisible = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            onDismiss()
        }
    }
}
