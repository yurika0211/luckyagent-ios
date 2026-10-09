import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
                        Button("加载更早的消息") { Task { await model.loadOlder() } }
                            .font(.footnote)
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        ForEach(model.lines) { line in
                            MessageRow(line: line).id(line.id)
                        }
                        ForEach(model.approvals) { approval in
                            ApprovalCard(approval: approval)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .sheet(isPresented: $showSessions) { SessionSheet() }
        .sheet(isPresented: $showModels) { ModelSheet() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.upload(data: data, name: "photo.jpg", mime: "image/jpeg")
                }
                photoItem = nil
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showSessions = true } label: { Image(systemName: "sidebar.left") }
            VStack(alignment: .leading, spacing: 0) {
                Text(currentTitle).font(.headline).lineLimit(1)
                Text(model.socketState.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showModels = true } label: { Image(systemName: "cpu") }
            Button { Task { await model.compactSession() } } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
            Button(role: .destructive) { model.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(model.socketState != .running)
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
                            Text(item.fileName ?? item.type)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Clover.tool, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker("相册", selection: $photoItem, matching: .images)
                    Button("文件") { showImporter = true }
                } label: { Image(systemName: "plus.circle") }
                TextField("说点什么", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(scheme == .dark ? Clover.darkSurface : Clover.surface, in: RoundedRectangle(cornerRadius: 16))
                Button { model.send() } label: {
                    Image(systemName: sendSymbol).font(.title2).foregroundStyle(Clover.accent)
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingAttachments.isEmpty)
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
                }
            }
            .padding(8)
            .background(Clover.tool, in: RoundedRectangle(cornerRadius: 12))
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
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await model.upload(data: data, name: url.lastPathComponent, mime: mime)
    }
}

struct MessageRow: View {
    var line: ChatLine
    @Environment(\.colorScheme) private var scheme

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
                Text(line.text.isEmpty ? "…" : line.text)
                    .font(line.kind == .tool || line.kind == .reasoning ? .caption : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(background, in: RoundedRectangle(cornerRadius: 14))
            .contextMenu {
                Button("复制") { UIPasteboard.general.string = line.text }
                Button("引用") { NotificationCenter.default.post(name: .quoteLine, object: line.text) }
            }
            if line.kind != .user { Spacer(minLength: 24) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quoteLine)) { _ in }
    }

    private var background: Color {
        switch line.kind {
        case .user: return scheme == .dark ? Clover.darkUser : Clover.user
        case .tool: return Clover.tool
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
            TextField("补充说明，可空", text: $input).textFieldStyle(.roundedBorder)
            HStack {
                Button("允许") { model.resolve(approval: approval, decision: "allow", input: input) }
                    .buttonStyle(.borderedProminent)
                Button("拒绝", role: .destructive) { model.resolve(approval: approval, decision: "deny", input: input) }
            }
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
                    }
                }
            }
            .navigationTitle("会话")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .alert("重命名", isPresented: .constant(renaming != nil)) {
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
