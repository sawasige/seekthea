import SwiftUI

struct OnboardingWelcomeView: View {
    let onStart: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var iconVisible = false
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var buttonsVisible = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowRadius: CGFloat = 20

    var body: some View {
        ZStack {
            // 背景: 径方向グラデーション（中心から "目の光" のように）
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.25),
                    Color.accentColor.opacity(0.05),
                    Color.clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 500
            )
            .scaleEffect(pulseScale)
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // アプリアイコン
                Image("AppIconImage")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.4), radius: glowRadius, x: 0, y: 8)
                    .scaleEffect(iconVisible ? 1.0 : 0.6)
                    .opacity(iconVisible ? 1.0 : 0)
                    .rotationEffect(.degrees(iconVisible ? 0 : -5))

                VStack(spacing: 12) {
                    Text("Seekthea")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .opacity(titleVisible ? 1 : 0)
                        .offset(y: titleVisible ? 0 : 20)

                    Text("興味のあるトピックから、\nあなただけのニュースフィードを。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .opacity(subtitleVisible ? 1 : 0)
                        .offset(y: subtitleVisible ? 0 : 20)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: onStart) {
                        Text("はじめる")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("スキップ", action: onSkip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
                .opacity(buttonsVisible ? 1 : 0)
            }
        }
        .onAppear {
            if reduceMotion {
                iconVisible = true
                titleVisible = true
                subtitleVisible = true
                buttonsVisible = true
                return
            }
            runEntranceAnimation()
        }
    }

    private func runEntranceAnimation() {
        // 背景パルス（無限ループ）
        withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
            pulseScale = 1.1
        }
        // アイコンの光パルス
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true).delay(0.5)) {
            glowRadius = 40
        }
        // アイコン登場
        withAnimation(.spring(response: 0.9, dampingFraction: 0.6).delay(0.1)) {
            iconVisible = true
        }
        // タイトル
        withAnimation(.easeOut(duration: 0.6).delay(0.6)) {
            titleVisible = true
        }
        // サブコピー
        withAnimation(.easeOut(duration: 0.6).delay(0.9)) {
            subtitleVisible = true
        }
        // ボタン
        withAnimation(.easeOut(duration: 0.6).delay(1.3)) {
            buttonsVisible = true
        }
    }
}
