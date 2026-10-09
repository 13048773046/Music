import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.42, green: 0.20, blue: 0.93),
                         Color(red: 0.16, green: 0.42, blue: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(width: 112, height: 112)
                    Image(systemName: "music.note")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundColor(.white)
                }
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)

                VStack(spacing: 6) {
                    Text("流萤音乐")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                    Text("让好音乐如流萤般点亮夜晚")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        }
    }
}
