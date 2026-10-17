import SwiftUI

struct SplashView: View {
    @State private var appeared = false
    @ObservedObject private var preloader = AppPreloader.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 22) {
                // 启动器 Logo：与 App 图标一致的深黑灰 Logo
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
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

                // 数据就绪驱动：加载阶段提示，避免用户误以为卡死
                if !preloader.startupReady {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                        Text(loadingHint)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary.opacity(0.7))
                    }
                    .opacity(appeared ? 1 : 0)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                appeared = true
            }
        }
    }

    /// 加载阶段提示（面向用户：当前正在准备哪部分）
    private var loadingHint: String {
        if !preloader.playerReady { return "正在加载曲库…" }
        if !preloader.discoverRecommendedReady { return "正在加载发现页…" }
        if !preloader.mineLoaded { return "正在加载我的页…" }
        return "正在加载天气场景…"
    }
}
