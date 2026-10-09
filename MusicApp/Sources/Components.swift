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
    @EnvironmentObject private var auth: AuthManager
    let track: Track
    let onTap: () -> Void

    @State private var liked: Bool
    @State private var likeCount: Int
    @State private var showComments = false
    @State private var shareURL: URL?

    init(track: Track, onTap: @escaping () -> Void) {
        self.track = track
        self.onTap = onTap
        _liked = State(initialValue: track.isLiked ?? false)
        _likeCount = State(initialValue: track.likeCount ?? 0)
    }

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

                // 点赞
                Button {
                    Task { await toggleLike() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 15))
                            .foregroundColor(liked ? .red : Theme.textTertiary)
                        if likeCount > 0 {
                            Text("\(likeCount)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                // 评论
                Button { showComments = true } label: {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textTertiary)
                }
                .buttonStyle(.plain)

                // 分享
                Button {
                    Task { await share() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textTertiary)
                }
                .buttonStyle(.plain)

                if isCurrent {
                    if player.isPlaying {
                        EqualizerBars()
                    } else {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.accent)
                    }
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showComments) {
            CommentSheet(track: track)
                .environmentObject(auth)
                .environmentObject(player)
        }
        .sheet(item: $shareURL) { u in
            ShareSheet(url: u)
        }
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
        await API.reportShare(track.id)
        // 分享歌曲流式地址给朋友
        shareURL = API.streamURL(track.id)
    }
}

/// 系统分享 sheet 桥接
extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url.absoluteString], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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

                // 拖头：缓冲中显示旋转加载动画，否则是小圆点
                Group {
                    if isBuffering, scrubFraction == nil {
                        BufferSpinner(tint: tint).frame(width: 20, height: 20)
                    } else {
                        Circle().fill(tint).frame(width: 10, height: 10)
                    }
                }
                .offset(x: pointX(shown, width: width) - (isBuffering && scrubFraction == nil ? 10 : 5))
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

/// 缓冲加载动画：3/4 圆弧持续旋转
private struct BufferSpinner: View {
    let tint: Color
    @State private var rotate = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotate = true
                }
            }
    }
}
