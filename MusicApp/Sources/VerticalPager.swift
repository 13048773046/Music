import SwiftUI
import UIKit

/// 竖向翻页容器：模仿抖音 / 汽水音乐的上下滑动切歌体验。
/// 基于 UIPageViewController（iOS 16 兼容），滑动停止后回调当前页。
///
/// 性能关键：控制器**懒创建**（滑到哪页才创建哪页），不再一次性为整个队列
/// （可达数百首）预建 UIHostingController + 触发每页的背景主色/歌词网络任务。
/// UIPageViewController 本身只需可见页 + 前后各一页；已创建的页缓存在字典中，
/// 翻回时直接复用（保留点赞/评论等 @State）。
struct VerticalPager: UIViewControllerRepresentable {
    @Binding var currentIndex: Int
    let tracks: [Track]
    /// 队列内容级版本号：变化时强制重建页面缓存。
    /// 原位插入/替换（如通知点击插播）不改变队首且不变短，shouldRebuild 无法识别，
    /// 若不强制重建会复用旧索引缓存页 → 显示信息与播放音频不符。
    let revision: Int
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
            let start = context.coordinator.hasController(at: currentIndex) ? currentIndex : 0
            pvc.setViewControllers(
                [context.coordinator.controller(for: start)],
                direction: .forward,
                animated: false,
                completion: nil
            )
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // 队列内容级变化（通知点击插播等）：队首/长度未变但内容变了，
        // shouldRebuild 识别不到，必须按 revision 强制重建页面缓存，
        // 否则旧索引缓存页会显示错歌信息（播放音频已是新歌）。
        if context.coordinator.lastRevision != revision {
            context.coordinator.rebuild(tracks: tracks)
            context.coordinator.lastRevision = revision
            if context.coordinator.hasController(at: currentIndex) {
                pvc.setViewControllers(
                    [context.coordinator.controller(for: currentIndex)],
                    direction: .forward,
                    animated: false,
                    completion: nil
                )
            }
            return
        }
        // 同步控制器：追加场景无需补建（懒创建）；数据源整体替换（普通流↔相关流）时重建。
        let rebuilt = context.coordinator.syncControllers(for: tracks)
        // 整体替换后旧控制器已不在新列表中，必须立即定位到当前播放索引，
        // 否则 UIPageViewController 仍持有已废弃的页面
        if rebuilt {
            if context.coordinator.hasController(at: currentIndex) {
                pvc.setViewControllers(
                    [context.coordinator.controller(for: currentIndex)],
                    direction: .forward,
                    animated: false,
                    completion: nil
                )
            }
            return
        }
        // 用户正在手势翻页时，禁止程序化 setViewControllers 回跳：
        // 播放器 0.1s timeObserver 会高频触发本方法，若在手势进行中
        // 按 player.currentIndex 强制回跳，会与 didFinishAnimating 的新索引打架，
        // 导致"滑到下一首不播、再滑一首才播上一首"的滞后一首 bug。
        guard !context.coordinator.isUserPaging else { return }
        guard let visible = pvc.viewControllers?.first,
              let visibleIndex = context.coordinator.index(of: visible),
              visibleIndex != currentIndex,
              context.coordinator.hasController(at: currentIndex) else {
            return
        }
        // 自动切歌（播放完/下一首/锁屏切歌）时用翻页动画平滑过渡到下一首，
        // 而不是直接闪现新歌页面：旧页滚出、新页滚入，体验连续不跳变。
        pvc.setViewControllers(
            [context.coordinator.controller(for: currentIndex)],
            direction: visibleIndex < currentIndex ? .forward : .reverse,
            animated: true,
            completion: nil
        )
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalPager
        /// 已创建的页面缓存：索引 → 控制器（懒创建，滑到才建）
        private(set) var controllers: [Int: UIViewController] = [:]
        /// 控制器 → 索引 反向表（before/after 定位用，O(1) 查询）
        private var indexByController: [ObjectIdentifier: Int] = [:]
        /// 与队列一一对应的歌曲 id（用于识别队列来源是否整体替换）
        private var trackIDs: [String] = []
        /// 上次处理的队列版本（revision 变化时强制重建页面缓存）
        var lastRevision = -1
        /// 用户手势正在翻页（willTransitionTo 置位、didFinishAnimating 复位）。
        /// 期间 updateUIViewController 不得程序化回跳，否则会与手势索引打架。
        var isUserPaging = false

