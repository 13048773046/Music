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
            controllers = tracks.map { track in
                UIHostingController(
                    rootView: PlayerCard(track: track)
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

/// 首页单页卡片：沉浸式播放界面（封面 + 信息 + 进度 + 控制）
struct PlayerCard: View {
    @EnvironmentObject private var player: PlayerManager
    let track: Track

    private var isCurrent: Bool {
        player.current?.id == track.id
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer(minLength: 60)

                AlbumArt(size: 300, title: track.title, coverURL: track.coverURL)
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
                    .scaleEffect(isCurrent && player.isPlaying ? 1.0 : 0.97)
                    .animation(
                        isCurrent && player.isPlaying
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .default,
                        value: isCurrent && player.isPlaying
                    )

                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(track.artist ?? "未知歌手")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 28)

                Spacer()

                VStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { player.progress },
                            set: { player.seek(toFraction: $0) }
                        ),
                        in: 0...1
                    )
                    .tint(.purple)

                    HStack {
                        Text(formatTime(player.currentTime))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(player.duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 60) {
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.toggle()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 68))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 30)

                Spacer(minLength: 44)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var background: some View {
        if let url = track.coverURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 90)
                        .opacity(0.55)
                } else {
                    defaultBackground
                }
            }
            .ignoresSafeArea()
        } else {
            defaultBackground
        }
    }

    private var defaultBackground: some View {
        LinearGradient(
            colors: [.purple.opacity(0.38), .blue.opacity(0.24), .black.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
