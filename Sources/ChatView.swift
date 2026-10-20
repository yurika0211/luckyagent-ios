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
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.isLoadingHistory { ProgressView("加载消息…").frame(maxWidth: .infinity) }
                        if model.hasOlderHistory {
                            Button("加载更早的消息") { Task { await model.loadOlder() } }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(model.isLoadingHistory || model.socketState == .running)
                        }
                        if model.lines.isEmpty && !model.isLoadingHistory {
                            ContentUnavailableView {
                                Label(model.activeSessionId.isEmpty ? "开始一段对话" : "会话已就绪", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text(model.activeSessionId.isEmpty ? "连接电脑后，新建或选择会话。" : "发送消息或添加附件，与电脑上的 Agent 对话。")
                            } actions: {
                                if model.activeSessionId.isEmpty {
                                    Button("新建会话") { Task { await model.newSession() } }.buttonStyle(.borderedProminent)
                                    Button("连接设置") { model.destination = .settings }
                                }
                            }
                        }
                        ForEach(model.lines) { line in
                            MessageRow(line: line).id(line.id)
                        }
                        ForEach(model.approvals) { approval in
                            ApprovalCard(approval: approval)
                        }
                    }
                    .padding(12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: model.lines.last?.text) { _, _ in
                    if let last = model.lines.last, last.streaming { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
        }
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .sheet(isPresented: $showSessions) { SessionSheet() }
        .sheet(isPresented: $showModels) { ModelSheet() }
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
                } catch {
                    model.banner = "读取照片失败：\(error.localizedDescription)"
                }
                photoItem = nil
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showSessions = true } label: { Image(systemName: "sidebar.left") }.accessibilityLabel("会话列表")
            VStack(alignment: .leading, spacing: 0) {
                Text(currentTitle).font(.headline).lineLimit(1)
                Text(model.socketState.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showModels = true } label: { Image(systemName: "cpu") }.accessibilityLabel("切换模型")
            Button { Task { await model.loadHistory() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.activeSessionId.isEmpty || model.socketState == .running || model.isLoadingHistory)
                .accessibilityLabel("刷新历史消息")
            Button { Task { await model.compactSession() } } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .accessibilityLabel("压缩会话")
                .disabled(model.activeSessionId.isEmpty || model.socketState != .connected || model.isCompacting || model.isStopping)
            Button(role: .destructive) { model.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(model.socketState != .running)
                .accessibilityLabel("停止当前回复")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            outboundStrip
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.pendingAttachments) { item in
                            HStack(spacing: 4) {
                                Text(item.fileName ?? item.type).lineLimit(1)
                                Button { model.pendingAttachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("移除附件 \(item.fileName ?? item.type)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(scheme == .dark ? Clover.darkSurface : Clover.tool, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker("相册", selection: $photoItem, matching: .images)
                    Button("文件") { showImporter = true }
                } label: { Image(systemName: "plus.circle") }
                .disabled(model.isUploading)
                .accessibilityLabel("添加附件")
                if model.isUploading { ProgressView().controlSize(.small) }
                TextField("说点什么", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(scheme == .dark ? Clover.darkSurface : Clover.surface, in: RoundedRectangle(cornerRadius: 16))
                Button { model.send() } label: {
                    Image(systemName: sendSymbol).font(.title2).foregroundStyle(Clover.accent)
                }
                .disabled(model.isUploading || model.isLoadingHistory || model.isStopping || model.isCompacting || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty))
                .accessibilityLabel(model.socketState == .running ? "排队发送" : "发送")
            }
        }
        .padding(12)
    }

    @ViewBuilder private var outboundStrip: some View {
        let items = model.outbound.visible(sessionId: model.activeSessionId)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.status == .failed ? "exclamationmark.circle" : "clock")
                            .foregroundStyle(item.status == .failed ? Clover.error : Clover.warning)
                        Text(item.status == .sending ? "发送中" : (item.status == .failed ? "失败" : "排队"))
                            .font(.caption2.weight(.semibold))
                        Text(item.preview).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        if item.status == .failed {
                            Button("重试") { model.retryOutbound(item.id) }.font(.caption2)
                        }
                        if item.status != .sending {
                            Button { model.dropOutbound(item.id) } label: { Image(systemName: "xmark") }
                                .font(.caption2)
                        }
                    }
                    if let error = item.error { Text(error).font(.caption2).foregroundStyle(Clover.error) }
                }
            }
            .padding(8)
            .background(scheme == .dark ? Clover.darkSurface : Clover.tool, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var sendSymbol: String {
        model.socketState == .running ? "text.line.first.and.arrowtriangle.forward" : "arrow.up.circle.fill"
    }

    private var currentTitle: String {
        model.sessions.first { $0.id == model.activeSessionId }?.displayTitle ?? (model.activeSessionId.isEmpty ? "未选择会话" : model.activeSessionId)
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
    @Environment(\.colorScheme) private var scheme
    @State private var previewURL: URL?
    @State private var downloading = false

    var body: some View {
        HStack {
            if line.kind == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                if line.kind == .tool {
                    HStack {
                        Image(systemName: "wrench")
                        Text(line.toolName ?? "tool").font(.caption.weight(.semibold))
                        Spacer()
                        Text(line.toolState ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if line.kind == .reasoning {
                    Text("思考").font(.caption2).foregroundStyle(.secondary)
                }
                if line.kind.rendersMarkdown {
                    ChatMarkdownView(text: line.text, compact: line.kind == .reasoning)
                } else {
                    Text(line.text.isEmpty ? "…" : line.text)
                        .font(line.kind == .tool ? .caption : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(line.attachments) { attachment in
                    Button {
                        Task {
                            downloading = true
                            previewURL = await model.previewAttachment(attachment)
                            downloading = false
                        }
                    } label: {
                        Label(attachment.fileName ?? attachment.type, systemImage: "paperclip")
                            .font(.footnote).lineLimit(2)
                    }
                    .disabled(downloading)
                }
                if downloading { ProgressView("下载附件…").font(.caption) }
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            .contextMenu {
                Button("复制") { UIPasteboard.general.string = line.text }
                Button("引用") { NotificationCenter.default.post(name: .quoteLine, object: line.text) }
            }
            if line.kind != .user { Spacer(minLength: 24) }
        }
        .quickLookPreview($previewURL)
    }

    private var background: Color {
        switch line.kind {
        case .user: return scheme == .dark ? Clover.darkUser : Clover.user
        case .tool: return scheme == .dark ? Clover.darkSurface : Clover.tool
        case .error: return Clover.error.opacity(0.12)
        case .reasoning, .status, .system: return .clear
        case .assistant: return .clear
        }
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

struct SessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: RuntimeSession?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索会话", text: $model.sessionQuery)
                        .onSubmit { Task { await model.refreshSessions() } }
                    Button("新建会话") { Task { await model.newSession(); dismiss() } }
                }
                Section("会话") {
                    ForEach(model.sessions) { session in
                        Button {
                            Task { await model.selectSession(session); dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if session.pinned { Image(systemName: "pin.fill").font(.caption2) }
                                    Text(session.displayTitle).foregroundStyle(.primary)
                                }
                                Text(session.updatedAt ?? session.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button("重命名") { renaming = session; newTitle = session.displayTitle }
                            Button("删除", role: .destructive) { Task { await model.deleteSession(session) } }
                        }
                        .swipeActions(edge: .leading) {
                            Button(session.pinned ? "取消置顶" : "置顶") { Task { await model.togglePin(session) } }.tint(Clover.accent)
                        }
                    }
                }
            }
            .navigationTitle("会话")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("标题", text: $newTitle)
                Button("保存") {
                    if let session = renaming { Task { await model.renameSession(session, title: newTitle) } }
                    renaming = nil
                }
                Button("取消", role: .cancel) { renaming = nil }
            }
            .task { await model.refreshSessions() }
        }
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
            .navigationTitle("模型")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await model.loadModels() }
        }
    }

    private var grouped: [(String, [ModelRef])] {
        Dictionary(grouping: model.models, by: { $0.kind }).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}
