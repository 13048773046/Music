import SwiftUI

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xFAF8F5), Color(hex: 0xE2F5EE)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 装饰性柔和色块
            Circle()
                .fill(Theme.peach.opacity(0.25))
                .frame(width: 300, height: 300)
                .blur(radius: 60)
                .offset(x: -140, y: -320)
            Circle()
                .fill(Theme.lilac.opacity(0.25))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: 150, y: 340)

            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.lilac],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 112, height: 112)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 8)
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundColor(.white)
                }
                .scaleEffect(appeared ? 1 : 0.8)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("流萤音乐")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("让好音乐如流萤般点亮夜晚")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                appeared = true
            }
        }
    }
}
