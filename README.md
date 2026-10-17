# luckyagent-ios

LuckyAgent 的 **iOS 客户端**。手机只当客户端，Agent、模型、记忆、工具仍跑在电脑的 `lh serve`。

和 `yurika0211/luckyagent-android` 并列，调同一套 HTTP / WebSocket API。功能面对齐安卓端 `v0.1.57`。

## 页面

| 安卓 | iOS |
|---|---|
| Chat | `ChatView`：流式回复、工具卡片、批准与补充输入、停止、会话搜索和置顶、模型切换、压缩、附件上传与预览、发送队列 |
| Tasks | `TasksView` |
| Background | `BackgroundView`：autonomy 队列和 worker |
| Cron | `CronView` |
| Trace | `TraceView` |
| Gateways | `GatewaysView` |
| Skills | `SkillsView`：skills + commands，支持运行命令并查看结果 |
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

Settings 的「保存连接」会应用地址与鉴权，「保存并探测」会再请求健康检查；主题选择立即保存。首次连上且没有会话时会创建会话。iPhone 上的 `127.0.0.1` 指手机本身，应填写电脑的局域网地址，并允许 App 访问本地网络。

## 命令行验证

```bash
brew install xcodegen
scripts/verify.sh
```

脚本先运行 macOS 核心测试，再生成工程并为 iOS Simulator 构建 App 与 XCTest 测试包。覆盖真实 Go 协议样例、HTTP 请求、WebSocket 重连与重放、聊天队列、批准、服务器切换和历史分页。无需打开 Xcode，也不依赖已安装的模拟器运行时。

```bash
# 仅运行核心测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 有对应模拟器运行时后，在 iOS 上执行 XCTest
xcodebuild -project LuckyAgent.xcodeproj -scheme LuckyAgent \
  -destination 'platform=iOS Simulator,name=<已安装的模拟器名称>' \
  CODE_SIGNING_ALLOWED=NO test
```

默认模拟器产物：`build/DerivedData/Build/Products/Debug-iphonesimulator/LuckyAgent.app`。工程文件由 `project.yml` 生成，不提交到 Git。

协议样例依据 LuckyAgent 服务端 `8e41aa1` 的 HTTP 与 WebSocket 实现。单元测试与通用模拟器构建不代表已完成真机、实际模型调用或签名发布验收。

## CI

`.github/workflows/ios.yml`

| 触发 | 做什么 |
|---|---|
| push / PR | 运行核心测试，构建模拟器 App 与测试包，上传 `.app` zip |
| tag `v*` | 配了签名 secrets 才出真机 `.ipa` 并挂到 Release |

签名没配时 tag 构建会跳过真机包，不会失败。步骤在 [docs/SIGNING.md](docs/SIGNING.md)。

## 和安卓的差别

- 没做相机实时扫码。配对先贴 `lh qr` 的 JSON。装上签名后可以再加 `AVFoundation` 扫码。
- 没做应用内录音。附件走相册和文件。
- Memory graph 只显示节点数和边数，和安卓当前一样，没有力导向图。
- 公式渲染用纯文本，没有安卓那套 LaTeX 视图。
- 聊天发送队列已对齐安卓：回复还在跑时，后面的消息排队，一轮结束再发下一条。失败的留着可重试，不挡住后面的。停止会丢掉正在发的和还排着的。
- 重连会从服务端持久化事件 cursor 续接。同一次运行中切换会话会保留草稿、聊天和队列；进入后台只断开连接，电脑上的任务继续执行。若发送回执丢失且服务端无法确认状态，会提示先刷新历史，再决定是否重试。
- 客户端待发送队列保存在内存中；强制退出后不恢复尚未送达服务器的消息。

## 目录

```text
Sources/        SwiftUI App、API、WebSocket、页面
Tests/          协议、HTTP、WebSocket、聊天状态与页面展示规则回归测试
Package.swift   无模拟器依赖的 macOS 核心测试目标
scripts/        本地与 CI 共用的验证入口
project.yml     XcodeGen 工程描述
.github/        Actions
docs/SIGNING.md
```
