import SwiftUI

/// Keep loading, failure, and successful empty results distinct on every runtime page.
private struct RuntimeFeedback: View {
    var loading: Bool
    var note: String
    var empty: Bool
    var title: String
    var symbol: String
    var description: String = "下拉或点刷新重新加载。"
    var retry: () -> Void

    var body: some View {
        if loading {
            HStack { ProgressView(); Text("加载中…").foregroundStyle(.secondary) }
        } else if !note.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("加载未完成", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Clover.error)
                Text(note).font(.footnote).textSelection(.enabled)
                Button("重试", action: retry)
            }
        } else if empty {
            ContentUnavailableView(title, systemImage: symbol, description: Text(description))
        }
    }
}

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false
    @State private var loadingDetail = false
    @State private var cancelling = false
    @State private var confirmCancel = false

    var body: some View {
        List {
            if let task = model.selectedTask {
                Section("详情") {
                    HStack(alignment: .top) {
                        Text(task.headline).font(.headline)
                        Spacer()
                        Button { model.selectedTask = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("关闭任务详情")
                    }
                    LabeledContent("状态", value: task.status)
                    Text(task.id).font(.caption.monospaced()).textSelection(.enabled)
                    if let error = task.error, !error.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(Clover.error).textSelection(.enabled)
                    }
                    if loadingDetail { ProgressView("加载任务详情…") }
                    if !model.taskResult.isEmpty {
                        DisclosureGroup("任务结果") { Text(model.taskResult).font(.footnote).textSelection(.enabled) }
                    }
                    ForEach(model.taskEvents) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.type).font(.caption.weight(.semibold))
                            if let message = event.message, !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                            if let time = event.timestamp { Text(time).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    if RuntimePresentation.canCancelTask(status: task.status) {
                        Button(cancelling ? "取消中…" : "取消这个任务", role: .destructive) { confirmCancel = true }
                            .disabled(cancelling || loadingDetail)
                    }
                }
            }
            Section("任务 \(model.tasks.count)") {
                RuntimeFeedback(loading: loading, note: model.tasksNote, empty: model.tasks.isEmpty,
                                title: "没有任务", symbol: "checklist") { Task { await reload() } }
                ForEach(model.tasks) { task in
                    Button { Task { await open(task) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.headline).foregroundStyle(.primary).lineLimit(2)
                            Text([task.status, task.mode ?? task.source ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(loadingDetail || cancelling)
                }
            }
        }
        .navigationTitle("Tasks")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } }.disabled(loading || cancelling) } }
        .refreshable { await reload() }
        .task { await reload() }
        .confirmationDialog("取消这个任务？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("取消任务", role: .destructive) {
                guard let task = model.selectedTask else { return }
                Task {
                    cancelling = true
                    await model.cancelTask(task)
                    cancelling = false
                }
            }
            Button("返回", role: .cancel) { }
        }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await model.loadTasks()
    }

    private func open(_ task: TaskRecord) async {
        guard !loadingDetail else { return }
        loadingDetail = true
        defer { loadingDetail = false }
        await model.openTask(task)
    }
}

