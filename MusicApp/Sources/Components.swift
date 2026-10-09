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
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
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
            HStack(spacing: 14) {
                AlbumArt(size: 52, title: track.title, coverURL: track.coverURL, radius: 14)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(Theme.textPrimary)
                    HStack(spacing: 4) {
                        if let artist = track.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                        if let durText = track.durText, durText != "--:--" {
                            Text("· \(durText)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                }

                Spacer()

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
                        .font(.system(size: 22))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
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

// MARK: - 细滑块（小尺寸拖头：轨道 3pt、滑块 10pt，点击/拖动均可）

struct ThinSlider: View {
    @Binding var value: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let ratio = min(max(value, 0), 1)
            let thumbSize: CGFloat = 10

            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(height: 3)
                // 已播放段
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, width * ratio), height: 3)
                // 小滑块
                Circle()
                    .fill(tint)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: max(0, min(width - thumbSize, width * ratio - thumbSize / 2)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let r = min(max(g.location.x / max(width, 1), 0), 1)
                        value = r
                    }
            )
        }
        .frame(height: 26)
    }
}
