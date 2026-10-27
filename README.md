# luckyagent-ios

LuckyAgent 的 **iOS 客户端**。手机只当客户端，Agent、模型、记忆、工具仍跑在电脑的 `lh serve`。

和 `yurika0211/luckyagent-android` 并列，调同一套 HTTP / WebSocket API。最初以安卓端 `v0.1.57` 为参考实现核心功能；本次界面核对使用 `v0.1.64` 的源码，并非完整功能移植，具体差异见 [安卓界面源码对照](docs/ANDROID_UI_REFERENCE.md)。

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

界面参考安卓客户端源码：浅色背景 `#f9faf4`，绿色强调 `#3f8a37`，白色圆角卡片，配色与紧凑间距沿用安卓定义。iPhone 使用分组抽屉导航，iPad 保留常驻侧栏，均支持浅色与深色外观。

聊天页使用圆角输入栏，连续的思考与工具记录合并为“思考了 N 步”入口，点击后在底部面板查看实时更新的思考正文与可折叠工具详情。正文保留复制与引用入口。会话列表按真实项目分组，支持折叠、搜索、置顶、重命名和删除确认；设置页按运行时连接、当前会话、配对、连接诊断和外观分组。

聊天中的用户消息、Agent 回复和思考内容支持 GitHub Flavored Markdown：标题、粗体、列表、引用、链接、行内代码、代码块和表格。历史消息和流式回复使用同一渲染方式；代码块支持单独复制，长代码和宽表格在消息内横向滚动。整条消息的「复制」「引用」保留原始 Markdown，工具输出与错误信息保留纯文本。

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

首次构建会通过 Swift Package Manager 下载 MarkdownUI 2.4.1 及其依赖，版本在 `project.yml` 和 `Package.swift` 中固定。

电脑上先 `lh serve`，听 `0.0.0.0:9090`。App → Settings，API Base 填 `http://<电脑局域网 IP>:9090`。也可以把 `lh qr` 打出来的 JSON 贴进「配对二维码内容」。

Settings 的「保存连接」会应用地址与鉴权，「保存并探测」会再请求健康检查；主题选择立即保存。首次连上且没有会话时会创建会话。iPhone 上的 `127.0.0.1` 指手机本身，应填写电脑的局域网地址，并允许 App 访问本地网络。

## 命令行验证

```bash
brew install xcodegen
scripts/verify.sh
```

脚本先运行 macOS 测试，再生成工程并为 iOS Simulator 构建 App 与 XCTest 测试包。覆盖真实 Go 协议样例、HTTP 请求、WebSocket 重连与重放、聊天队列、批准、服务器切换、历史分页，以及 Markdown 的深浅色、宽代码/表格、流式更新渲染和聊天执行记录分组。无需打开 Xcode，也不依赖已安装的模拟器运行时。渲染测试会生成 `build/markdown-preview.png`、`build/chat-design-preview.png` 和 `build/chat-activity-preview.png`，供检查真实共享组件的样式；这些 macOS 离屏预览不代表已完成 iOS 真机交互或大字模式验收。

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
