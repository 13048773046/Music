import SwiftUI

// MARK: - 加载状态

enum LoadState: Equatable {
    case loading
    case loaded
    case empty
    case failed(String)
}

// MARK: - 封面组件（支持真实封面图，无封面时用柔和渐变占位）

struct AlbumArt: View {
    let size: CGFloat
    let title: String
    var coverURL: URL? = nil
    var radius: CGFloat? = nil

    var body: some View {
        Group {
            if let coverURL {
                CachedCoverImage(url: coverURL, title: title, placeholder: placeholder)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius ?? size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius ?? size * 0.22, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    private var placeholder: some View {
        let (c1, c2) = paletteFrom(title)
        return ZStack {
            LinearGradient(
                colors: [c1, c2],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private func paletteFrom(_ text: String) -> (Color, Color) {
        var hash = 0
        for scalar in text.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return Theme.placeholderPalettes[hash % Theme.placeholderPalettes.count]
    }
}

// MARK: - 封面图内存缓存（避免重复下载/解码）

final class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    /// 清理全部封面内存缓存（设置页「清理缓存」）
    func clear() {
        cache.removeAllObjects()
    }
}

// MARK: - 歌词内存缓存（配合预加载：切歌时歌词立即命中，无需等待网络）

/// 已解析歌词的内存缓存：trackId → [KRCLine]。预加载时提前拉取并解析入库，
/// 播放页切歌时先查缓存再回退网络，避免切到下一首歌词区还转圈。
/// NSCache 自动淘汰（内存压力/上限），线程安全无需自加锁。
final class LyricsCache {
    static let shared = LyricsCache()
    private let cache = NSCache<NSString, NSArray>()

    func lines(for id: String) -> [KRCLine]? {
        cache.object(forKey: id as NSString) as? [KRCLine]
    }

    func store(_ lines: [KRCLine], for id: String) {
        cache.setObject(lines as NSArray, forKey: id as NSString)
    }

    /// 清理全部歌词缓存（设置页「清理缓存」）
    func clear() {
        cache.removeAllObjects()
    }
}

/// 带内存缓存的封面图：首次下载后缓存，切页/列表重建不再重复请求
struct CachedCoverImage<Placeholder: View>: View {
    let url: URL
    let title: String
    let placeholder: Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
                    .task { await load() }
            }
        }
    }

    private func load() async {
        if let cached = CoverImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                CoverImageCache.shared.store(img, for: url)
                image = img
            }
        } catch {
            // 下载失败保留占位图
        }
    }
}

// MARK: - 播放中声波动画

struct EqualizerBars: View {
    var color: Color = Theme.accent
    @State private var animate = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: animate ? 14 : 6)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: animate
                    )
            }
        }
        .frame(height: 16)
        .onAppear { animate = true }
    }
}

// MARK: - 列表行（白色卡片行）