struct BackgroundView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false

    var body: some View {
        List {
            RuntimeFeedback(loading: loading, note: model.backgroundNote, empty: model.dashboard == nil,
                            title: "没有后台数据", symbol: "gearshape.2") { Task { await reload() } }
            if let dash = model.dashboard {
                Section("队列") {
                    if let q = dash.queue {
                        LabeledContent("待执行", value: "\(q.ready)")
                        LabeledContent("执行中", value: "\(q.inProgress)")
                        LabeledContent("阻塞", value: "\(q.blocked)")
                        LabeledContent("已完成", value: "\(q.done)")
                    }
                    LabeledContent("Workers", value: "\(dash.pool?.workerCount ?? dash.workers.count)")
                    if let time = dash.generatedAt { LabeledContent("更新于", value: time).font(.caption) }
                }
                Section("Workers") {
                    if dash.workers.isEmpty { Text("没有运行中的 Worker").foregroundStyle(.secondary) }
                    ForEach(dash.workers) { worker in
                        VStack(alignment: .leading, spacing: 3) {
                            LabeledContent(worker.id, value: worker.state)
                            if let task = worker.currentTaskId, !task.isEmpty {
                                Text("当前任务 \(task)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("后台任务") {
                    if dash.tasks.isEmpty { Text("没有后台任务").foregroundStyle(.secondary) }
                    ForEach(dash.tasks) { task in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title.isEmpty ? task.id : task.title)
                            Text([task.state, task.priority].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !task.description.isEmpty { Text(task.description).font(.footnote).textSelection(.enabled) }
                            if let worker = task.assignedTo, !worker.isEmpty { Text("Worker \(worker)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Background")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } }.disabled(loading) } }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await model.loadBackground()
    }
}

struct CronView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false

    var body: some View {
        List {
            RuntimeFeedback(loading: loading, note: model.cronNote, empty: model.cron == nil,
                            title: "没有定时任务数据", symbol: "clock") { Task { await reload() } }
            if let cron = model.cron {
                LabeledContent("引擎", value: cron.running ? "运行中" : "已停止")
                Section("任务 \(cron.count)") {
                    if cron.jobs.isEmpty { Text("没有定时任务").foregroundStyle(.secondary) }
                    ForEach(cron.jobs) { job in
                        DisclosureGroup {
                            if !job.description.isEmpty { Text(job.description).font(.footnote).textSelection(.enabled) }
                            if let command = job.command, !command.isEmpty { Text(command).font(.footnote.monospaced()).textSelection(.enabled) }
                            if let last = job.lastRun { LabeledContent("上次运行", value: last).font(.caption) }
                            if let next = job.nextRun { LabeledContent("下次运行", value: next).font(.caption) }
                            Text(job.id).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.name.isEmpty ? job.id : job.name)
                                Text("\(job.schedule) · \(job.status)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Cron")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } }.disabled(loading) } }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await model.loadCron()
    }
}

struct TraceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false

    var body: some View {
        List {
            if !model.activeSessionId.isEmpty {
                Section("当前会话") { Text(model.activeSessionId).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if model.activeSessionId.isEmpty {
                ContentUnavailableView("先选择会话", systemImage: "point.3.connected.trianglepath", description: Text("到 Chat 选择会话后查看工具调用轨迹。"))
            } else {
                RuntimeFeedback(loading: loading, note: model.traceNote, empty: model.traceText.isEmpty,
                                title: "还没有轨迹", symbol: "point.3.connected.trianglepath",
                                description: "会话中的工具执行结束后，可在这里查看。") { Task { await reload() } }
            }
            if !model.activeSessionId.isEmpty, let trace = RuntimeToolTrace.parse(model.traceText) {
                Section("工具调用") {
                    LabeledContent("总计", value: "\(trace.totalCalls ?? trace.tools.count)")
                    if let successes = trace.successes { LabeledContent("成功", value: "\(successes)") }
                    if let failures = trace.failures { LabeledContent("失败", value: "\(failures)") }
                    if trace.tools.isEmpty { Text("这个会话还没有工具调用").foregroundStyle(.secondary) }
                    ForEach(Array(trace.tools.enumerated()), id: \.offset) { _, tool in
                        DisclosureGroup {
                            if let annotation = tool.annotation, !annotation.isEmpty { Text(annotation).font(.footnote) }
                            if let args = tool.arguments, !args.isEmpty { Text("参数\n\(args)").font(.caption.monospaced()).textSelection(.enabled) }
                            if let result = tool.result, !result.isEmpty { Text("结果\n\(result)").font(.caption.monospaced()).textSelection(.enabled) }
                            if let error = tool.error, !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Clover.error).textSelection(.enabled) }
                            if let duration = tool.durationMS, duration > 0 { Text("\(duration) ms").font(.caption).foregroundStyle(.secondary) }
                        } label: {
                            Label(tool.name, systemImage: tool.success ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(tool.success ? Color.primary : Clover.error)
                        }
                    }
                }
                Section { DisclosureGroup("原始响应") { rawTrace } }
            } else if !model.activeSessionId.isEmpty && !model.traceText.isEmpty {
                Section("轨迹") { rawTrace }
            }
        }
        .navigationTitle("Trace")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } }.disabled(loading || model.activeSessionId.isEmpty) } }
        .refreshable { await reload() }
        .task(id: model.activeSessionId) { await reload() }
    }

    private var rawTrace: some View {
        Text(model.traceText).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
    }

    private func reload() async {
        // A new session must replace the previous session's trace, even if its request is still pending.
        loading = true
        defer { loading = false }
        await model.loadTrace()
    }
}

