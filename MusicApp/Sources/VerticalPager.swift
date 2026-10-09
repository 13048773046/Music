import SwiftUI
import UIKit

/// 竖向翻页容器：模仿抖音 / 汽水音乐的上下滑动切歌体验。
/// 基于 UIPageViewController（iOS 16 兼容），滑动停止后回调当前页。
struct VerticalPager: UIViewControllerRepresentable {
    @Binding var currentIndex: Int
    let tracks: [Track]
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .vertical,
            options: nil
        )
        // 透明背景：避免 UIKit 默认底色在状态栏/底部区域露出
        pvc.view.backgroundColor = .clear
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        context.coordinator.rebuild(tracks: tracks)
        if !tracks.isEmpty {
            // 起始页跟随播放器当前索引；越界（如尚未播放）时兜底到第 0 页
            let start = context.coordinator.controllers.indices.contains(currentIndex) ? currentIndex : 0
            pvc.setViewControllers(
                [context.coordinator.controllers[start]],
                direction: .forward,
                animated: false,
                completion: nil
            )
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard let visible = pvc.viewControllers?.first,
              let visibleIndex = context.coordinator.controllers.firstIndex(of: visible),
              visibleIndex != currentIndex,
              context.coordinator.controllers.indices.contains(currentIndex) else {
            return
        }
        pvc.setViewControllers(
            [context.coordinator.controllers[currentIndex]],
            direction: visibleIndex < currentIndex ? .forward : .reverse,
            animated: false,
            completion: nil
        )
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalPager
        var controllers: [UIViewController] = []

        init(_ parent: VerticalPager) {
            self.parent = parent
        }

        func rebuild(tracks: [Track]) {
            let total = tracks.count
            controllers = tracks.enumerated().map { index, track in
                let hosting = UIHostingController(
                    rootView: PlayerCard(track: track, index: index, total: total)
                        .environmentObject(PlayerManager.shared)
                )
                // 透明背景：页面主色背景可延伸覆盖全屏（状态栏 / 底部小白条）
                hosting.view.backgroundColor = .clear
                return hosting
            }
        }

        // MARK: DataSource

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = controllers.firstIndex(of: viewController), index > 0 else { return nil }
            return controllers[index - 1]
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = controllers.firstIndex(of: viewController),
                  index < controllers.count - 1 else { return nil }
            return controllers[index + 1]
        }

        // MARK: Delegate

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let visible = pvc.viewControllers?.first,
                  let index = controllers.firstIndex(of: visible) else { return }
            parent.currentIndex = index
            parent.onPageChanged(index)
        }
    }
}

// MARK: - 首页单页卡片：正方形封面置顶 + 歌名/作者 + 拖动条（清新浅色版）

struct PlayerCard: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let index: Int
    let total: Int

    /// 当前歌曲封面的主色背景（nil = 加载中/无封面，用浅色渐变兜底）
    @State private var bgColor: Color?

    var body: some View {
        GeometryReader { geo in
            // 真实安全区（不可在外层加 ignoresSafeArea，否则会被清零导致控件被状态栏遮挡）
            let safeTop = geo.safeAreaInsets.top
            // 底部留白 = 透明导航栏内容高度(~63) + 底部安全区（home indicator），
            // 保证进度条/时间等控件在任何机型上都不会被导航栏遮挡
            let tabBarSpace = 70 + geo.safeAreaInsets.bottom
            // 封面加大约40%：几乎满宽，左外距很小
            let coverSize = max(geo.size.width - 28, 260)
            // 封面居中后的左外距（歌名/作者与之对齐）
            let sidePadding = (geo.size.width - coverSize) / 2
            // 背景是否偏浅（决定文字用深色还是白色）；无封面时按深色背景处理
            let onLight = bgColor.map { luminance(of: $0) > 0.55 } ?? false

            ZStack {
                // 背景：自身忽略安全区延伸到全屏（状态栏 / 底部小白条），不影响上方安全区计算
                background
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    // 顶部标题栏：App 名 + 播放模式
                    topBar(onLight: onLight)
                        .padding(.horizontal, 20)
                        .padding(.top, safeTop + 6)

                    Spacer(minLength: 12)

                    // 1:1 正方形封面（小圆角，居中，左外距很小）
                    AlbumArt(size: coverSize, title: track.title, coverURL: track.coverURL, radius: 12)

                    // 歌曲名称 + 作者名称：左对齐，左外距与封面一致
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(textPrimary(onLight: onLight))
                            .lineLimit(1)

                        Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                            .font(.system(size: 15))
                            .foregroundColor(textSecondary(onLight: onLight))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, sidePadding)
                    .padding(.top, 26)

                    Spacer(minLength: 12)

                    // 拖动条 + 时间（细滑块：小拖头，不遮挡内容）
                    VStack(spacing: 10) {
                        ThinSlider(
                            value: Binding(
                                get: { player.progress },
                                set: { player.seek(toFraction: $0) }
                            ),
                            tint: textPrimary(onLight: onLight)
                        )

                        HStack {
                            Text(formatTime(player.currentTime))
                            Spacer()
                            Text(formatTime(player.duration))
                        }
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(textSecondary(onLight: onLight))
                    }
                    .padding(.horizontal, sidePadding)

                    // 底部留白（TabBar 空间，自适应导航栏高度与底部安全区）
                    Spacer(minLength: tabBarSpace)
                }
                .frame(maxWidth: .infinity)
            }
            // 背景偏浅→深色状态栏文字；背景偏深→白色状态栏文字（沉浸式适配）
            .preferredColorScheme(onLight ? .light : .dark)
        }
        .task(id: track.id) {
            await loadBackground()
        }
        .animation(.easeInOut(duration: 0.35), value: bgColor)
        .id(track.id)
    }

    // MARK: - 背景：封面主色纯色

    @ViewBuilder
    private var background: some View {
        if let bg = bgColor {
            // 纯色：提取的封面主颜色
            bg.ignoresSafeArea()
        } else {
            // 加载中/无封面：深色兜底
            LinearGradient(
                colors: [Color(hex: 0x1C1C1F), Color(hex: 0x121214)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    /// 异步提取当前歌曲封面主色，并同步背景亮度给透明导航栏
    private func loadBackground() async {
        bgColor = nil
        player.playerCardBackgroundLight = true
        guard let url = track.coverURL else { return }
        let ui = await CoverPalette.color(for: track.id, from: url)
        let color = Color(uiColor: ui)
        bgColor = color
        player.playerCardBackgroundLight = luminance(of: color) > 0.55
    }

    // MARK: - 亮度与动态文字色

    private func luminance(of color: Color) -> CGFloat {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// 主文字：浅背景用深色，深背景用白色
    private func textPrimary(onLight: Bool) -> Color {
        onLight ? Theme.textPrimary : .white
    }

    /// 次文字：浅背景用灰色，深背景用半透明白
    private func textSecondary(onLight: Bool) -> Color {
        onLight ? Theme.textSecondary : .white.opacity(0.78)
    }

    // MARK: - 顶部标题栏

    private func topBar(onLight: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(onLight ? Theme.accent : .white)
                Text("流萤音乐")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(textPrimary(onLight: onLight))
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    player.cyclePlayMode()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: player.playMode.symbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(player.playMode.label)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(textSecondary(onLight: onLight))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    (onLight ? Color.white : Color.black.opacity(0.25)).opacity(0.7),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
        }
    }
}