struct TrackRow: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let onTap: () -> Void

    private var isCurrent: Bool {
        player.current?.id == track.id
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AlbumArt(size: 52, title: track.title, coverURL: track.coverURL, radius: 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(Theme.textPrimary)
                    HStack(spacing: 4) {
                        Text(track.displayAuthor)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        if let pc = track.playCount, pc > 0 {
                            Text("· 播放 \(pc)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                Spacer()

                // 右侧状态：未播放=竖三点；当前播放=跳动三竖条；当前暂停=静止三竖条
                if isCurrent {
                    if player.isPlaying {
                        EqualizerBars()
                    } else {
                        // 暂停的当前歌曲：静止三根竖条
                        HStack(spacing: 2.5) {
                            Capsule().fill(Theme.accent).frame(width: 2.5, height: 10)
                            Capsule().fill(Theme.accent).frame(width: 2.5, height: 10)
                            Capsule().fill(Theme.accent).frame(width: 2.5, height: 10)
                        }
                        .frame(width: 20, height: 16)
                    }
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                        .rotationEffect(.degrees(90))
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

/// 系统分享 sheet 桥接（分享文本内容）
struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 分享载荷：歌曲名@流萤音乐 + 隐藏式分享链接
struct SharePayload: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - 通用时间格式化

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

// MARK: - 空态 / 错误态通用视图

struct StatusPlaceholder: View {
    let icon: String
    let title: String
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 88, height: 88)
                Image(systemName: icon)
                    .font(.system(size: 36))
                    .foregroundColor(Theme.accent)
            }
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            if let retry {
                Button(action: retry) {
                    Text("重试")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 多功能进度条（已播放段 + 已缓冲段 + 缓冲加载动画 + 拖动预览松手 seek）

/// 同一根进度条表达三层信息：
/// - 淡色轨道：整段歌曲时长
/// - 中浅段（buffer）：已经缓冲到的位置（来自 AVPlayerItem.loadedTimeRanges）
/// - 纯色段（progress）：当前播放位置
/// - 拖头：普通态是 10pt 小圆点；缓冲中（网络卡顿/加载）变为 20pt 旋转圆环动画
/// 拖动过程只更新预览位置，松手才回调 onSeek，避免频繁 seek 打断播放。
struct PlayerProgressBar: View {
    var progress: Double        // 当前播放位置 0...1
    var buffer: Double          // 已缓冲位置 0...1
    var isBuffering: Bool       // 是否正在缓冲（显示加载动画）
    var tint: Color = .white
    /// 拖动中的预览位置（由父视图持有，时间标签同步显示预览时间）
    @Binding var scrubFraction: Double?
    var onSeek: (Double) -> Void

    private var shown: Double { scrubFraction ?? progress }

    private func clamped(_ f: Double) -> Double { min(max(f, 0), 1) }
    private func pointX(_ f: Double, width: CGFloat) -> CGFloat {
        CGFloat(clamped(f)) * width
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // 总轨道
                Capsule()
                    .fill(tint.opacity(0.18))
                    .frame(height: 3)
                // 已缓冲段（比播放段浅，一眼看出缓存到哪里）
                Capsule()
                    .fill(tint.opacity(0.38))
                    .frame(width: pointX(buffer, width: width), height: 3)
                // 已播放段
                Capsule()
                    .fill(tint)
                    .frame(width: pointX(shown, width: width), height: 3)

                // 缓冲中：一条白线在轨道上从左快速扫到右循环（不确定进度动画）
                if isBuffering, scrubFraction == nil {
                    LoadingSweep(tint: tint)
                }

                // 拖头：缓冲中也保持小圆点（不再转圈）
                Circle().fill(tint).frame(width: 10, height: 10)
                    .offset(x: pointX(shown, width: width) - 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        scrubFraction = clamped(g.location.x / max(width, 1))
                    }
                    .onEnded { g in
                        onSeek(clamped(g.location.x / max(width, 1)))
                        scrubFraction = nil
                    }
            )
        }
        .frame(height: 26)
    }
}

/// 缓冲加载动画：一条短白线在轨道上从左快速扫到右，循环往复（不确定进度）
/// 高度限到 3pt，与轨道线重合，不浮在进度条空白区。
private struct LoadingSweep: View {
    let tint: Color
    /// 段起始位置 0...1（-0.25 表示从轨道左外侧进入）
    @State private var phase: CGFloat = -0.25

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule()
                .fill(tint)
                .frame(width: w * 0.25, height: 3)
                .offset(x: phase * w)
        }
        .frame(height: 3)   // 关键：限高 3pt，ZStack 垂直居中后正好压在轨道线上
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}

// MARK: - 跑马灯文字（长标题自动水平无缝滚动，短标题静止）

struct MarqueeText: View {
    let text: String
    let font: Font
    /// 溢出（文字超出可用宽度，会被右侧按钮挡住）时使用的紧凑字号；nil = 不缩小
    var compactFont: Font? = nil
    let color: Color
    /// 滚动速度（pt/秒）
    var speed: CGFloat = 50
    /// 每次滚动前停顿秒数
    var pause: TimeInterval = 1.2
    /// 是否允许滚动：非当前播放页传 false，离屏页不再跑 repeatForever 动画，减少卡顿
    var active: Bool = true

    @State private var textWidth: CGFloat = 0    // 原字号单份文字宽
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// 原字号文字是否超出容器（即会被右侧音效按钮挡住）：只据此触发缩小 + 滚动
    private var overflow: Bool { textWidth > containerWidth + 4 && containerWidth > 0 }
    /// 显示字号：溢出（被按钮挡住）时用紧凑字号缩小
    private var displayFont: Font { overflow ? (compactFont ?? font) : font }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 50) {
                Text(text).font(displayFont).foregroundColor(color).fixedSize()
                if overflow {
                    Text(text).font(displayFont).foregroundColor(color).fixedSize()
                }
            }
            .background(
                GeometryReader { tgeo in
                    Color.clear.onAppear {
                        containerWidth = geo.size.width
                    }
                }
            )
            .overlay(alignment: .leading) {
                // 隐藏的原字号文本：精确测量「是否会被右侧按钮挡住」，与显示字号解耦。
                // 避免缩小字号后溢出判断跟着变、导致不滚动的误判。
                Text(text).font(font).fixedSize().hidden()
                    .background(
                        GeometryReader { orig in
                            Color.clear.onAppear { textWidth = orig.size.width }
                        }
                    )
            }
            .offset(x: offset)
            .onAppear { start(container: geo.size.width) }
            .onChange(of: text) { _ in restart(container: geo.size.width) }
            .onChange(of: active) { newValue in
                if newValue {
                    restart(container: containerWidth)
                } else {
                    // 非当前页：停止滚动并归位，避免离屏动画持续消耗
                    withAnimation(nil) { offset = 0 }
                }
            }
        }
        .frame(height: 30)
        .clipped()
    }

    private func start(container: CGFloat) {
        containerWidth = container
        guard active else { return }
        // 等一帧拿到 textWidth（background onAppear 可能晚于主 onAppear）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard active, overflow else { return }
            let distance = textWidth + 50
            withAnimation(
                .linear(duration: Double(distance / speed))
                .delay(pause)
                .repeatForever(autoreverses: false)
            ) {
                offset = -distance
            }
        }
    }

    private func restart(container: CGFloat) {
        offset = 0
        start(container: container)
    }
}