struct GatewaysView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false

    var body: some View {
        List {
            RuntimeFeedback(loading: loading, note: model.gatewaysNote, empty: model.gateways.isEmpty,
                            title: "没有网关", symbol: "network", description: "在电脑端配置并启动消息网关后，刷新查看状态。") {
                Task { await reload() }
            }
            ForEach(model.gateways) { gateway in
                HStack(alignment: .top) {
                    Image(systemName: gateway.running ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(gateway.running ? Clover.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(gateway.name.isEmpty ? gateway.id : gateway.name)
                        Text(gateway.platform ?? gateway.status ?? "").font(.caption).foregroundStyle(.secondary)
                        if let error = gateway.error, !error.isEmpty {
                            Text(error).font(.footnote).foregroundStyle(Clover.error).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Text(gateway.running ? "运行中" : "已停止").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Gateways")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } }.disabled(loading) } }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await model.loadGateways()
    }
}

struct SkillsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false
    @State private var selectedCommand: RuntimeCommand?

    var body: some View {
        List {
            RuntimeFeedback(loading: loading, note: model.skillsNote, empty: model.skills.isEmpty && model.commands.isEmpty,
                            title: "没有技能或命令", symbol: "sparkles") { Task { await reload() } }
            Section("Skills · \(model.skills.count)") {
                if model.skills.isEmpty && !loading && model.skillsNote.isEmpty { Text("没有已加载的技能").foregroundStyle(.secondary) }
                ForEach(model.skills) { skill in
                    DisclosureGroup {
                        if let desc = skill.description, !desc.isEmpty { Text(desc).font(.footnote).textSelection(.enabled) }
                    } label: {
                        HStack {
                            Text(skill.name)
                            Spacer()
                            if let enabled = skill.enabled {
                                Text(enabled ? "已启用" : "未启用").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Commands · \(model.commands.count)") {
                ForEach(model.commands) { command in
                    Button { selectedCommand = command } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(command.usage ?? "/\(command.name)").font(.body.monospaced()).foregroundStyle(.primary)
                            if let desc = command.description { Text(desc).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await reload() } }.disabled(loading) } }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(item: $selectedCommand) { command in
            RuntimeCommandView(command: command).environmentObject(model)
        }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await model.loadSkills()
    }
}

private struct RuntimeCommandView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let command: RuntimeCommand
    @State private var args = ""
    @State private var output = ""
    @State private var running = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(command.usage ?? "/\(command.name)").font(.body.monospaced())
                    if let description = command.description { Text(description).font(.footnote).foregroundStyle(.secondary) }
                    TextField("参数（可空）", text: $args, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(running)
                    Text(model.activeSessionId.isEmpty ? "尚未选择会话；会话命令需先在 Chat 选择会话。" : "当前会话：\(model.activeSessionId)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(running ? "运行中…" : "运行命令") {
                        Task {
                            running = true
                            output = await model.runCommand(command: command.name, args: args)
                            running = false
                        }
                    }
                    .disabled(running)
                }
                if running { ProgressView("执行中…") }
                if !output.isEmpty { Section("结果") { Text(output).font(.footnote.monospaced()).textSelection(.enabled) } }
            }
            .navigationTitle("/\(command.name)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(running) } }
            .interactiveDismissDisabled(running)
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var loading = false
    @State private var lastQuery = ""

    var body: some View {
        List {
            Section("检索记忆") {
                TextField("输入关键词", text: $model.memoryQuery)
                    .submitLabel(.search)
                    .disabled(loading)
                    .onSubmit { Task { await reload() } }
                if !model.memoryStatsText.isEmpty { LabeledContent("记忆统计", value: model.memoryStatsText).font(.footnote) }
                if !model.graphSummary.isEmpty { LabeledContent("关系图", value: model.graphSummary).font(.footnote) }
            }
            RuntimeFeedback(loading: loading, note: model.memoryNote, empty: model.memories.isEmpty,
                            title: lastQuery.isEmpty ? "搜索记忆" : "没有匹配的记忆", symbol: "brain",
                            description: lastQuery.isEmpty ? "输入关键词后点查询。" : "试试其他关键词。") { Task { await reload() } }
            if !model.memories.isEmpty {
                Section("结果 · \(lastQuery)") {
                    ForEach(model.memories) { entry in
                        DisclosureGroup {
                            Text(entry.content).font(.footnote).textSelection(.enabled)
                            Text(entry.id).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title ?? entry.category ?? entry.tier ?? "memory").font(.caption).foregroundStyle(.secondary)
                                Text(entry.content).font(.footnote).lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Memory")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("查询") { Task { await reload() } }.disabled(loading) } }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await model.loadMemory()
        if model.memoryNote.isEmpty { lastQuery = model.memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = AppSettings()
    @State private var revealKey = false
    @State private var pairingText = ""
    @State private var settingsNote = ""
    @State private var invalidSettings = false

    var body: some View {
        Form {
            Section("连接") {
                TextField("API Base", text: $draft.apiBase)
                    .keyboardType(.URL).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Group {
                        if revealKey { TextField("API Key", text: $draft.apiKey) }
                        else { SecureField("API Key", text: $draft.apiKey) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { revealKey.toggle() } label: { Image(systemName: revealKey ? "eye.slash" : "eye") }
                        .accessibilityLabel(revealKey ? "隐藏 API Key" : "显示 API Key")
                }
                Toggle("使用 Bearer（关闭时使用 X-API-Key）", isOn: $draft.useBearer)
                TextField("Session ID，可空", text: $draft.sessionId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
                Text("填写电脑端 lh serve 的 HTTP 或 HTTPS 地址；真机应使用电脑的局域网地址。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存连接设置") { _ = save() }.disabled(model.busy)
                if !settingsNote.isEmpty {
                    Text(settingsNote).font(.footnote).foregroundStyle(invalidSettings ? Clover.error : Color.secondary)
                }
            }
            Section("外观") {
                Picker("主题", selection: $draft.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .onChange(of: draft.appearance) { _, appearance in
                    var next = model.settings
                    next.appearance = appearance
                    model.applySettings(next)
                }
            }
            Section("配对二维码内容") {
                TextField("粘贴 lh qr 的 JSON", text: $pairingText, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...4)
                Button("应用配对文本") { applyPairing() }
                    .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                Text("在电脑执行 lh qr，粘贴包含地址和临时 token 的 JSON。配对密钥使用 X-API-Key。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("探测") {
                LabeledContent("Health", value: model.healthText)
                Button(model.busy ? "探测中…" : "保存并探测") {
                    guard save() else { return }
                    Task { await model.probe() }
                }
                .disabled(model.busy)
                Button("重连 WebSocket") { model.reconnect() }.disabled(model.busy)
            }
            Section("关于") {
                LabeledContent("客户端", value: "luckyagent-ios 0.1.0")
                Text("手机是客户端，Agent、模型、记忆和工具运行在电脑的 lh serve 上。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear { draft = model.settings }
    }

    @discardableResult private func save() -> Bool {
        guard let base = RuntimePresentation.normalizedAPIBase(draft.apiBase) else {
            invalidSettings = true
            settingsNote = "地址无效：请填写完整的 http:// 或 https:// 地址，不要包含账号、查询参数或 #。"
            return false
        }
        draft.apiBase = base
        draft.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sessionId = draft.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.applySettings(draft) else {
            invalidSettings = true
            settingsNote = model.banner ?? "连接设置未能保存，请重试。"
            return false
        }
        invalidSettings = false
        settingsNote = "连接设置已保存。"
        return true
    }

    private func applyPairing() {
        guard let payload = PairingQR.parse(pairingText) else {
            invalidSettings = true
            settingsNote = "配对文本无法解析，请粘贴 lh qr 输出的完整 JSON。"
            return
        }
        draft.apiBase = payload.apiBase
        draft.apiKey = payload.apiKey
        draft.useBearer = false
        if save() {
            pairingText = ""
            settingsNote = "已保存配对：\(payload.name)"
        }
    }
}
