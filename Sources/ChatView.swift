import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var showSessions = false
    @State private var showModels = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            sessionBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if model.isLoadingHistory { ProgressView("加载消息…").frame(maxWidth: .infinity) }
                        if model.hasOlderHistory {
                            Button("加载更早的消息") { Task { await model.loadOlder() } }
                                .font(.caption)
                                .buttonStyle(CloverActionButtonStyle())
                                .frame(maxWidth: .infinity)
                                .disabled(model.isLoadingHistory || model.socketState == .running)
                        }
                        if model.lines.isEmpty && !model.isLoadingHistory { welcome }
                        ForEach(ChatTimelineSection.group(model.lines)) { section in
                            if section.isActivity {
                                ActivityRow(lines: section.lines)
                            } else if let line = section.lines.first {
                                MessageRow(line: line)
                            }
                        }
                        ForEach(model.approvals) { approval in ApprovalCard(approval: approval) }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.lines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: model.lines.last?.text) { _, _ in
                    if model.lines.last?.streaming == true { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
            }
        }
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showModels = true } label: {
                    HStack(spacing: 6) {
                        Text(model.models.first(where: { $0.current && $0.kind == "chat" })?.label ?? "模型")
                            .font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel("切换模型")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await model.newSession() } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建会话")
                    .disabled(model.busy || model.isStopping || model.isCompacting)
                Menu {
                    Button("会话列表", systemImage: "rectangle.stack") { showSessions = true }
                    Button("切换模型", systemImage: "cpu") { showModels = true }
                    Button("刷新消息", systemImage: "arrow.clockwise") { Task { await model.loadHistory() } }
                        .disabled(model.activeSessionId.isEmpty || model.socketState == .running || model.isLoadingHistory)
                    Button("压缩会话", systemImage: "arrow.down.right.and.arrow.up.left") { Task { await model.compactSession() } }
                        .disabled(model.activeSessionId.isEmpty || model.socketState != .connected || model.isCompacting || model.isStopping)
                    Button("连接设置", systemImage: "gearshape") { model.destination = .settings }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("更多聊天操作")
            }
        }
        .sheet(isPresented: $showSessions) { SessionSheet() }
        .sheet(isPresented: $showModels) { ModelSheet() }
        .task(id: model.models.isEmpty) {
            if model.models.isEmpty { await model.loadModels() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): model.banner = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quoteLine)) { notification in
            guard let text = notification.object as? String else { return }
            model.draft += (model.draft.isEmpty ? "" : "\n\n") + text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { return }
                    let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) && $0.preferredFilenameExtension != nil }) ?? .jpeg
                    await model.upload(data: data, name: "photo.\(type.preferredFilenameExtension ?? "jpg")", mime: type.preferredMIMEType ?? "image/jpeg")
                } catch { model.banner = "读取照片失败：\(error.localizedDescription)" }
                photoItem = nil
            }
        }
    }

    private var sessionBar: some View {
        HStack(spacing: 10) {
            Button { showSessions = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(currentTitle).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(stateLabel).font(.caption)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 20)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(scheme == .dark ? Clover.darkAccent : Clover.accent)
                .frame(width: 80, height: 80)
                .background(scheme == .dark ? Clover.darkUser : Clover.user, in: RoundedRectangle(cornerRadius: 28))
            Text("开始一段对话").font(.title2.weight(.semibold))
            Text("发条消息，让 LuckyAgent 帮你处理。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.activeSessionId.isEmpty {
                Button("连接运行时") { model.destination = .settings }
                    .buttonStyle(CloverActionButtonStyle(prominent: true))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            outboundStrip
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "paperclip")
                                Text(item.fileName ?? item.type).lineLimit(1)
                                Button { model.pendingAttachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("移除附件 \(item.fileName ?? item.type)")
                            }
                            .font(.caption).padding(10)
                            .background(scheme == .dark ? Clover.darkSurface : Clover.surface, in: Capsule())
                        }
                    }
                }
            }
            if model.socketState == .running || model.isStopping {
                HStack {
                    Text(model.isStopping ? "正在停止…" : "正在回复，后续消息将排队")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.stop() } label: { Label("停止", systemImage: "stop.fill") }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(model.isStopping)
                }
            }
            ChatComposerBar(text: $model.draft, canSend: canSend, queued: model.socketState == .running) {
                Menu {
                    PhotosPicker("从相册选择", selection: $photoItem, matching: .images)
                    Button("选择文件", systemImage: "doc") { showImporter = true }
                } label: { Image(systemName: "plus") }
                .disabled(model.isUploading)
                .accessibilityLabel("添加附件")
            } onSend: { model.send() }
            if model.isUploading { ProgressView("上传附件…").font(.caption) }
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
    }

    @ViewBuilder private var outboundStrip: some View {
        let items = model.outbound.visible(sessionId: model.activeSessionId)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.status == .failed ? "exclamationmark.circle" : "clock")
                            .foregroundStyle(item.status == .failed ? Clover.error : Clover.warning)
                        Text(item.status == .sending ? "发送中" : (item.status == .failed ? "发送失败" : "等待发送"))
                            .font(.caption.weight(.medium))
                        Text(item.preview).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        if item.status == .failed { Button("重试") { model.retryOutbound(item.id) }.font(.caption) }
                        if item.status != .sending {
                            Button { model.dropOutbound(item.id) } label: { Image(systemName: "xmark") }
                                .frame(minWidth: 30, minHeight: 30)
                                .accessibilityLabel("移除待发送消息")
                        }
                    }
                    if let error = item.error { Text(error).font(.caption).foregroundStyle(Clover.error) }
                }
            }
            .padding(12)
            .background(scheme == .dark ? Clover.darkSurface : Clover.tool, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var canSend: Bool {
        !model.isUploading && !model.isLoadingHistory && !model.isStopping && !model.isCompacting
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty)
    }

    private var currentTitle: String {
        model.sessions.first { $0.id == model.activeSessionId }?.displayTitle
            ?? (model.activeSessionId.isEmpty ? "选择会话" : "当前会话")
    }

    private var stateLabel: String {
        switch model.socketState {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .running: return "运行中"
        case .reconnecting: return "重连中"
        case .closed: return "已断开"
        case .error: return "连接异常"
        }
    }

    private var stateColor: Color {
        switch model.socketState {
        case .connected, .running: return scheme == .dark ? Clover.darkAccent : Clover.accent
        case .connecting, .reconnecting: return Clover.warning
        default: return .secondary
        }
    }

    private func importFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            await model.upload(data: data, name: url.lastPathComponent, mime: mime)
        } catch { model.banner = "读取文件失败：\(error.localizedDescription)" }
    }
}

