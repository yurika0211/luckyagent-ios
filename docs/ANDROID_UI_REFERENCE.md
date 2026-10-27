# 安卓界面源码对照

核对日期：2026-10-20。参考仓库 [yurika0211/luckyagent-android](https://github.com/yurika0211/luckyagent-android)，版本 `0.1.64`（versionCode 52），固定提交 [`678c0a0adcf3721a3aa574842fca81af207d4d3e`](https://github.com/yurika0211/luckyagent-android/tree/678c0a0adcf3721a3aa574842fca81af207d4d3e)，提交日期 2026-10-18。

本机参考副本位于 `build/reference/luckyagent-android`，来自该提交的源码归档，不是独立 Git checkout，不参与 iOS 构建。

## 已核对的实现

| 安卓源码 | 实际实现 | iOS 对应 |
|---|---|---|
| [Color.kt](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/theme/Color.kt#L8) | 背景 `F9FAF4`、强调 `3F8A37`、用户气泡 `E9EFD9`，以及独立深色配色 | `Theme.swift` 使用相同颜色值 |
| [SectionChrome.kt](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/components/SectionChrome.kt#L134) | 卡片横向 14、纵向 12 间距，medium 形状半径 16，边框透明度 35% | `cloverCard` 对应紧凑间距与圆角，保留不透明表面 |
| [ChatScreen.kt — BubbleRow](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/screens/ChatScreen.kt#L1266) | 用户气泡靠右、半径 18、横向 12 / 纵向 10 间距；助手正文直接排版 | `ChatMessageContent` |
| [ChatScreen.kt — ComposerBar](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/screens/ChatScreen.kt#L2264) | 输入栏半径 28、紧凑边距、无阴影 | `ChatComposerBar`，保留附件、发送与排队操作 |
| [ChatScreen.kt — ProcessTimeline / ThinkingSheet](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/screens/ChatScreen.kt#L1820) | “思考了 N 步”打开底部面板；思考正文直接显示，工具详情可折叠 | `ChatActivityGroup` / `ActivitySheet`，按首条记录 ID 查询当前分组，保留流式更新、复制、引用与附件预览 |
| [LuckyAgentAppRoot.kt — NavigationPage](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/LuckyAgentAppRoot.kt#L417) | 品牌、连接状态、分组导航和底部设置 | `Sidebar`，只显示已实现页面 |
| [ChatScreen.kt — SessionDrawer](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/screens/ChatScreen.kt#L3919) | 搜索、置顶/项目分组、当前会话、会话操作 | `SessionSheet` 使用原生底部面板，保留分组与操作 |

## 仍存在的差异

- 截图中的背景图是本地相册导入。安卓 [SettingsAppearanceCard](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/screens/SettingsScreen.kt#L202) 提供背景、遮罩、输入条/气泡/顶栏/卡片/侧栏五项透明度以及字体和字号设置。默认背景文件为空；iOS 当前只提供跟随系统/浅色/深色主题。
- 安卓 [SettingsEndpointCard](https://github.com/yurika0211/luckyagent-android/blob/678c0a0adcf3721a3aa574842fca81af207d4d3e/app/src/main/java/com/luckyagent/android/ui/screens/SettingsScreen.kt#L454) 管理多个运行时并支持切换、相机扫码和相册识码；iOS 当前编辑一个运行时，支持粘贴配对 JSON。
- 安卓有插件、运行时配置、会话项目修改、语音、上下文用量与运行详情等入口；会话栏的九宫格图标用于打开功能导航。iOS 本次视觉调整没有补齐这些数据与功能。
- iOS 保留原生导航与无障碍交互；源码对照不表示像素级复刻，也不表示真机验收。

## 本轮验证

`scripts/verify.sh`：96 项 macOS 测试通过，iOS Simulator App 和 XCTest 测试包构建成功。聊天与思考详情共享组件检查了 320 / 390 宽度下的深浅色布局，预览输出在 `build/chat-design-preview.png` 和 `build/chat-activity-preview.png`。没有启动模拟器、App 或 `lh`，底部面板交互与真机显示仍需在设备上验收。