        // MARK: 页缓存 LRU 上限（企业级内存防护）
        /// 访问顺序：最近访问在前（LRU 淘汰依据）
        private var accessOrder: [Int] = []
        /// 缓存上限：超过后淘汰最久未访问且不在当前页附近的页面。
        /// 防止长滑数百首后 600+ 个 UIHostingController 常驻内存。
        private let maxCachedPages = 32
        /// 受保护范围：当前页 ± 3（覆盖 UIPageViewController 可见页 + 滑动预取区）
        private var protectedRange: ClosedRange<Int> {
            let center = parent.currentIndex
            return (center - 3)...(center + 3)
        }

        init(_ parent: VerticalPager) {
            self.parent = parent
        }

        /// 获取/懒创建指定索引的页面控制器
        func controller(for index: Int) -> UIViewController {
            if let existing = controllers[index] {
                touch(index)
                return existing
            }
            guard parent.tracks.indices.contains(index) else {
                // 索引越界（极端竞态）：返回一个空白占位页避免崩溃
                let hosting = UIHostingController(rootView: Color.clear)
                hosting.view.backgroundColor = .clear
                controllers[index] = hosting
                indexByController[ObjectIdentifier(hosting)] = index
                touch(index)
                return hosting
            }
            let track = parent.tracks[index]
            let top = Self.windowSafeAreaTop
            let bottom = Self.windowSafeAreaBottom
            let hosting = UIHostingController(
                rootView: PlayerCard(track: track, index: index,
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
            controllers[index] = hosting
            indexByController[ObjectIdentifier(hosting)] = index
            touch(index)
            evictIfNeeded()
            return hosting
        }

        /// 标记访问并把该索引移到最前（LRU）
        private func touch(_ index: Int) {
            accessOrder.removeAll { $0 == index }
            accessOrder.insert(index, at: 0)
        }

        /// 超过缓存上限时淘汰最久未访问且不在当前页附近的页面
        private func evictIfNeeded() {
            guard accessOrder.count > maxCachedPages else { return }
            let protected = protectedRange
            // 先拷贝再遍历：迭代期间修改 accessOrder 会触发「Collection 变异时枚举」崩溃
            for index in Array(accessOrder.reversed()) where !protected.contains(index) {
                guard controllers[index] != nil else { continue }
                let removed = controllers.removeValue(forKey: index)
                if let removed {
                    indexByController.removeValue(forKey: ObjectIdentifier(removed))
                }
                accessOrder.removeAll { $0 == index }
                if accessOrder.count <= maxCachedPages { break }
            }
        }

        /// 控制器反查索引（O(1)）
        func index(of vc: UIViewController) -> Int? {
            indexByController[ObjectIdentifier(vc)]
        }

        /// 指定索引是否在队列范围内（可创建页面）。不依赖已创建缓存：
        /// 整体重建后旧缓存已清空，但当前索引仍应能定位到新队列对应页。
        func hasController(at index: Int) -> Bool {
            parent.tracks.indices.contains(index)
        }

        func rebuild(tracks: [Track]) {
            controllers.removeAll()
            indexByController.removeAll()
            accessOrder.removeAll()
            trackIDs = tracks.map { $0.id }
        }

        /// 同步控制器。返回 true 表示整体重建（数据源切换：普通流 ↔ 相关流）。
        /// - 追加：无需补建（懒创建），保留已建页面（避免翻页位置跳动）
        /// - 替换：新队列变短，或新第一首已不在旧队列中 → 重建全部页
        func syncControllers(for newTracks: [Track]) -> Bool {
            let needRebuild = shouldRebuild(for: newTracks)
            if needRebuild {
                rebuild(tracks: newTracks)
                return true
            }
            trackIDs = newTracks.map { $0.id }
            return false
        }

        /// 判断队列来源是否被整体替换（如搜索相关流 ↔ 发现页普通流）。
        /// 追加场景新第一首仍在旧队列中且长度不减；替换场景反之。
        private func shouldRebuild(for newTracks: [Track]) -> Bool {
            guard !controllers.isEmpty else { return !newTracks.isEmpty }
            guard let firstNew = newTracks.first?.id else { return true }
            return newTracks.count < trackIDs.count || !trackIDs.contains(firstNew)
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
            guard let index = index(of: viewController), index > 0 else { return nil }
            return controller(for: index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController), index < parent.tracks.count - 1 else { return nil }
            return controller(for: index + 1)
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
                  let index = index(of: visible) else { return }
            parent.currentIndex = index
            parent.onPageChanged(index)
        }
    }
}

// MARK: - 音效预设（全部已实现真实音频处理）

struct EQOption: Identifiable {
    let id = UUID().uuidString
    let name: String
    let icon: String
}

private let eqOptions: [EQOption] = [
    EQOption(name: "原音", icon: "speaker.fill"),
    EQOption(name: "3D 立体音效", icon: "wave.3.right.circle.fill"),
    EQOption(name: "360 环绕", icon: "arrow.triangle.2.circlepath.circle.fill"),
    EQOption(name: "复古", icon: "clock.arrow.circlepath"),
    EQOption(name: "现场", icon: "music.mic"),
    EQOption(name: "流行", icon: "music.note"),
    EQOption(name: "摇滚", icon: "guitars"),
]

private struct EQBSheet: View {
    @Binding var selected: String
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(eqOptions) { opt in
                        Button {
                            // 直接应用音效（引擎模式间切换不重载，进度/歌词连续）
                            player.applyEQ(opt.name)
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
    /// 歌曲信息菜单（竖排三点按钮打开）
    @State private var showMenu = false
    @State private var showUserProfile: String?
    /// 菜单内等待执行的后续动作：菜单 sheet dismiss 完成后触发，避免弹窗切换竞态
    @State private var pendingEQ = false
    @State private var pendingFullScreen = false
    @State private var pendingAddToPlaylist = false
    /// 全屏沉浸式歌词
    @State private var showFullScreen = false
    /// 添加到歌单弹窗
    @State private var showPlaylistPicker = false

    init(track: Track, index: Int,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        self.track = track
        self.index = index
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
                    // 这里直接从封面开始（顶部留白由全局 TopBar 占位）。
                    // topInset 为 keyWindow 状态栏真实高度（刘海机 59 / 非刘海 47）；
                    // 47 兜底防注入时机读数异常为 0；+56 为全局 TopBar 完整占位高度，
                    // 保证封面/歌名在任何机型都不会被状态栏或 TopBar 遮挡。
                    Spacer(minLength: 6 + max(topInset, 47) + 56)

                    // 封面区域（1:1 正方形，小圆角，居中）
                    AlbumArt(size: coverSize, title: track.title, coverURL: track.coverURL, radius: 12)

                    // 歌曲名称 + 作者名称：左对齐，左外距与封面一致
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            MarqueeText(
                                text: track.title,
                                font: .system(size: 24, weight: .bold),
                                // 歌名太长会被右侧音效按钮遮住时：缩小字号 + 跑马灯滚动
                                compactFont: .system(size: 18, weight: .semibold),
                                color: textPrimary(onLight: onLight),
                                active: isCurrent
                            )

                            // 发布者名称（点击跳转用户主页）
                            Button {
                                if let uid = track.userId, !uid.isEmpty {
                                    showUserProfile = uid
                                }
                            } label: {
                                Text(track.userName.flatMap { $0.isEmpty ? nil : $0 } ?? "未知用户")
                                    .font(.system(size: 15))
                                    .foregroundColor(textSecondary(onLight: onLight))
                                    .lineLimit(1)
                            }
                        }
                        .layoutPriority(1)

                        // 更多按钮：竖排三点，打开歌曲信息菜单（无背景，仅图标）
                        Button {
                            showMenu = true
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 19, weight: .semibold))
                                .rotationEffect(.degrees(90))
                                .foregroundColor(textPrimary(onLight: onLight))
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
            // 加载歌词：预加载已把歌词入缓存则直接命中（切歌立即显示）；
            // 否则拉取并解析，同时入库供下次/其他页复用
            lyricLines = []
            if let cached = LyricsCache.shared.lines(for: track.id) {
                lyricLines = cached
            } else if track.hasLyric == true {
                if let text = try? await API.fetchLyric(track.id) {
                    lyricLines = parseLyrics(text)
                    if !lyricLines.isEmpty { LyricsCache.shared.store(lyricLines, for: track.id) }
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
                .environmentObject(player)
                .presentationDetents([.medium])
        }
        // 歌曲信息菜单：关闭后按 pending 标记依次打开音效弹窗 / 全屏歌词，
        // 在 onDismiss 回调里触发，规避「上一个 sheet 未完全关闭就弹下一个」的竞态。
        .sheet(isPresented: $showMenu, onDismiss: {
            if pendingEQ { pendingEQ = false; showEQ = true }
            if pendingFullScreen { pendingFullScreen = false; showFullScreen = true }
            if pendingAddToPlaylist { pendingAddToPlaylist = false; showPlaylistPicker = true }
        }) {
            TrackMenuSheet(
                track: track,
                eqName: player.selectedEQ,
                onEQ: { pendingEQ = true; showMenu = false },
                onFullScreen: { pendingFullScreen = true; showMenu = false },
                onAddToPlaylist: { pendingAddToPlaylist = true; showMenu = false }
            )
            .presentationDetents([.height(400)])
            .presentationDragIndicator(.visible)
        }
        // 用户主页弹窗
        .sheet(item: $showUserProfile) { uid in
            UserProfileView(userId: uid)
                .environmentObject(player)
                .environmentObject(auth)
        }
        // 全屏沉浸式歌词：onDismiss 兜底复位方向授权并强制转回竖屏。
        // 主界面 OrientationVC 是 child controller，dismiss 后不会自动触发
        // viewWillAppear，若不显式 setValue(.portrait) 设备会停在横屏。
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            FullScreenOrientation.shared.isFullScreen = false
            DispatchQueue.main.async {
                UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            }
        }) {
            FullScreenLyricView(track: track, lines: lyricLines)
                .environmentObject(player)
                .landscapeFullScreen()
        }
        // 添加到歌单弹窗
        .sheet(isPresented: $showPlaylistPicker) {
            AddToPlaylistSheet(track: track)
                .environmentObject(auth)
        }
        // 音效切换统一走 EQBSheet 的 player.applyEQ（引擎同类切换不重载、进度连续），
        // 不再监听 selectedEQ 变化重载整曲。
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
            // 行为上报：点赞/取消赞（取消赞 value=-1）
            let ev = API.BehaviorEvent(trackId: track.id, event: "like",
                                       value: r.liked ? 1 : -1)
            Task { await API.reportBehavior([ev]) }
        } catch {}
    }

    private func share() async {
        // 分享文案：《歌名》@流萤音乐 短链（汽水音乐风格，短链跳转 H5 分享页）
        let link = await API.shareLink(for: track.id)
        let updated = await API.reportShare(track.id)
        if updated > 0 { shareCount = updated }   // 接口失败时保留本地计数，不被 0 覆盖
        // 行为上报：分享成功
        let ev = API.BehaviorEvent(trackId: track.id, event: "share", value: 1)
        Task { await API.reportBehavior([ev]) }
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
    /// 切歌瞬间背景回退深色渐变 → 文字保持白色，避免「浅色文字配深色背景」闪烁；
    /// 主色提取完成后按亮度动态切换文字颜色。
    private func loadBackground() async {
        bgColor = nil
        player.playerCardBackgroundLight = false
        guard let url = track.coverURL else { return }
        let ui = await CoverPalette.color(for: track.id, from: url)
        // 共享原始封面主色给侧边栏（侧边栏自行压暗到 0.3，比播放页更暗）
        player.playerCardDominant = ui
        // 把提取出的主色压暗到约 40%，作为播放页背景（深底白字更沉浸）
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let factor: CGFloat = 0.4
        let dark = UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
        let color = Color(uiColor: dark)
        bgColor = color
        // 背景色就绪后才更新导航栏亮度（深底白字 / 浅底深字）
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

}

// MARK: - 歌曲信息菜单（播放页 ⋮ 三点按钮）

/// 上半：封面 + 歌名/歌手/专辑信息；下半：操作项（音效 → 关本弹窗后开音效弹窗；全屏播放）。
private struct TrackMenuSheet: View {
    let track: Track
    let eqName: String
    var onEQ: () -> Void
    var onFullScreen: () -> Void
    var onAddToPlaylist: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 歌曲信息卡：封面 + 标题 / 歌手 / 专辑
            HStack(spacing: 14) {
                AlbumArt(size: 60, title: track.title, coverURL: track.coverURL, radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let album = track.album, !album.isEmpty {
                        Text("专辑 · \(album)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 18)

            Divider().padding(.horizontal, 20)

            // 添加到歌单：关闭本弹窗，随后（onDismiss）打开歌单选择弹窗
            Button {
                dismiss()
                onAddToPlaylist()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .frame(width: 26)
                    Text("添加到歌单")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 音效：关闭本弹窗，随后（onDismiss）打开音效选择弹窗
            Button {
                dismiss()
                onEQ()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .frame(width: 26)
                    Text("音效")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(eqName)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 全屏播放：关闭本弹窗，随后（onDismiss）进入全屏沉浸式歌词
            Button {
                dismiss()
                onFullScreen()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .frame(width: 26)
                    Text("全屏播放")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
    }
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
            } else {
                // 无歌词：歌词区显示「作者·歌手名」停留 5 秒 → 平滑过渡到「该歌曲暂无歌词」
                // → 持续显示直到歌曲结束（不循环）。
                // 视口高度与 LyricPreview 一致 = 60，布局稳定不跳动。
                // .id 按歌曲绑定：切歌重建组件、重新计时，每首歌都从「作者行停留」开始。
                NoLyricPlaceholder(author: player.current?.displayAuthor ?? "未知歌手",
                                   tint: tint)
                    .id(player.current?.id ?? "no-lyric")
            }
        } else if !lines.isEmpty {
            // 非当前页：固定占位保持布局稳定（LyricPreview 视口高度 = 26*2 + 8）
            Color.clear.frame(height: 60)
        }
    }
}

/// 无歌词占位：作者·歌手名 + 「该歌曲暂无歌词」，替代原本空白歌词区。
/// 用 TimelineView(.animation) 时间轴驱动，与正常歌词 LyricPreview 同款单调滚动 + 缩放/淡出过渡：
/// 「作者·歌手名」停留 hold 秒（默认 5s）→ 平滑滚动到「该歌曲暂无歌词」→ **停住，不循环**，
/// 持续显示直到歌曲结束。高度与 LyricPreview 视口一致（60），保证有/无歌词切歌时页面不跳动。
private struct NoLyricPlaceholder: View {
    let author: String
    let tint: Color

    private static let hold: Double = 5.0       // 第一行「作者·歌手名」停留时长（秒）
    private static let scroll: Double = 0.28    // 滚到第二行的过渡时长（秒，与正常歌词一致）
    private static let rowGap: CGFloat = 8
    private static let step: CGFloat = 32       // 第一行行高24 + 间距8，滚动位移
    private static let viewHeight: CGFloat = 60

    /// 组件创建时刻（相对计时基准）：TimelineView 的 date 是 2001 年起算的绝对时间，
    /// 直接 `t < hold` 判断恒为假（2026 年约 8.1e8 秒），会导致第一行从不显示——
    /// 必须减去创建时刻得到「本首歌」的经过秒数。
    @State private var startRef: TimeInterval = Date().timeIntervalSinceReferenceDate

    /// 滚动单调化追踪器：class 引用属性不触发 SwiftUI 重绘，过渡阶段只增不减不回弹
    private final class Tracker { var maxT: Double = 0; var lastC: Int = -2 }
    @State private var tracker = Tracker()

    var body: some View {
        TimelineView(.animation) { ctx in
            // 相对创建时刻的经过秒数：0 → hold 为作者行停留期，之后过渡到暂无歌词
            let t = ctx.date.timeIntervalSinceReferenceDate - startRef
            // 目标行：第一行停留 hold 秒后滚到第二行，单向到达后停住（不循环）
            let c = t < Self.hold ? 0 : 1
            // 滚动进度：进入第二行后 0→1；第一行停留期为 0
            let seg = t < Self.hold ? 0 : min(max((t - Self.hold) / Self.scroll, 0), 1)
            // 切行重置 + 滚动进度单调化（副作用在辅助函数中完成，ViewBuilder 内只声明式调用）
            let _ = advanceTracker(c: c, seg: seg)
            let raw = tracker.maxT
            let eased = 1 - (1 - raw) * (1 - raw) * (1 - raw)   // easeOutCubic
            let scrolling = raw < 1
            // 位移：滚到第二行时上移 step（用 eased 插值），到顶后停住
            let offsetY = -Self.step * eased

            VStack(spacing: Self.rowGap) {
                placeholderRow("作者·\(author)", size: 20, weight: .medium,
                               isCur: c == 0, isOld: c == 1,
                               scrolling: scrolling, eased: eased)
                placeholderRow("该歌曲暂无歌词", size: 15, weight: .regular,
                               isCur: c == 1, isOld: false,
                               scrolling: scrolling, eased: eased)
            }
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.viewHeight, alignment: .top)
            .clipped()
        }
        .frame(height: Self.viewHeight, alignment: .top)
    }

    /// 切行重置 + 滚动进度单调化：ViewBuilder 里不允许直接写 if 副作用语句，
    /// 收敛到本辅助函数，在 body 内以 `let _ = advanceTracker(...)` 声明式调用
    private func advanceTracker(c: Int, seg: Double) {
        if c != tracker.lastC { tracker.lastC = c; tracker.maxT = 0 }
        if seg > tracker.maxT { tracker.maxT = seg }
    }

    /// 单行过渡动画（与正常歌词 LyricPreview 一致）：
    /// 当前行滚动期从 0.8 放大到 1.0；被替换行（旧行）同步缩小淡出。
    private func placeholderRow(_ text: String, size: CGFloat, weight: Font.Weight,
                                isCur: Bool, isOld: Bool, scrolling: Bool, eased: Double) -> some View {
        let scale: Double = isCur
            ? (scrolling ? 0.8 + 0.2 * eased : 1.0)
            : (isOld ? 1.0 - 0.15 * eased : 0.8)
        let opacity = isOld ? (1 - eased) : 1.0
        return Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundColor(tint.opacity(isCur ? 0.92 : 0.45))
            .lineLimit(1)
            .scaleEffect(scale, anchor: .leading)
            .opacity(opacity)
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

            // 原音 → 引擎无缝切换：后台预下载进度反馈（切换瞬间不打断播放，
            // 就绪后自动接管；此提示让用户知道正在准备音效）
            if player.engineSwitchInProgress {
                Text("音效加载中 \(Int(player.engineDownloadFraction * 100))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(secondaryTint)
            }

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

// MARK: - 添加到歌单弹窗

private struct AddToPlaylistSheet: View {
    let track: Track
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var showCreate = false
    @State private var newPlaylistName = ""
    @State private var isCreating = false
    @State private var showSuccess = false
    @State private var successText = ""
    @State private var errorText = ""
    @State private var addingToPlaylistId: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playlists.isEmpty {
                    // 没有歌单，显示去创建
                    VStack(spacing: 20) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("还没有歌单")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                        Button {
                            showCreate = true
                        } label: {
                            Text("去创建歌单")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Theme.accent))
                        }
                    }
                } else {
                    // 歌单列表
                    List {
                        ForEach(playlists) { pl in
                            Button {
                                addToPlaylist(pl)
                            } label: {
                                HStack(spacing: 12) {
                                    CachedCoverImage(
                                        url: URL(string: pl.cover) ?? URL(string: "about:blank")!,
                                        title: pl.name,
                                        placeholder: RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft)
                                            .overlay(Image(systemName: "music.note").foregroundColor(Theme.accent))
                                    )
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(pl.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text("\(pl.trackCount) 首歌曲")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    
                                    if addingToPlaylistId == pl.id {
                                        ProgressView()
                                            .tint(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(addingToPlaylistId != nil)
                        }

                        // 创建新歌单按钮
                        Button {
                            showCreate = true
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.accent.opacity(0.15))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(Theme.accent)
                                }
                                Text("创建新歌单")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Theme.accent)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreate) {
                createSheet
            }
            .overlay {
                if showSuccess {
                    successView
                } else if !errorText.isEmpty {
                    errorView
                }
            }
        }
        .task { await loadPlaylists() }
    }

    private var createSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("歌单名称", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                Button {
                    Task { await createAndAdd() }
                } label: {
                    if isCreating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("创建并添加")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.accent))
                .padding(.horizontal, 20)
                .disabled(newPlaylistName.isEmpty || isCreating)

                Spacer()
            }
            .navigationTitle("创建新歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { showCreate = false }
                }
            }
        }
    }

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Theme.accent)
            Text(successText)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text(errorText)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }

    private func loadPlaylists() async {
        do {
            let list = try await API.fetchPlaylists()
            playlists = list
        } catch {
            print("加载歌单失败: \(error)")
        }
        isLoading = false
    }

    private func addToPlaylist(_ pl: Playlist) {
        addingToPlaylistId = pl.id
        Task {
            do {
                try await API.addToPlaylist(
                    playlistId: pl.id,
                    trackId: track.id,
                    title: track.title,
                    artist: track.artist ?? "未知歌手",
                    cover: track.coverURL?.absoluteString ?? ""
                )
                successText = "已添加到 \(pl.name)"
                showSuccess = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                dismiss()
            } catch {
                errorText = "添加失败: \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                errorText = ""
            }
            addingToPlaylistId = nil
        }
    }

    private func createAndAdd() async {
        isCreating = true
        do {
            let pid = try await API.createPlaylist(name: newPlaylistName)
            await API.addToPlaylist(
                playlistId: pid,
                trackId: track.id,
                title: track.title,
                artist: track.artist ?? "未知歌手",
                cover: track.coverURL?.absoluteString ?? ""
            )
            showCreate = false
            successText = "已创建并添加"
            showSuccess = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            dismiss()
        } catch {
            print("创建歌单失败: \(error)")
        }
        isCreating = false
    }
}
