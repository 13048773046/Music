import SwiftUI

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 104, height: 104)
                    Image(systemName: "music.note")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundColor(.white)
                }
                .scaleEffect(appeared ? 1 : 0.85)
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
