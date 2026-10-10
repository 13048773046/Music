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
        // 歌曲追加（滑到末尾自动加载下一批）时，只给新 track 补建控制器，
        // 不重建已有页——否则会把当前翻页位置重置到首页。
        context.coordinator.syncControllers(for: tracks)
        // 用户正在手势翻页时，禁止程序化 setViewControllers 回跳：
        // 播放器 0.1s timeObserver 会高频触发本方法，若在手势进行中
        // 按 player.currentIndex 强制回跳，会与 didFinishAnimating 的新索引打架，
        // 导致"滑到下一首不播、再滑一首才播上一首"的滞后一首 bug。
        guard !context.coordinator.isUserPaging else { return }
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
        /// 用户手势正在翻页（willTransitionTo 置位、didFinishAnimating 复位）。
        /// 期间 updateUIViewController 不得程序化回跳，否则会与手势索引打架。
        var isUserPaging = false

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

        /// 歌曲追加时只为新增 track 补建控制器（不重建已有页，避免翻页位置跳动）
        func syncControllers(for newTracks: [Track]) {
            let total = newTracks.count
            let top = Self.windowSafeAreaTop
            let bottom = Self.windowSafeAreaBottom
            while controllers.count < newTracks.count {
                let index = controllers.count
                let track = newTracks[index]
                let hosting = UIHostingController(
                    rootView: PlayerCard(track: track, index: index, total: total,
                                         topInset: top, bottomInset: bottom)
                        .environmentObject(PlayerManager.shared)
                        .environmentObject(AuthManager.shared)
                )
                hosting.view.backgroundColor = .clear
                hosting.additionalSafeAreaInsets = UIEdgeInsets(top: -top, left: 0, bottom: -bottom, right: 0)
                controllers.append(hosting)
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

        /// 用户手势开始翻到下一个控制器：标记为正在翻页，
        /// 拦截高频 updateUIViewController 的程序化回跳。
        func pageViewController(_ pvc: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isUserPaging = true
        }

        func pageViewController(_ pvc: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            isUserPaging = false
            guard completed,
                  let visible = pvc.viewControllers?.first,
                  let index = controllers.firstIndex(of: visible) else { return }
            parent.currentIndex = index
            parent.onPageChanged(index)
        }
    }
}

// MARK: - 音效预设（UI 先做，功能后续接）

struct EQOption: Identifiable {
    let id = UUID().uuidString
    let name: String
    let icon: String
}

private let eqOptions: [EQOption] = [
    EQOption(name: "原音", icon: "speaker.fill"),
    EQOption(name: "3D 环绕", icon: "wave.3.right.circle.fill"),
    EQOption(name: "360 环绕", icon: "arrow.triangle.2.circlepath.circle.fill"),
    EQOption(name: "复古", icon: "clock.arrow.circlepath"),
    EQOption(name: "现场", icon: "music.mic"),
    EQOption(name: "流行", icon: "music.note"),
    EQOption(name: "摇滚", icon: "guitars"),
]

