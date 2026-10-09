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

// MARK: - 首页单页卡片：正方形封面置顶 + 歌名/作者 + 拖动条（清新浅色版）

struct PlayerCard: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track
    let index: Int
    let total: Int

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            // 封面加大约40%：几乎满宽，左外距很小
            let coverSize = max(geo.size.width - 28, 260)
            // 封面居中后的左外距（歌名/作者与之对齐）
            let sidePadding = (geo.size.width - coverSize) / 2

            ZStack {
                background

                VStack(spacing: 0) {
                    // 顶部标题栏：App 名 + 播放模式
                    topBar
                        .padding(.horizontal, 20)
                        .padding(.top, safeTop + 6)

                    Spacer(minLength: 12)

                    // 1:1 正方形封面（小圆角，居中，左外距很小）
                    AlbumArt(size: coverSize, title: track.title, coverURL: track.coverURL, radius: 12)

                    // 歌曲名称 + 作者名称：左对齐，左外距与封面一致
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)

                        Text(track.artist.flatMap { $0.isEmpty ? nil : $0 } ?? "未知歌手")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, sidePadding)
                    .padding(.top, 26)

                    Spacer(minLength: 12)

                    // 拖动条 + 时间
                    VStack(spacing: 10) {
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
                    }
                    .padding(.horizontal, sidePadding)

                    // 底部留白（TabBar 空间）
                    Spacer(minLength: 76)
                }
                .frame(maxWidth: .infinity)
            }
            .clipped()
        }
        .id(track.id)
    }

    // MARK: - 背景：清新浅色渐变

    private var background: some View {
        LinearGradient(
            colors: [Color(hex: 0xF2F9F6), Color(hex: 0xF7F3FA)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
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
}
