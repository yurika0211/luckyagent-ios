import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            if let task = model.selectedTask {
                Section("详情") {
                    Text(task.headline).font(.headline)
                    Text(task.status).font(.caption).foregroundStyle(.secondary)
                    if !model.taskResult.isEmpty { Text(model.taskResult).font(.footnote).textSelection(.enabled) }
                    ForEach(model.taskEvents) { event in
                        VStack(alignment: .leading) {
                            Text(event.type).font(.caption.weight(.semibold))
                            Text(event.message ?? "").font(.caption)
                        }
                    }
                    Button("取消这个任务", role: .destructive) { Task { await model.cancelTask(task) } }
                }
            }
            Section {
                NoteText(text: model.tasksNote)
                ForEach(model.tasks) { task in
                    Button { Task { await model.openTask(task) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.headline).foregroundStyle(.primary).lineLimit(2)
                            Text("\(task.status) · \(task.mode ?? task.source ?? "")").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await model.loadTasks() } } } }
        .overlay { if model.tasks.isEmpty { ContentUnavailableView("没有任务", systemImage: "checklist", description: Text(model.tasksNote)) } }
        .task { await model.loadTasks() }
    }
}

struct BackgroundView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            NoteText(text: model.backgroundNote)
            if let dash = model.dashboard {
                Section("队列") {
                    if let q = dash.queue {
                        LabeledContent("ready", value: "\(q.ready)")
                        LabeledContent("in progress", value: "\(q.inProgress)")
                        LabeledContent("blocked", value: "\(q.blocked)")
                        LabeledContent("done", value: "\(q.done)")
                    }
                    LabeledContent("workers", value: "\(dash.pool?.workerCount ?? dash.workers.count)")
                }
                Section("Workers") {
                    ForEach(dash.workers) { worker in
                        LabeledContent(worker.id, value: worker.state)
                    }
                }
                Section("后台任务") {
                    ForEach(dash.tasks) { task in
                        VStack(alignment: .leading) {
                            Text(task.title.isEmpty ? task.id : task.title)
                            Text("\(task.state) · \(task.priority)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Background")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await model.loadBackground() } } } }
        .task { await model.loadBackground() }
    }
}

struct CronView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            NoteText(text: model.cronNote)
            if let cron = model.cron {
                LabeledContent("引擎", value: cron.running ? "运行中" : "停着")
                Section("任务 \(cron.count)") {
                    ForEach(cron.jobs) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.name.isEmpty ? job.id : job.name)
                            Text("\(job.schedule) · \(job.status)").font(.caption).foregroundStyle(.secondary)
                            if let last = job.lastRun { Text("上次 \(last)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Cron")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await model.loadCron() } } } }
        .task { await model.loadCron() }
    }
}

struct TraceView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PageHeader(title: "Trace", subtitle: model.activeSessionId)
                NoteText(text: model.traceNote)
                Text(model.traceText.isEmpty ? "还没有轨迹" : model.traceText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationTitle("Trace")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await model.loadTrace() } } } }
        .task { await model.loadTrace() }
    }
}

struct GatewaysView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            NoteText(text: model.gatewaysNote)
            ForEach(model.gateways) { gateway in
                HStack {
                    Circle().fill(gateway.running ? Clover.accent : Clover.error).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(gateway.name.isEmpty ? gateway.id : gateway.name)
                        Text(gateway.platform ?? gateway.status ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(gateway.running ? "on" : "off").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Gateways")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await model.loadGateways() } } } }
        .task { await model.loadGateways() }
    }
}

struct SkillsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            NoteText(text: model.skillsNote)
            Section("Skills") {
                ForEach(model.skills) { skill in
                    VStack(alignment: .leading) {
                        Text(skill.name)
                        if let desc = skill.description { Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }
            Section("Commands") {
                ForEach(model.commands) { command in
                    VStack(alignment: .leading) {
                        Text(command.name).font(.body.monospaced())
                        if let usage = command.usage { Text(usage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新") { Task { await model.loadSkills() } } } }
        .task { await model.loadSkills() }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            NoteText(text: model.memoryNote)
            Section {
                TextField("recall 查询", text: $model.memoryQuery)
                    .onSubmit { Task { await model.loadMemory() } }
                LabeledContent("tiers", value: model.memoryStatsText)
                LabeledContent("graph", value: model.graphSummary)
            }
            Section("结果") {
                ForEach(model.memories) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title ?? entry.category ?? entry.tier ?? "memory").font(.caption).foregroundStyle(.secondary)
                        Text(entry.content).font(.footnote).lineLimit(6)
                    }
                }
            }
        }
        .navigationTitle("Memory")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("查询") { Task { await model.loadMemory() } } } }
        .task { await model.loadMemory() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = AppSettings()
    @State private var revealKey = false
    @State private var pairingText = ""

    var body: some View {
        Form {
            Section("连接") {
                TextField("API Base", text: $draft.apiBase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    if revealKey {
                        TextField("API Key", text: $draft.apiKey)
                    } else {
                        SecureField("API Key", text: $draft.apiKey)
                    }
                    Button { revealKey.toggle() } label: { Image(systemName: revealKey ? "eye.slash" : "eye") }
                }
                Toggle("用 Bearer（关则用 X-API-Key）", isOn: $draft.useBearer)
                TextField("Session ID，可空", text: $draft.sessionId)
                    .font(.caption.monospaced())
            }
            Section("外观") {
                Picker("主题", selection: $draft.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            }
            Section("配对二维码内容") {
                TextField("粘贴 luckyagent:// 或 JSON", text: $pairingText, axis: .vertical)
                    .lineLimit(2...4)
                Button("应用这段配对文本") { applyPairing() }
                    .disabled(pairingText.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("相机扫码需要在装了签名的真机上。模拟器和未签名包先用粘贴。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("探测") {
                LabeledContent("health", value: model.healthText)
                Button(model.busy ? "探测中…" : "保存并探测") { saveAndProbe() }
                    .disabled(model.busy)
                Button("重连 WebSocket") { model.reconnect() }
            }
            Section("关于") {
                LabeledContent("客户端", value: "luckyagent-ios 0.1.0")
                LabeledContent("对应安卓", value: "v0.1.57 功能面")
                Text("手机只是客户端。模型、记忆、工具仍在电脑的 lh serve 上。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear { draft = model.settings }
    }

    private func saveAndProbe() {
        model.applySettings(draft)
        Task { await model.probe() }
    }

    private func applyPairing() {
        guard let payload = PairingQR.parse(pairingText) else {
            model.banner = "这段文本解析不了"
            return
        }
        draft.apiBase = payload.apiBase
        draft.apiKey = payload.apiKey
        draft.useBearer = false
        model.applyPairing(payload)
    }
}