struct MessageRow: View {
    var line: ChatLine
    @EnvironmentObject private var model: AppModel
    @State private var previewURL: URL?
    @State private var downloading = false

    var body: some View {
        ChatMessageContent(line: line, downloading: downloading,
                           onCopy: { UIPasteboard.general.string = line.text },
                           onQuote: { NotificationCenter.default.post(name: .quoteLine, object: line.text) },
                           onPreview: { attachment in
            Task {
                downloading = true
                previewURL = await model.previewAttachment(attachment)
                downloading = false
            }
        })
        .quickLookPreview($previewURL)
    }
}

private struct ActivityRow: View {
    var lines: [ChatLine]
    @EnvironmentObject private var model: AppModel
    @State private var previewURL: URL?
    @State private var downloading = false

    var body: some View {
        ChatActivityGroup(lines: lines, downloading: downloading,
                          onCopy: { UIPasteboard.general.string = $0.text },
                          onQuote: { NotificationCenter.default.post(name: .quoteLine, object: $0.text) },
                          onPreview: { attachment in
            Task {
                downloading = true
                previewURL = await model.previewAttachment(attachment)
                downloading = false
            }
        })
        .quickLookPreview($previewURL)
    }
}

extension Notification.Name { static let quoteLine = Notification.Name("quoteLine") }

struct ApprovalCard: View {
    @EnvironmentObject private var model: AppModel
    var approval: PendingApproval
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.title ?? "需要确认").font(.headline)
            if let prompt = approval.prompt { Text(prompt).font(.footnote) }
            if approval.secure {
                SecureField("输入内容", text: $input).textFieldStyle(.roundedBorder)
            } else {
                TextField("补充说明，可空", text: $input).textFieldStyle(.roundedBorder)
            }
            HStack {
                if approval.kind == "input" || approval.kind == "credential" {
                    Button("提交") { model.resolve(approval: approval, decision: "submit", input: input) }.buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消", role: .cancel) { model.resolve(approval: approval, decision: "cancel", input: "") }
                } else if !approval.options.isEmpty {
                    ForEach(approval.options) { option in
                        Button(option.label) { model.resolve(approval: approval, decision: option.id, input: input) }.buttonStyle(.bordered)
                    }
                } else {
                    Button("允许") { model.resolve(approval: approval, decision: "allow", input: input) }.buttonStyle(.borderedProminent)
                    Button("拒绝", role: .destructive) { model.resolve(approval: approval, decision: "deny", input: input) }
                }
            }
            .disabled(model.resolvingApprovalId != nil)
            if model.resolvingApprovalId == approval.stableId { ProgressView("提交中…") }
        }
        .cloverCard()
    }
}

struct ModelSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0) { kind, models in
                    Section(kind) {
                        ForEach(models) { modelRef in
                            Button {
                                Task { await model.switchModel(modelRef); dismiss() }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(modelRef.label)
                                        Text(modelRef.provider ?? "").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if modelRef.current { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { CloverBackground() }
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await model.loadModels() }
        }
    }

    private var grouped: [(String, [ModelRef])] {
        Dictionary(grouping: model.models, by: { $0.kind }).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}
