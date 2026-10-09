# luckyagent-ios

LuckyAgent 的 **iOS 客户端**。手机只当客户端，Agent、模型、记忆、工具仍跑在电脑的 `lh serve`。

和 `yurika0211/luckyagent-android` 并列，调同一套 HTTP / WebSocket API。功能面对齐安卓端 `v0.1.57`。

## 页面

| 安卓 | iOS |
|---|---|
| Chat | `ChatView`：流式回复、工具卡片、停止、会话、模型切换、压缩、附件、发送队列 |
| Tasks | `TasksView` |
| Background | `BackgroundView`：autonomy 队列和 worker |
| Cron | `CronView` |
| Trace | `TraceView` |
| Gateways | `GatewaysView` |
| Skills | `SkillsView`：skills + commands |
| Memory | `MemoryView`：recall、tier、graph 数量 |
| Settings | `SettingsView`：地址、Key、主题、`lh qr` 配对 |

主题色跟安卓一致：bg `#f8f5ee`，accent `#356f42`。iPad 宽屏用侧栏，iPhone 用菜单切换。

## 协议

- `GET /api/v1/health/live`、`/soul`、`/models`、`POST /models/switch`
- `GET|POST|PATCH|DELETE /api/v1/sessions`，历史分页，`/compact`
- `WS /api/v1/ws?session=...`
- 事件：`stream_chunk`、`reasoning`、`tool_call`、`tool_result`、`status`、`approval`、`stream_end`、`error`、`cancel`
- `POST /api/v1/uploads` 附件
- memory、gateways、skills、commands、cron、tasks、autonomy、approvals、context

鉴权：Bearer 或 `X-API-Key`。`lh qr` 的临时 token 走 `X-API-Key`，和安卓一样。Key 放 Keychain，不进仓库。

## 本地打开

需要 Mac、Xcode 16 左右。

```bash
brew install xcodegen
xcodegen generate
open LuckyAgent.xcodeproj
```

模拟器直接 Run。真机签名看 [docs/SIGNING.md](docs/SIGNING.md)。

电脑上先 `lh serve`，听 `0.0.0.0:9090`。App → Settings，API Base 填 `http://<电脑局域网 IP>:9090`。也可以把 `lh qr` 打出来的 JSON 贴进「配对二维码内容」。

## CI

`.github/workflows/ios.yml`

| 触发 | 做什么 |
|---|---|
| push / PR | 在 macOS 上编模拟器包，上传 `.app` zip |
| tag `v*` | 配了签名 secrets 才出真机 `.ipa` 并挂到 Release |

签名没配时 tag 构建会跳过真机包，不会失败。步骤在 [docs/SIGNING.md](docs/SIGNING.md)。

## 和安卓的差别

- 没做相机实时扫码。配对先贴 `lh qr` 的 JSON。装上签名后可以再加 `AVFoundation` 扫码。
- 没做应用内录音。附件走相册和文件。
- Memory graph 只显示节点数和边数，和安卓当前一样，没有力导向图。
- 公式渲染用纯文本，没有安卓那套 LaTeX 视图。
- 聊天发送队列已对齐安卓：回复还在跑时，后面的消息排队，一轮结束再发下一条。失败的留着可重试，不挡住后面的。停止会丢掉正在发的和还排着的。

## 目录

```text
Sources/        SwiftUI App、API、WebSocket、页面
Tests/          配对码解析
project.yml     XcodeGen 工程描述
.github/        Actions
docs/SIGNING.md
```
