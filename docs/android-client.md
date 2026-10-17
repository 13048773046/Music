# 流萤音乐 Android 客户端

Jetpack Compose 原生安卓客户端，1:1 复刻 iOS SwiftUI 版 UI 与交互逻辑。

> 详细说明已并入仓库主交接文档「八、Android 前端（Jetpack Compose）完整说明」（v15）；本文档为精简版技术说明。

## 工程信息

- **语言 / UI**：Kotlin / Jetpack Compose（Material3），Compose BOM 2024.09.03
- **包名**：`app.star2936.guava3291`（与 iOS Bundle ID 一致）
- **SDK**：minSdk 29（Android 10）/ targetSdk 35 / compileSdk 35
- **版本**：1.0.0（versionCode 1）
- **构建**：Gradle 8.9 + JDK 17，release 未混淆

## 技术栈

- **网络**：OkHttp + kotlinx.serialization
- **图片**：Coil
- **音频**：Media3 ExoPlayer（SimpleCache 200MB LRU 流缓存 + ForwardingPlayer + 弱网自愈）
- **WebSocket**：OkHttp WebSocket（实时通知/行为上报，25s 心跳 + 指数退避重连）
- **安全存储**：EncryptedSharedPreferences（登录态 + 播放会话）
- **DI**：手动单例（object PlayerManager / AuthManager / NotificationBus / Library / WeatherContext）

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
│       │   │   ├── PlayerManager.kt     # 播放器（队列/模式/通知/EQ/弱网自愈）
│       │   │   ├── AuthManager.kt       # 登录态/切换账号
│       │   │   ├── NotificationBus.kt   # WebSocket 实时通知
│       │   │   ├── AppState.kt          # PlayerSession（会话持久化）+ AppPreloader + AppRouter
│       │   │   ├── Library.kt           # 曲库全局单例
│       │   │   ├── WeatherContext.kt    # 定位 + 天气×时段场景
│       │   │   └── PlaybackService.kt   # 前台媒体服务（系统通知/锁屏）
│       │   ├── data/                    # 数据层
│       │   │   ├── Api.kt               # REST API
│       │   │   └── Models.kt            # 数据模型（含 BehaviorEvent）
│       │   ├── ui/                      # Compose UI
│       │   │   ├── main/                # 主框架（TabBar + 侧边栏 + 子页栈）
│       │   │   ├── home/                # 播放页（竖滑 Pager + 歌词 + 三点菜单）
│       │   │   ├── discover/            # 发现页（猜你喜欢 + 天气卡片）
│       │   │   ├── mine/                # 我的页面（三 Tab + 听歌时长）
│       │   │   ├── notifications/       # 消息通知（分页）+ 官方消息
│       │   │   ├── sidebar/             # 侧边栏（听歌模式 + 场景音乐）
│       │   │   ├── search/              # 搜索（历史 + 结果流）
│       │   │   ├── upload/              # 上传歌曲
│       │   │   ├── settings/            # 设置/切换账号/改密/资料编辑/关于
│       │   │   ├── profile/             # 用户主页
│       │   │   ├── playlists/           # 歌单列表/详情
│       │   │   ├── history/             # 播放历史
│       │   │   ├── login/               # 登录/注册
│       │   │   ├── comment/             # 评论弹窗
│       │   │   ├── components/          # 通用组件（CoverImage/MarqueeText 等）
│       │   │   ├── splash/              # 启动页
│       │   │   └── theme/               # 主题色
│       │   └── util/                    # 工具
│       │       ├── ColorPalette.kt      # 封面主色提取
│       │       ├── LyricsParser.kt      # KRC/LRC 歌词解析
│       │       └── TimeFormat.kt        # 时间/日期格式化
│       └── res/                         # 资源（图标/字符串）
├── build.gradle.kts
├── settings.gradle.kts
└── gradle.properties
```

## 构建

```bash
# 需要 JDK 17 + Android SDK 35 + Gradle 8.9
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
