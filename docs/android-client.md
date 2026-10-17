# 流萤音乐 Android 客户端

Jetpack Compose 原生安卓客户端，1:1 复刻 iOS SwiftUI 版 UI 与交互逻辑。

## 技术栈

- **语言**：Kotlin
- **UI**：Jetpack Compose（Material3）
- **网络**：OkHttp + kotlinx.serialization
- **图片**：Coil
- **音频**：Media3 ExoPlayer（含 SimpleCache 缓存）
- **WebSocket**：OkHttp WebSocket（实时通知/行为上报）
- **DI**：手动单例（object PlayerManager / AuthManager / NotificationBus）

## 目录结构

```
android/
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/app/star2936/guava3291/
│       │   ├── MainActivity.kt          # 入口：生命周期监听 WS/音量
│       │   ├── MusicApplication.kt      # Application：初始化缓存/预加载
│       │   ├── state/                   # 全局状态
│       │   │   ├── PlayerManager.kt     # 播放器（队列/模式/通知/EQ）
│       │   │   ├── AuthManager.kt       # 登录态/切换账号
│       │   │   ├── NotificationBus.kt   # WebSocket 实时通知
│       │   │   ├── AppRouter.kt         # 跨页跳转（评论/用户主页）
│       │   │   └── AppPreloader.kt      # 启动预加载
│       │   ├── data/                    # 数据层
│       │   │   ├── Api.kt               # REST API
│       │   │   ├── Models.kt            # 数据模型
│       │   │   └── BehaviorEvent.kt
│       │   ├── ui/                      # Compose UI
│       │   │   ├── main/                # 主框架（TabBar + 侧边栏）
│       │   │   ├── home/                # 播放页（竖滑 Pager + 歌词）
│       │   │   ├── discover/            # 发现页
│       │   │   ├── mine/                # 我的页面
│       │   │   ├── notifications/        # 消息通知
│       │   │   ├── sidebar/             # 侧边栏
│       │   │   ├── search/              # 搜索
│       │   │   ├── upload/             # 上传歌曲
│       │   │   └── theme/               # 主题色
│       │   └── util/                    # 工具
│       │       ├── ColorPalette.kt      # 封面主色提取
│       │       ├── KRCLine.kt           # 逐字歌词解析
│       │       └── PlayerSession.kt     # 播放会话持久化
│       └── res/                         # 资源（图标/字符串）
├── build.gradle.kts
├── settings.gradle.kts
└── gradle.properties
```

## 构建

```bash
# 需要 JDK 17 + Android SDK 34 + Gradle 8.9
export JAVA_HOME=/path/to/jdk-17
cd android
gradle assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
```

## 与 iOS 的对应关系

| iOS (SwiftUI) | Android (Compose) |
|---|---|
| PlayerManager.swift | state/PlayerManager.kt |
| AuthManager.swift | state/AuthManager.kt |
| NotificationBus (AppRouter.swift) | state/NotificationBus.kt |
| AppRouter.swift | state/AppRouter.kt |
| SidebarView.swift | ui/sidebar/SidebarContent.kt |
| HomeView.swift + VerticalPager.swift | ui/home/HomeScreen.kt |
| DiscoverView.swift | ui/discover/DiscoverScreen.kt |
| MineView.swift | ui/mine/MineScreen.kt |
| NotificationsView.swift | ui/notifications/NotificationsScreen.kt |
| API.swift | data/Api.kt |
| Library.swift | state/AppPreloader.kt + Library 逻辑 |

## 核心特性

1. **竖滑切歌**：VerticalPager，滑动结束 settledPage 才回调，自动切歌 animateScrollToPage 跟随
2. **听歌模式**：默认/我的作品/我的喜欢/新鲜模式，会话缓存切换
3. **WebSocket 实时通知**：25s 心跳，指数退避重连（1s→60s），收到推送自动刷新通知列表
4. **MediaStyle 系统通知**：封面/歌曲名/作者/上一首/暂停/下一首，ForwardingPlayer override seekToPrevious/NextMediaItem
5. **SimpleCache**：歌曲流缓存，弱网续播
6. **封面主色提取**：ColorPalette 提取封面主色，播放页/侧边栏背景跟随

## 适配说明

- 最低 SDK：26（Android 8.0）
- 目标 SDK：34（Android 14），兼容到 Android 16
- 通知权限：Android 13+ 运行时申请 POST_NOTIFICATIONS
- 沉浸式：背景延伸到状态栏/导航栏，内容避让
