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
            let top = Self.windowSafeAreaTop
            let bottom = Self.windowSafeAreaBottom
            controllers = tracks.enumerated().map { index, track in
                let hosting = UIHostingController(
                    rootView: PlayerCard(track: track, index: index, total: total,
                                         topInset: top, bottomInset: bottom)
                        .environmentObject(PlayerManager.shared)
                        .environmentObject(AuthManager.shared)
                )
                // 透明背景：页面主色背景可延伸覆盖全屏（状态栏 / 底部小白条）
                hosting.view.backgroundColor = .clear
                // 关键：取消 UIHostingController 桥接层的自动安全区避让。
                // 之前直接在 PlayerCard 里读 geo.safeAreaInsets 加 padding 没效果，
                // 是因为嵌套在 UIPageViewController 里时该值恒为 0——
                // 桥接层已经悄悄处理过安全区，靠读值拿不到状态栏高度。
                // 这里用负的 additionalSafeAreaInsets 把安全区抵消为 0，
                // SwiftUI 内容从屏幕原点（状态栏正后方）开始布局，
                // 顶部/底部安全区一律由 keyWindow 真实值显式注入（iOS 16.0 全版本兼容）。
                hosting.additionalSafeAreaInsets = UIEdgeInsets(top: -top, left: 0, bottom: -bottom, right: 0)
                return hosting
            }
        }

        /// 从 keyWindow 读取真实安全区高度（顶部状态栏 / 底部 Home 指示条）
        static var windowSafeAreaTop: CGFloat {
            (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?
                .windows.first(where: { $0.isKeyWindow })?
                .safeAreaInsets.top ?? 0
        }
        static var windowSafeAreaBottom: CGFloat {
            (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?
                .windows.first(where: { $0.isKeyWindow })?
                .safeAreaInsets.bottom ?? 0
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
    @EnvironmentObject private var auth: AuthManager
    let track: Track
    let index: Int
    let total: Int
    /// 真实安全区高度（由 Coordinator 从 keyWindow 注入，不依赖桥接层）
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// 当前歌曲封面的主色背景（nil = 加载中/无封面，用浅色渐变兜底）
    @State private var bgColor: Color?
    /// 进度条拖动中的预览位置（nil = 跟随真实播放进度，松手才 seek）
    @State private var scrubFraction: Double? = nil
    /// 互动状态（按歌曲独立，切回页面保留）
    @State private var liked: Bool
    @State private var likeCount: Int
    @State private var shareCount: Int
    @State private var commentCount: Int
    @State private var showComments = false
    @State private var shareURL: URL?
    /// 歌词显示切换（点击封面切换）
    @State private var showLyrics = false
    @State private var lyricLines: [KRCLine] = []

    init(track: Track, index: Int, total: Int,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        self.track = track
        self.index = index
        self.total = total
        self.topInset = topInset
        self.bottomInset = bottomInset
        _liked = State(initialValue: track.isLiked ?? false)
        _likeCount = State(initialValue: track.likeCount ?? 0)
        _shareCount = State(initialValue: track.shareCount ?? 0)
        _commentCount = State(initialValue: track.commentCount ?? 0)
    }

    var body: some View {
        GeometryReader { geo in
            // hosting.safeAreaRegions=[]：这里 geo.safeAreaInsets 恒为 0，
            // 顶部栏/底部控件的安全区一律用外部注入的真实值，
            // 从根上避免 UIKit↔SwiftUI 桥接把安全区吞掉导致偏移失效。
            let tabBarSpace = 70 + bottomInset
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
                    // 顶部标题栏：App 名 + 播放模式（撑满整行：左 App 名 / 右模式按钮，对齐在状态栏下方）
                    topBar(onLight: onLight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, topInset + 6)

                    // 1:1 正方形封面（小圆角，居中，左外距很小）；与顶部栏间距收小，整体上移
                    Spacer(minLength: 6)

                    // 封面区域：点击切换封面/歌词视图
                    Group {
                        if showLyrics && !lyricLines.isEmpty {
                            LyricView(lines: lyricLines,
                                      progress: (scrubFraction ?? player.progress) * player.duration,
                                      tint: textPrimary(onLight: onLight))
                                .frame(width: coverSize, height: coverSize)
                        } else {
                            AlbumArt(size: coverSize, title: track.title, coverURL: track.coverURL, radius: 12)
                        }
                    }
                    .onTapGesture {
                        if !lyricLines.isEmpty { showLyrics.toggle() }
                    }

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

                    // 互动操作行：点赞 / 评论 / 分享（紧贴进度条上方；左对齐，数量角标）
                    HStack(spacing: 30) {
                        actionButton(
                            icon: "heart.fill",
                            tint: liked ? .red : textPrimary(onLight: onLight),
                            count: likeCount,
                            onLight: onLight
                        ) { Task { await toggleLike() } }
                        actionButton(
                            icon: "bubble.right.fill",
                            tint: textPrimary(onLight: onLight),
                            count: commentCount,
                            onLight: onLight
                        ) { showComments = true }
                        actionButton(
                            icon: "arrowshape.turn.up.forward.fill",
                            tint: textPrimary(onLight: onLight),
                            count: shareCount,
                            onLight: onLight
                        ) { Task { await share() } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, 10)

                    // 多功能进度条：同一根条展示已播放段 + 已缓冲段，缓冲中拖头变加载动画；
                    // 拖动时只预览位置，松手才执行 seek
                    VStack(spacing: 10) {
                        PlayerProgressBar(
                            progress: player.progress,
                            buffer: player.bufferProgress,
                            isBuffering: player.isBuffering,
                            tint: textPrimary(onLight: onLight),
                            scrubFraction: $scrubFraction,
                            onSeek: { fraction in player.seek(toFraction: fraction) }
                        )

                        HStack {
                            Text(formatTime((scrubFraction ?? player.progress) * player.duration))
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
            // 加载歌词
            showLyrics = false
            lyricLines = []
            if track.hasLyric == true {
                if let text = try? await API.fetchLyric(track.id) {
                    lyricLines = parseLyrics(text)
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: bgColor)
        .id(track.id)
        .sheet(isPresented: $showComments) {
            CommentSheet(track: track)
                .environmentObject(auth)
        }
        .sheet(item: $shareURL) { u in
            ShareSheet(url: u)
        }
    }

    // MARK: - 互动按钮（点赞 / 评论 / 分享）

    /// 实心圆润图标 + 数量角标（显示在图标右上角，0 或无数量时不显示角标）；frame 自适应图标大小
    private func actionButton(icon: String, tint: Color, count: Int?,
                              onLight: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(tint)
                if let count, count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(tint)
                        .offset(x: 12, y: -10)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleLike() async {
        guard let uid = auth.currentUser?.id else { return }
        do {
            let r = try await API.toggleLike(trackId: track.id, userId: uid)
            liked = r.liked
            likeCount = r.count
        } catch {}
    }

    private func share() async {
        let updated = await API.reportShare(track.id)
        if updated > 0 { shareCount = updated }   // 接口失败时保留本地计数，不被 0 覆盖
        shareURL = API.streamURL(track.id)
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