private struct EQBSheet: View {
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(eqOptions) { opt in
                        Button {
                            selected = opt.name
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: opt.icon)
                                    .font(.system(size: 22))
                                Text(opt.name)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                selected == opt.name
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(selected == opt.name ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                            .foregroundColor(selected == opt.name ? Color.accentColor : .primary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("音效")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 首页单页卡片

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
    @State private var shareItem: SharePayload?
    @State private var lyricLines: [KRCLine] = []
    /// 音效选择弹窗
    @State private var showEQ = false

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
            // 是否为当前播放页（低频：仅切歌时变化）。
            // 高频播放状态（进度/缓冲/时间）只在当前页渲染，离屏页不订阅，
            // 避免歌曲加载多了以后每次 0.1s 进度刷新触发全部页面重算导致卡顿。
            let isCurrent = player.currentIndex == index

            ZStack {
                // 背景：自身忽略安全区延伸到全屏（状态栏 / 底部小白条），不影响上方安全区计算
                background
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    // 顶部标题栏已移到 MainTabView 全局层级（与底部 TabBar 平级），
                    // 这里直接从封面开始（顶部留白由全局 TopBar 占位）
                    Spacer(minLength: 6 + topInset + 50)

                    // 封面区域（1:1 正方形，小圆角，居中）
                    AlbumArt(size: coverSize, title: track.title, coverURL: track.coverURL, radius: 12)

                    // 歌曲名称 + 作者名称：左对齐，左外距与封面一致
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            MarqueeText(
                                text: track.title,
                                font: .system(size: 24, weight: .bold),
                                color: textPrimary(onLight: onLight),
                                active: isCurrent
                            )

                            Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                                .font(.system(size: 15))
                                .foregroundColor(textSecondary(onLight: onLight))
                                .lineLimit(1)
                        }
                        .layoutPriority(1)

                        // 音效按钮：固定最右，显示当前选中的音效名，跑马灯时不被遮住
                        Button {
                            showEQ = true
                        } label: {
                            Text(player.selectedEQ)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(textPrimary(onLight: onLight).opacity(0.85))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    (onLight ? Color.black.opacity(0.08) : Color.white.opacity(0.15)),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .fixedSize()
                        .layoutPriority(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, sidePadding)
                    .padding(.top, 26)

                    // 歌词预览：当前句（逐字填充）+ 下一句，两句滚动播放。
                    // 高频进度状态隔离：仅当前播放页实时渲染，非当前页固定占位保持布局稳定。
                    LiveLyricView(
                        lines: lyricLines,
                        scrubFraction: $scrubFraction,
                        tint: textPrimary(onLight: onLight),
                        isCurrent: isCurrent
                    )
                    .padding(.horizontal, sidePadding)
                    .padding(.top, 10)

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
                    // 拖动时只预览位置，松手才执行 seek。
                    // 高频状态隔离：进度/缓冲/时间/加载失败仅在当前播放页读取，离屏页静态占位。
                    LiveProgressView(
                        scrubFraction: $scrubFraction,
                        tint: textPrimary(onLight: onLight),
                        secondaryTint: textSecondary(onLight: onLight),
                        isCurrent: isCurrent,
                        onLight: onLight
                    )
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
        .sheet(item: $shareItem) { p in
            ShareSheet(text: p.text)
        }
        .sheet(isPresented: $showEQ) {
            EQBSheet(selected: $player.selectedEQ)
                .presentationDetents([.medium])
        }
        .onChange(of: player.selectedEQ) { _ in
            // 切换音效后重新加载当前歌曲
            player.reloadCurrent()
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
        // 分享文案：《歌名》@流萤音乐 短链（汽水音乐风格，短链跳转 H5 分享页）
        let link = await API.shareLink(for: track.id)
        let updated = await API.reportShare(track.id)
        if updated > 0 { shareCount = updated }   // 接口失败时保留本地计数，不被 0 覆盖
        if let link {
            shareItem = SharePayload(text: "《\(track.title)》@流萤音乐 \(link)")
        } else {
            shareItem = SharePayload(text: "《\(track.title)》@流萤音乐")
        }
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
        // 把提取出的主色压暗到约 40%，作为播放页背景（深底白字更沉浸）
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let factor: CGFloat = 0.4
        let dark = UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
        let color = Color(uiColor: dark)
        bgColor = color
        player.playerCardBackgroundLight = false
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

}

// MARK: - 高频播放状态隔离组件（性能关键）

/// 歌词实时预览：只在「当前播放页」渲染并读取播放器高频进度状态。
/// 播放器每 0.1s 更新一次进度，若所有已加载页都读取这些状态，
/// 歌曲加载多了以后每次刷新都要重算全部页面，是首页卡顿掉帧的根源。
/// 这里把高频读取收敛到单个子视图：非当前页不渲染（占位保持布局），
/// 进度刷新只会重算当前页的这一个组件。
private struct LiveLyricView: View {
    @EnvironmentObject private var player: PlayerManager
    let lines: [KRCLine]
    @Binding var scrubFraction: Double?
    let tint: Color
    let isCurrent: Bool

    var body: some View {
        if isCurrent {
            if !lines.isEmpty {
                LyricPreview(
                    lines: lines,
                    progress: (scrubFraction ?? player.progress) * player.duration,
                    tint: tint
                )
            }
        } else if !lines.isEmpty {
            // 非当前页：固定占位保持布局稳定（LyricPreview 视口高度 = 26*2 + 8）
            Color.clear.frame(height: 60)
        }
    }
}

/// 进度条 + 时间 + 加载失败重试：只在「当前播放页」读取播放器高频状态。
/// 结构上分成两层：外层只依赖低频的 isCurrent（切歌才变化），
/// 内层 RealProgressView 才读取 player.progress / buffer / isBuffering / loadFailed / duration。
/// 非当前页时内层不在视图树中，0.1s 的进度刷新不会触达离屏页。
private struct LiveProgressView: View {
    @EnvironmentObject private var player: PlayerManager
    @Binding var scrubFraction: Double?
    let tint: Color
    let secondaryTint: Color
    let isCurrent: Bool
    let onLight: Bool

    var body: some View {
        if isCurrent {
            RealProgressView(scrubFraction: $scrubFraction,
                             tint: tint,
                             secondaryTint: secondaryTint,
                             onLight: onLight)
        } else {
            // 非当前页：固定高度占位（进度条 26 + 间距 10 + 时间行约 15），切页布局不跳动
            VStack(spacing: 10) {
                Color.clear.frame(height: 26)
                Color.clear.frame(height: 15)
            }
        }
    }
}

private struct RealProgressView: View {
    @EnvironmentObject private var player: PlayerManager
    @Binding var scrubFraction: Double?
    let tint: Color
    let secondaryTint: Color
    let onLight: Bool

    var body: some View {
        VStack(spacing: 10) {
            // 音频加载失败：显示重试入口（网络中断/资源损坏时避免静默卡死）
            if player.loadFailed {
                Button {
                    player.reloadCurrent()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                        Text("加载失败，点此重试")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(secondaryTint)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        (onLight ? Color.black.opacity(0.06) : Color.white.opacity(0.14)),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
            PlayerProgressBar(
                progress: player.progress,
                buffer: player.bufferProgress,
                isBuffering: player.isBuffering,
                tint: tint,
                scrubFraction: $scrubFraction,
                onSeek: { fraction in player.seek(toFraction: fraction) }
            )

            HStack {
                Text(formatTime((scrubFraction ?? player.progress) * player.duration))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(secondaryTint)
        }
    }
}
