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
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        context.coordinator.rebuild(tracks: tracks)
        if !tracks.isEmpty {
            pvc.setViewControllers(
                [context.coordinator.controllers[currentIndex]],
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
                UIHostingController(
                    rootView: PlayerCard(track: track, index: index, total: total)
                        .environmentObject(PlayerManager.shared)
                )
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

// MARK: - 首页单页卡片：汽水音乐风格全屏播放页（清新浅色版）

struct PlayerCard: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let index: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom

            ZStack {
                background

                VStack(spacing: 0) {
                    // 顶部标题栏：App 名 + 播放模式
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, safeTop + 6)

                    Spacer()

                    // 歌曲信息 + 播放控制（叠在背景上）
                    VStack(alignment: .leading, spacing: 0) {
                        infoSection
                            .padding(.horizontal, 26)

                        controlsSection
                            .padding(.horizontal, 26)
                            .padding(.top, 26)
                    }
                    .padding(.bottom, safeBottom + 96)
                }
            }
            .clipped()
        }
        .id(track.id)
    }

    // MARK: - 背景：封面铺满 + 提亮 + 底部渐变保证文字可读

    @ViewBuilder
    private var background: some View {
        ZStack {
            if let url = track.coverURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        fallbackGradient
                    }
                }
            } else {
                fallbackGradient
            }

            // 提亮为浅色调
            Color.white.opacity(0.62)
            // 顶部更亮，保证标题栏可读
            LinearGradient(
                colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            // 底部渐变，保证文字可读
            LinearGradient(
                colors: [Color.white.opacity(0.0), Color.white.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var fallbackGradient: some View {
        LinearGradient(
            colors: [Color(hex: 0xE2F5EE), Color(hex: 0xF0EAFB)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - 顶部标题栏

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.accent)
                Text("流萤音乐")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
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
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.85), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 歌曲信息区

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                if let album = track.album, !album.isEmpty {
                    Text("· \(album)")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .lineLimit(1)

            Text(track.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)

            // 标识行：时长 / 播放进度位次
            HStack(spacing: 8) {
                tagLabel(icon: "clock", text: track.durText ?? "--:--")
                tagLabel(icon: "list.number", text: "第 \(index + 1) / \(total) 首")
            }
        }
    }

    private func tagLabel(icon: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.accentSoft, in: Capsule())
    }

    // MARK: - 播放控制区

    private var controlsSection: some View {
        VStack(spacing: 14) {
            // 进度条
            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.seek(toFraction: $0) }
                ),
                in: 0...1
            )
            .tint(Theme.accent)

            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundColor(Theme.textSecondary)

            // 控制按钮
            HStack(spacing: 50) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 26))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)

                Button {
                    player.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 74, height: 74)
                            .shadow(color: Theme.softShadow, radius: 12, x: 0, y: 6)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34))
                            .foregroundColor(Theme.accent)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 26))
                        .foregroundColor(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }
}
