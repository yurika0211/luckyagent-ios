import Foundation
import SwiftUI

@MainActor
protocol ChatSocket: AnyObject {
    var canSendChat: Bool { get }
    func disconnect()
    func sendChat(message: String, attachments: [MediaAttachment]) -> String?
    @discardableResult func cancel() -> Bool
    @discardableResult func sendApproval(requestId: String, provider: String, decision: String, input: String) -> Bool
}

extension SocketClient: ChatSocket {}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var destination: AppDestination = .chat
    @Published var socketState: SocketState = .idle
    @Published var statusNote: String = ""
    @Published var banner: String?

    @Published var personaName: String = ""
    @Published var sessions: [RuntimeSession] = []
    @Published var sessionQuery: String = ""
    @Published var lines: [ChatLine] = []
    @Published var draft: String = ""
    @Published var pendingAttachments: [MediaAttachment] = []
    @Published var approvals: [PendingApproval] = []
    @Published var models: [ModelRef] = []

    @Published var tasks: [TaskRecord] = []
    @Published var tasksNote: String = ""
    @Published var selectedTask: TaskRecord?
    @Published var taskEvents: [TaskEvent] = []
    @Published var taskResult: String = ""

    @Published var dashboard: AutonomyDashboardResponse?
    @Published var backgroundNote: String = ""
    @Published var cron: CronListResponse?
    @Published var cronNote: String = ""
    @Published var traceText: String = ""
    @Published var traceNote: String = ""
    @Published var gateways: [GatewayStatus] = []
    @Published var gatewaysNote: String = ""
    @Published var skills: [SkillInfo] = []
    @Published var commands: [RuntimeCommand] = []
    @Published var skillsNote: String = ""
    @Published var memories: [MemoryEntry] = []
    @Published var memoryQuery: String = ""
    @Published var memoryStatsText: String = ""
    @Published var graphSummary: String = ""
    @Published var memoryNote: String = ""

    @Published var healthText: String = "还没探测"
    @Published var busy = false
    @Published var outbound: OutboundQueue = OutboundQueue()
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasOlderHistory = false
    @Published private(set) var isUploading = false
    @Published private(set) var isStopping = false
    @Published private(set) var resolvingApprovalId: String?

    private let store: SettingsStore
    private var api: APIClient
    var socket: (any ChatSocket)?
    private var assistantLineId: String?
    private var reasoningLineId: String?
    private var historyOffset = 0
    private var historyTotal = 0
    private var historyRequest = UUID()
    private var connectionID = UUID()
    private var serverID = UUID()
    private var taskDetailRequest = UUID()
    private var probeRequest = UUID()
    private var bootstrapped = false
    private var settingsTask: Task<Void, Never>?
    private var sessionSockets: [String: SocketClient] = [:]
    private var chatSnapshots: [String: ChatSnapshot] = [:]

    private struct ChatSnapshot {
        var lines: [ChatLine]
        var approvals: [PendingApproval]
        var draft: String
        var attachments: [MediaAttachment]
        var assistantId: String?
        var reasoningId: String?
        var offset: Int
        var total: Int
        var hasOlder: Bool
    }

    init(store: SettingsStore = .shared, api: APIClient? = nil) {
        self.store = store
        self.settings = store.settings
        self.api = api ?? APIClient(settings: store.settings)
    }

    var activeSessionId: String { settings.sessionId }

    @discardableResult
    func applySettings(_ next: AppSettings) -> Bool {
        let previousSessionId = settings.sessionId
        let changedServer = next.apiBase != settings.apiBase || next.apiKey != settings.apiKey || next.useBearer != settings.useBearer
        let changedSession = next.sessionId != settings.sessionId
        guard store.update({ $0 = next }) else { banner = store.lastError; return false }
        settings = next
        api.settings = next
        if changedServer || changedSession {
            socket?.disconnect()
            socket = nil
            connectionID = UUID()
            resetChat()
            if changedServer {
                serverID = UUID()
                sessionSockets.values.forEach { $0.disconnect() }
                sessionSockets.removeAll()
                chatSnapshots.removeAll()
                taskDetailRequest = UUID()
                probeRequest = UUID()
                busy = false
                outbound = OutboundQueue()
                sessions = []
                models = []
                personaName = ""
                tasks = []; selectedTask = nil; taskEvents = []; taskResult = ""
                dashboard = nil; cron = nil; traceText = ""; gateways = []; skills = []; commands = []; memories = []
                memoryStatsText = ""; graphSummary = ""; healthText = "还没探测"
                tasksNote = ""; backgroundNote = ""; cronNote = ""; traceNote = ""
                gatewaysNote = ""; skillsNote = ""; memoryNote = ""
            } else if changedSession {
                for id in [previousSessionId, next.sessionId] {
                    sessionSockets.removeValue(forKey: id)?.disconnect()
                    chatSnapshots.removeValue(forKey: id)
                }
            }
            settingsTask?.cancel()
            settingsTask = Task { [weak self] in await self?.bootstrapConnection() }
        }
        return true
    }

    @discardableResult
    func applyPairing(_ payload: PairingPayload) -> Bool {
        var next = settings
        next.apiBase = payload.apiBase
        next.apiKey = payload.apiKey
        next.useBearer = false
        guard applySettings(next) else { return false }
        banner = "已写入配对：\(payload.name)"
        return true
    }

    // MARK: chat

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await bootstrapConnection()
    }

    private func bootstrapConnection() async {
        let current = connectionID
        await refreshSessions()
        guard !Task.isCancelled, current == connectionID else { return }
        if settings.sessionId.isEmpty, let first = sessions.first {
            settings.sessionId = first.id
            store.update { $0.sessionId = first.id }
        }
        if settings.sessionId.isEmpty {
            await newSession()
        } else {
            await loadHistory()
            guard !Task.isCancelled, current == connectionID else { return }
            reconnect()
        }
        if !Task.isCancelled { await loadSoul() }
    }

    private func resetChat() {
        historyRequest = UUID()
        isLoadingHistory = false
        hasOlderHistory = false
        historyOffset = 0
        historyTotal = 0
        lines = []
        approvals = []
        resolvingApprovalId = nil
        pendingAttachments = []
        draft = ""
        assistantLineId = nil
        reasoningLineId = nil
        isStopping = false
        statusNote = ""
        socketState = .idle
    }

    func reconnect() {
        if let client = sessionSockets[activeSessionId] {
            socket = client
            client.connect(sessionId: settings.sessionId)
            Task { await loadApprovals() }
            return
        }
        socket?.disconnect()
        guard !settings.sessionId.isEmpty else { socketState = .idle; return }
        connectionID = UUID()
        let boundSession = activeSessionId
        let server = serverID
        let client = SocketClient(api: api, onEvent: { [weak self] env in
            guard let self, server == self.serverID, boundSession == self.activeSessionId else { return }
            self.handle(env)
        }, onState: { [weak self] state, note in
            guard let self, server == self.serverID, boundSession == self.activeSessionId else { return }
            let inFlight = self.outbound.visible(sessionId: self.activeSessionId).contains { $0.status == .sending }
            self.socketState = state == .connected && inFlight ? .running : state
            self.statusNote = note ?? ""
            if state == .connected { self.dispatchOutbound() }
        }, onSendFailure: { [weak self] requestId, reason in
            guard let self, server == self.serverID, boundSession == self.activeSessionId else { return }
            if let item = self.outbound.items.first(where: { $0.requestId == requestId }) {
                self.outbound.markFailed(id: item.id, error: reason)
            }
            self.banner = reason
            if self.resolvingApprovalId == requestId { self.resolvingApprovalId = nil }
        })
        socket = client
        sessionSockets[boundSession] = client
        client.connect(sessionId: settings.sessionId)
        Task { await loadApprovals() }
    }

    func resumeConnection() {
        guard bootstrapped, socketState == .closed || socketState == .error || socketState == .reconnecting else { return }
        if activeSessionId.isEmpty {
            settingsTask?.cancel()
            settingsTask = Task { [weak self] in await self?.bootstrapConnection() }
        } else { reconnect() }
    }

    func suspendConnection() {
        settingsTask?.cancel()
        sessionSockets.values.forEach { $0.disconnect() }
        socket?.disconnect()
        socketState = .closed
    }

    func refreshSessions() async {
        let server = serverID
        let query = sessionQuery
        do {
            let fetched = try await api.listSessions(query: query)
            guard server == serverID, query == sessionQuery else { return }
            // The server sorts pinned first, then by the actual timestamp. Keep
            // that order; lexical RFC3339 comparisons break across time zones.
            sessions = fetched
        }
        catch { if server == serverID, query == sessionQuery { banner = error.localizedDescription } }
    }

    func selectSession(_ session: RuntimeSession) async {
        guard session.id != settings.sessionId else { return }
        if !activeSessionId.isEmpty {
            chatSnapshots[activeSessionId] = ChatSnapshot(lines: lines, approvals: approvals, draft: draft,
                attachments: pendingAttachments, assistantId: assistantLineId, reasoningId: reasoningLineId,
                offset: historyOffset, total: historyTotal, hasOlder: hasOlderHistory)
        }
        socket?.disconnect()
        socket = nil
        connectionID = UUID()
        settings.sessionId = session.id
        store.update { $0.sessionId = session.id }
        resetChat()
        if let snapshot = chatSnapshots[session.id] {
            lines = snapshot.lines; approvals = snapshot.approvals; draft = snapshot.draft
            pendingAttachments = snapshot.attachments; assistantLineId = snapshot.assistantId; reasoningLineId = snapshot.reasoningId
            historyOffset = snapshot.offset; historyTotal = snapshot.total; hasOlderHistory = snapshot.hasOlder
            reconnect()
            return
        }
        let current = connectionID
        await loadHistory()
        guard current == connectionID else { return }
        reconnect()
    }

    func newSession() async {
        let server = serverID
        do {
            let created = try await api.createSession(title: "iOS session")
            guard server == serverID else { return }
            sessions.insert(created, at: 0)
            await selectSession(created)
        } catch { if server == serverID { banner = error.localizedDescription } }
    }

    func renameSession(_ session: RuntimeSession, title: String) async {
        let server = serverID
        do {
            _ = try await api.patchSession(id: session.id, patch: SessionPatchRequest(title: title))
            guard server == serverID else { return }
            await refreshSessions()
        } catch { if server == serverID { banner = error.localizedDescription } }
    }

    func togglePin(_ session: RuntimeSession) async {
        let server = serverID
        do {
            _ = try await api.patchSession(id: session.id, patch: SessionPatchRequest(pinned: !session.pinned))
            guard server == serverID else { return }
            await refreshSessions()
        } catch { if server == serverID { banner = error.localizedDescription } }
    }

    func deleteSession(_ session: RuntimeSession) async {
        let server = serverID
        do {
            try await api.deleteSession(id: session.id)
            guard server == serverID else { return }
            sessionSockets.removeValue(forKey: session.id)?.disconnect()
            chatSnapshots.removeValue(forKey: session.id)
            if settings.sessionId == session.id {
                socket?.disconnect()
                socket = nil
                connectionID = UUID()
                settings.sessionId = ""
                store.update { $0.sessionId = "" }
                resetChat()
            }
            outbound.removeSession(session.id)
            await refreshSessions()
            guard server == serverID else { return }
            if settings.sessionId.isEmpty, let next = sessions.first { await selectSession(next) }
        } catch { if server == serverID { banner = error.localizedDescription } }
    }

    func loadHistory() async {
        guard !settings.sessionId.isEmpty else { return }
        let sessionId = settings.sessionId
        let request = UUID()
        historyRequest = request
        isLoadingHistory = true
        defer { if historyRequest == request { isLoadingHistory = false } }
        do {
            let history = try await api.history(sessionId: sessionId, limit: 80, full: true)
            guard historyRequest == request, sessionId == activeSessionId else { return }
            lines = history.messages.flatMap(linesFrom)
            historyOffset = history.returned ?? history.messages.count
            historyTotal = history.messageCount ?? historyOffset
            hasOlderHistory = history.hasMore ?? (historyOffset < historyTotal)
            assistantLineId = nil
            reasoningLineId = nil
        } catch { if historyRequest == request, sessionId == activeSessionId { banner = error.localizedDescription } }
    }

    func loadOlder() async {
        guard !settings.sessionId.isEmpty, hasOlderHistory, !isLoadingHistory, socketState != .running else { return }
        let sessionId = settings.sessionId
        let request = UUID()
        historyRequest = request
        isLoadingHistory = true
        defer { if historyRequest == request { isLoadingHistory = false } }
        do {
            // The API counts provider messages, while one message may render as
            // several rows (reasoning and tool calls). New turns also shift offsets.
            let latest = try await api.history(sessionId: sessionId, limit: 1)
            guard historyRequest == request, sessionId == activeSessionId else { return }
            let offset = historyOffset + max(0, (latest.messageCount ?? historyTotal) - historyTotal)
            let history = try await api.history(sessionId: sessionId, limit: 80, offset: offset, full: true)
            guard historyRequest == request, sessionId == activeSessionId else { return }
            let older = history.messages.flatMap(linesFrom)
            lines = older + lines
            historyOffset = offset + (history.returned ?? history.messages.count)
            historyTotal = history.messageCount ?? historyTotal
            hasOlderHistory = history.hasMore ?? (historyOffset < historyTotal)
        } catch { if historyRequest == request, sessionId == activeSessionId { banner = error.localizedDescription } }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isUploading, !isLoadingHistory, !isStopping else { return }
        guard !activeSessionId.isEmpty else { banner = "请先新建或选择会话"; return }
        guard socketState == .connected || socketState == .running else {
            banner = "还没连上。先去 Settings 填地址。"
            return
        }
        let sessionId = settings.sessionId
        let attachments = pendingAttachments
        let preview = String((text.isEmpty ? "（附件）" : text).prefix(120))
        lines.append(ChatLine(kind: .user, text: text, attachments: attachments))
        outbound.enqueue(OutboundItem(
            id: "outbound-\(UUID().uuidString)",
            sessionId: sessionId,
            preview: preview,
            message: text,
            attachments: attachments,
            requestId: nil,
            status: .queued,
            error: nil
        ))
        draft = ""
        pendingAttachments = []
        dispatchOutbound()
    }

    func retryOutbound(_ id: String) {
        outbound.retry(id: id)
        dispatchOutbound()
    }

    func dropOutbound(_ id: String) {
        outbound.remove(id: id)
    }

    /// The runtime takes one turn per session. Send the next queued message only
    /// when nothing for this session is already in flight.
    private func dispatchOutbound() {
        guard socketState == .connected, socket?.canSendChat == true, !isStopping else { return }
        let sessionId = settings.sessionId
        guard let item = outbound.nextSendable(sessionId: sessionId) else { return }
        outbound.markSending(id: item.id)
        assistantLineId = nil
        reasoningLineId = nil
        guard let requestId = socket?.sendChat(message: item.message, attachments: item.attachments) else {
            outbound.markFailed(id: item.id, error: "发送失败，连接不在。")
            banner = "发送失败，连接不在。"
            return
        }
        outbound.markSent(id: item.id, requestId: requestId)
    }

    func stop() {
        guard socket?.cancel() == true else { banner = "停止失败，连接不在。"; return }
        isStopping = true
        outbound.dropActive(sessionId: settings.sessionId)
    }

    func resolve(approval: PendingApproval, decision: String, input: String) {
        guard resolvingApprovalId == nil else { return }
        guard socket?.sendApproval(
            requestId: approval.stableId,
            provider: approval.provider ?? "runtime",
            decision: decision,
            input: input
        ) == true else { banner = "提交失败，连接不在。"; return }
        resolvingApprovalId = approval.stableId
        // Keep the card until the runtime acknowledges the decision.
    }

    func upload(data: Data, name: String, mime: String) async {
        guard !isUploading else { banner = "请等待当前附件上传完成"; return }
        isUploading = true
        let current = connectionID
        defer { isUploading = false }
        do {
            let attachment = try await api.upload(data: data, fileName: name, mime: mime)
            guard current == connectionID else { return }
            pendingAttachments.append(attachment)
        } catch { if current == connectionID { banner = error.localizedDescription } }
    }

    func previewAttachment(_ attachment: MediaAttachment) async -> URL? {
        let current = connectionID
        do { return try await api.downloadAttachment(attachment) }
        catch { if current == connectionID { banner = error.localizedDescription }; return nil }
    }

    func loadModels() async {
        let server = serverID
        do {
            let fetched = try await api.listModels().models
            guard server == serverID else { return }
            models = fetched
        }
        catch { if server == serverID { banner = error.localizedDescription } }
    }

    func switchModel(_ model: ModelRef) async {
        let server = serverID
        do {
            try await api.switchModel(kind: model.kind, model: model.id, provider: model.provider)
            guard server == serverID else { return }
            banner = "已切换 \(model.kind)：\(model.label)"
            await loadModels()
        } catch { if server == serverID { banner = error.localizedDescription } }
    }

    func compactSession() async {
        guard !settings.sessionId.isEmpty else { return }
        let server = serverID
        let sessionId = activeSessionId
        do {
            let result = try await api.compact(sessionId: sessionId)
            guard server == serverID, sessionId == activeSessionId else { return }
            banner = result.display?.message ?? result.summary ?? "已压缩"
            await loadHistory()
        } catch { if server == serverID, sessionId == activeSessionId { banner = error.localizedDescription } }
    }

    // MARK: other pages

    func loadTasks() async {
        let server = serverID
        do {
            let fetched = try await api.listTasks()
            guard server == serverID else { return }
            tasks = fetched; tasksNote = ""
            if let id = selectedTask?.id, let updated = tasks.first(where: { $0.id == id }) { selectedTask = updated }
        }
        catch { if server == serverID { tasksNote = error.localizedDescription } }
    }

    func openTask(_ task: TaskRecord) async {
        let server = serverID
        let request = UUID()
        taskDetailRequest = request
        selectedTask = task
        taskEvents = []
        taskResult = task.result ?? ""
        tasksNote = ""
        do {
            let detail = try await api.getTask(id: task.id)
            guard server == serverID, taskDetailRequest == request, selectedTask?.id == task.id else { return }
            selectedTask = detail
            taskResult = detail.result ?? ""
            let events = try await api.taskEvents(id: task.id)
            guard server == serverID, taskDetailRequest == request, selectedTask?.id == task.id else { return }
            taskEvents = events
            do {
                let result = try await api.taskResult(id: task.id)
                if server == serverID, taskDetailRequest == request, selectedTask?.id == task.id { taskResult = result }
            } catch APIError.http(404, _) {
                // Running tasks and older runtimes may not have a stored result.
            }
        } catch { if server == serverID, taskDetailRequest == request, selectedTask?.id == task.id { tasksNote = error.localizedDescription } }
    }

    func cancelTask(_ task: TaskRecord) async {
        let server = serverID
        do {
            try await api.cancelTask(id: task.id)
            guard server == serverID else { return }
            await loadTasks()
            guard server == serverID else { return }
            if let selectedTask, selectedTask.id == task.id { await openTask(selectedTask) }
        }
        catch { if server == serverID { tasksNote = error.localizedDescription } }
    }

    func loadBackground() async {
        let server = serverID
        do {
            let fetched = try await api.autonomyDashboard()
            guard server == serverID else { return }
            dashboard = fetched; backgroundNote = ""
        }
        catch { if server == serverID { backgroundNote = error.localizedDescription } }
    }

    func loadCron() async {
        let server = serverID
        do {
            let fetched = try await api.listCron()
            guard server == serverID else { return }
            cron = fetched; cronNote = ""
        }
        catch { if server == serverID { cronNote = error.localizedDescription } }
    }

    func loadTrace() async {
        let server = serverID
        let sessionId = activeSessionId
        traceText = ""
        guard !sessionId.isEmpty else { traceNote = "先选一个会话"; return }
        do {
            let trace = try await api.toolTrace(sessionId: sessionId)
            guard server == serverID, sessionId == activeSessionId else { return }
            traceText = trace; traceNote = ""
        }
        catch { if server == serverID, sessionId == activeSessionId, !Task.isCancelled { traceNote = error.localizedDescription } }
    }

    func loadGateways() async {
        let server = serverID
        do {
            let fetched = try await api.listGateways()
            guard server == serverID else { return }
            gateways = fetched; gatewaysNote = ""
        }
        catch { if server == serverID { gatewaysNote = error.localizedDescription } }
    }

    func loadSkills() async {
        let server = serverID
        do {
            let fetchedSkills = try await api.listSkills().skills
            guard server == serverID else { return }
            skills = fetchedSkills
            let fetchedCommands = try await api.listCommands()
            guard server == serverID else { return }
            commands = fetchedCommands
            skillsNote = ""
        } catch { if server == serverID { skillsNote = error.localizedDescription } }
    }

    func loadMemory() async {
        let server = serverID
        let query = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { memories = [] }
        do {
            let stats = try await api.memoryStats()
            guard server == serverID, query == memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            memoryStatsText = stats.tiers?.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · ") ?? "count \(stats.count ?? 0)"
            if !query.isEmpty {
                let result = try await api.recall(query: query)
                guard server == serverID, query == memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                memories = result
            }
            let graph = try await api.memoryGraph()
            guard server == serverID, query == memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            graphSummary = "\(graph.nodes.count) 个节点 · \(graph.edges.count) 条边"
            memoryNote = ""
        } catch { if server == serverID, query == memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines) { memoryNote = error.localizedDescription } }
    }

    func runCommand(command: String, args: String) async -> String {
        let server = serverID
        let sessionId = activeSessionId
        do {
            let result = try await api.runCommand(command: command, args: args, sessionId: sessionId)
            guard server == serverID, sessionId == activeSessionId else { return "连接或会话已更改，请重新运行命令。" }
            if let error = result.error, !error.isEmpty { return error }
            return result.output ?? result.result ?? "执行完成"
        } catch {
            guard server == serverID, sessionId == activeSessionId else { return "连接或会话已更改，请重新运行命令。" }
            return error.localizedDescription
        }
    }

    private func loadApprovals() async {
        let current = connectionID
        do {
            let pending = try await api.listApprovals()
            guard current == connectionID else { return }
            for approval in pending where approval.sessionId == activeSessionId {
                if !approvals.contains(where: { $0.stableId == approval.stableId }) { approvals.append(approval) }
            }
        } catch { /* Streaming approvals remain available when older servers lack this endpoint. */ }
    }

    func probe() async {
        let server = serverID
        let request = UUID()
        probeRequest = request
        busy = true
        defer { if server == serverID, probeRequest == request { busy = false } }
        do {
            let health = try await api.health()
            guard server == serverID, probeRequest == request else { return }
            healthText = health
            await loadSoul()
        } catch { if server == serverID, probeRequest == request { healthText = error.localizedDescription } }
    }

    // MARK: events

    func handle(_ env: WsEnvelope) {
        guard env.sessionId?.isEmpty != false || env.sessionId == activeSessionId else { return }
        switch env.type {
        case "stream_chunk", "assistant_delta", "delta", "chunk":
            let piece = env.data?.field("delta")?.string
                ?? env.data?.field("content")?.string
                ?? env.data?.field("text")?.string
                ?? env.data?.string
                ?? ""
            guard !piece.isEmpty else { return }
            appendStream(kind: .assistant, id: &assistantLineId, piece: piece)
        case "reasoning":
            let piece = env.data?.field("delta")?.string ?? env.data?.field("content")?.string ?? env.data?.field("summary")?.string ?? env.data?.string ?? ""
            guard !piece.isEmpty else { return }
            appendStream(kind: .reasoning, id: &reasoningLineId, piece: piece)
        case "tool_call", "tool", "running":
            if env.data?.field("visibility")?.string == "hidden" { return }
            let name = env.data?.field("name")?.string ?? env.data?.field("tool")?.string ?? "tool"
            let args = env.data?.field("display")?.string ?? env.data?.field("args")?.string ?? env.data?.field("params")?.pretty ?? env.data?.field("arguments")?.pretty ?? env.data?.field("input")?.pretty ?? ""
            let stepId = env.data?.field("step_id")?.string
            if let stepId, let index = lines.lastIndex(where: { $0.toolCallId == stepId && $0.kind == .tool }) {
                lines[index].text = args
            } else {
                lines.append(ChatLine(kind: .tool, text: args, toolName: name, toolState: "running", toolCallId: stepId))
            }
        case "tool_result":
            if env.data?.field("visibility")?.string == "hidden" { return }
            let name = env.data?.field("name")?.string ?? "tool"
            let output = env.data?.field("output")?.pretty ?? env.data?.field("result")?.pretty ?? env.data?.pretty ?? ""
            let stepId = env.data?.field("step_id")?.string
            let toolState = env.data?.field("success") == .bool(false) ? "failed" : "done"
            let attachments: [MediaAttachment] = decodeAttachments(env.data?.field("attachments"))
            if let index = lines.lastIndex(where: { $0.kind == .tool && (stepId != nil ? $0.toolCallId == stepId : ($0.toolName == name && $0.toolState == "running")) }) {
                lines[index].text = output
                lines[index].toolState = toolState
                lines[index].attachments = attachments
            } else {
                lines.append(ChatLine(kind: .tool, text: output, toolName: name, toolState: toolState, toolCallId: stepId, attachments: attachments))
            }
        case "status":
            let state = env.data?.field("state")?.string
            let text = env.data?.field("message")?.string ?? env.data?.string ?? ""
            if state == "connected", socket?.canSendChat == true {
                // After replay, a server with no active run cannot confirm a
                // send whose acknowledgement was lost. Never resend it silently.
                if let sending = outbound.visible(sessionId: activeSessionId).first(where: { $0.status == .sending }) {
                    let note = "上一条消息的送达状态无法确认，请刷新历史后决定是否重试。"
                    outbound.markFailed(id: sending.id, error: note)
                    banner = note
                    finishStreams()
                }
                isStopping = false
                socketState = .connected
                dispatchOutbound()
            }
            if state == "approval_resolved", let id = resolvingApprovalId {
                approvals.removeAll { $0.stableId == id }
                resolvingApprovalId = nil
            }
            if state == "idle", matchesCurrentTurn(env) {
                finishStreams()
                socketState = .connected
                if isStopping || text == "cancelled" {
                    isStopping = false
                    outbound.dropActive(sessionId: activeSessionId)
                    lines.append(ChatLine(kind: .system, text: "已停止"))
                } else {
                    finishOutboundTurn(env)
                }
            }
            if !text.isEmpty, state != "connected", state != "idle" { statusNote = text }
        case "compact":
            statusNote = env.data?.field("message")?.string ?? "正在压缩上下文"
        case "task_event":
            if let message = env.data?.field("message")?.string, !message.isEmpty { statusNote = message }
        case "approval":
            if let data = env.data, let encoded = try? JSONEncoder().encode(data),
               var approval = try? JSONDecoder().decode(PendingApproval.self, from: encoded) {
                approval.sessionId = env.sessionId
                if !approvals.contains(where: { $0.stableId == approval.stableId }) { approvals.append(approval) }
            }
        case "stream_end", "final", "done", "chat_done", "assistant_message":
            guard matchesCurrentTurn(env) else { return }
            let final = env.data?.field("full_response")?.string ?? env.data?.field("content")?.string ?? env.data?.field("message")?.string
            let attachments = decodeAttachments(env.data?.field("attachments"))
            if let id = assistantLineId, let index = lines.firstIndex(where: { $0.id == id }) {
                if let final, !final.isEmpty { lines[index].text = final }
                lines[index].attachments = attachments
            } else if (final?.isEmpty == false) || !attachments.isEmpty {
                lines.append(ChatLine(kind: .assistant, text: final ?? "", attachments: attachments))
            }
            finishStreams()
            socketState = .connected
            finishOutboundTurn(env)
        case "error":
            let error = env.error ?? env.data?.field("message")?.string ?? "出错了"
            lines.append(ChatLine(kind: .error, text: error))
            if env.data?.field("code")?.string == "APPROVAL_FAILED" {
                resolvingApprovalId = nil
                socketState = .running
                return
            }
            guard matchesCurrentTurn(env) else { return }
            finishStreams()
            isStopping = false
            socketState = .connected
            failOutboundTurn(env, error: error)
        case "cancel", "cancelled":
            guard matchesCurrentTurn(env) else { return }
            lines.append(ChatLine(kind: .system, text: "已停止"))
            finishStreams()
            isStopping = false
            outbound.dropActive(sessionId: env.sessionId ?? settings.sessionId)
        default:
            break
        }
    }

    /// A turn ended cleanly. Drop the in-flight item, then send the next queued one.
    private func finishOutboundTurn(_ env: WsEnvelope) {
        let session = env.sessionId ?? settings.sessionId
        if let sending = outbound.visible(sessionId: session).first(where: { $0.status == .sending }) {
            outbound.remove(id: sending.id)
        }
        if session == settings.sessionId { dispatchOutbound() }
    }

    /// The in-flight item failed. Keep it for retry, and let a later queued message go out.
    private func failOutboundTurn(_ env: WsEnvelope, error: String) {
        let session = env.sessionId ?? settings.sessionId
        if let sending = outbound.visible(sessionId: session).first(where: { $0.status == .sending }) {
            outbound.markFailed(id: sending.id, error: error)
        }
        if session == settings.sessionId { dispatchOutbound() }
    }

    private func matchesCurrentTurn(_ env: WsEnvelope) -> Bool {
        guard let requestId = env.parentId ?? env.runId,
              let sending = outbound.visible(sessionId: activeSessionId).first(where: { $0.status == .sending }) else { return true }
        return sending.requestId == requestId
    }

    private func finishStreams() {
        for index in lines.indices { lines[index].streaming = false }
        assistantLineId = nil
        reasoningLineId = nil
    }

    private func decodeAttachments(_ value: JSONValue?) -> [MediaAttachment] {
        guard let value, let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([MediaAttachment].self, from: data)) ?? []
    }

    private func appendStream(kind: ChatLine.Kind, id: inout String?, piece: String) {
        if let id, let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].text += piece
            return
        }
        let line = ChatLine(kind: kind, text: piece, streaming: true)
        id = line.id
        lines.append(line)
    }

    private func linesFrom(_ message: ProviderMessage) -> [ChatLine] {
        let role = (message.role ?? "").lowercased()
        var out: [ChatLine] = []
        if !message.toolCalls.isEmpty {
            for call in message.toolCalls {
                out.append(ChatLine(kind: .tool, text: call.arguments ?? "", toolName: call.name ?? "tool", toolState: "done"))
            }
        }
        let text = message.displayText
        if !text.isEmpty || !message.attachments.isEmpty {
            let kind: ChatLine.Kind = role == "user" ? .user : (role == "system" ? .system : (role == "tool" ? .tool : .assistant))
            out.append(ChatLine(kind: kind, text: text, toolName: message.name, toolState: role == "tool" ? "done" : nil, toolCallId: message.toolCallId, attachments: message.attachments))
        }
        if let reasoning = message.reasoningContent, !reasoning.isEmpty {
            out.append(ChatLine(kind: .reasoning, text: reasoning))
        }
        return out
    }

    private func loadSoul() async {
        let server = serverID
        if let soul = try? await api.soul(), server == serverID { personaName = soul.name }
    }
}
