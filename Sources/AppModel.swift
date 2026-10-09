import Foundation
import SwiftUI

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

    private let store: SettingsStore
    private var api: APIClient
    private var socket: SocketClient?
    private var assistantLineId: String?
    private var reasoningLineId: String?

    init(store: SettingsStore = .shared) {
        self.store = store
        self.settings = store.settings
        self.api = APIClient(settings: store.settings)
    }

    var activeSessionId: String { settings.sessionId }

    func applySettings(_ next: AppSettings) {
        settings = next
        store.update { $0 = next }
        api.settings = next
        reconnect()
    }

    func applyPairing(_ payload: PairingPayload) {
        var next = settings
        next.apiBase = payload.apiBase
        next.apiKey = payload.apiKey
        next.useBearer = false
        applySettings(next)
        banner = "已写入配对：\(payload.name)"
    }

    // MARK: chat

    func bootstrap() async {
        await refreshSessions()
        if settings.sessionId.isEmpty, let first = sessions.first {
            settings.sessionId = first.id
            store.update { $0.sessionId = first.id }
        }
        reconnect()
        if !settings.sessionId.isEmpty { await loadHistory() }
        await loadSoul()
    }

    func reconnect() {
        socket?.disconnect()
        let client = SocketClient(api: api, onEvent: { [weak self] env in
            self?.handle(env)
        }, onState: { [weak self] state, note in
            self?.socketState = state
            if let note, !note.isEmpty { self?.statusNote = note }
        })
        socket = client
        client.connect(sessionId: settings.sessionId)
    }

    func refreshSessions() async {
        do { sessions = try await api.listSessions(query: sessionQuery).sorted { ($0.pinned ? 0 : 1, $0.updatedAt ?? "") < ($1.pinned ? 0 : 1, $1.updatedAt ?? "") } }
        catch { banner = error.localizedDescription }
    }

    func selectSession(_ session: RuntimeSession) async {
        settings.sessionId = session.id
        store.update { $0.sessionId = session.id }
        lines = []
        assistantLineId = nil
        reconnect()
        await loadHistory()
    }

    func newSession() async {
        do {
            let created = try await api.createSession(title: "iOS session")
            sessions.insert(created, at: 0)
            await selectSession(created)
        } catch { banner = error.localizedDescription }
    }

    func renameSession(_ session: RuntimeSession, title: String) async {
        do {
            _ = try await api.patchSession(id: session.id, patch: SessionPatchRequest(title: title))
            await refreshSessions()
        } catch { banner = error.localizedDescription }
    }

    func deleteSession(_ session: RuntimeSession) async {
        do {
            try await api.deleteSession(id: session.id)
            if settings.sessionId == session.id {
                settings.sessionId = ""
                lines = []
            }
            await refreshSessions()
        } catch { banner = error.localizedDescription }
    }

    func loadHistory() async {
        guard !settings.sessionId.isEmpty else { return }
        do {
            let history = try await api.history(sessionId: settings.sessionId, limit: 80, full: true)
            lines = history.messages.flatMap(linesFrom)
        } catch { banner = error.localizedDescription }
    }

    func loadOlder() async {
        guard !settings.sessionId.isEmpty else { return }
        do {
            let history = try await api.history(sessionId: settings.sessionId, limit: 80, offset: lines.count)
            let older = history.messages.flatMap(linesFrom)
            lines = older + lines
        } catch { banner = error.localizedDescription }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard socketState == .connected || socketState == .running else {
            banner = "还没连上。先去 Settings 填地址。"
            return
        }
        lines.append(ChatLine(kind: .user, text: text.isEmpty ? "（附件）" : text))
        draft = ""
        let attachments = pendingAttachments
        pendingAttachments = []
        assistantLineId = nil
        reasoningLineId = nil
        if socket?.sendChat(message: text, attachments: attachments) == nil {
            banner = "发送失败，连接不在。"
        }
    }

    func stop() { socket?.cancel() }

    func resolve(approval: PendingApproval, decision: String, input: String) {
        socket?.sendApproval(
            requestId: approval.stableId,
            provider: approval.provider ?? "runtime",
            decision: decision,
            input: input
        )
        approvals.removeAll { $0.stableId == approval.stableId }
    }

    func upload(data: Data, name: String, mime: String) async {
        do {
            let attachment = try await api.upload(data: data, fileName: name, mime: mime)
            pendingAttachments.append(attachment)
        } catch { banner = error.localizedDescription }
    }

    func loadModels() async {
        do { models = try await api.listModels().models }
        catch { banner = error.localizedDescription }
    }

    func switchModel(_ model: ModelRef) async {
        do {
            try await api.switchModel(kind: model.kind, model: model.id, provider: model.provider)
            banner = "已切换 \(model.kind)：\(model.label)"
            await loadModels()
        } catch { banner = error.localizedDescription }
    }

    func compactSession() async {
        guard !settings.sessionId.isEmpty else { return }
        do {
            let result = try await api.compact(sessionId: settings.sessionId)
            banner = result.display?.message ?? result.summary ?? "已压缩"
            await loadHistory()
        } catch { banner = error.localizedDescription }
    }

    // MARK: other pages

    func loadTasks() async {
        do { tasks = try await api.listTasks(); tasksNote = "" }
        catch { tasksNote = error.localizedDescription }
    }

    func openTask(_ task: TaskRecord) async {
        selectedTask = task
        taskEvents = (try? await api.taskEvents(id: task.id)) ?? []
        taskResult = (try? await api.taskResult(id: task.id)) ?? ""
    }

    func cancelTask(_ task: TaskRecord) async {
        do { try await api.cancelTask(id: task.id); await loadTasks() }
        catch { tasksNote = error.localizedDescription }
    }

    func loadBackground() async {
        do { dashboard = try await api.autonomyDashboard(); backgroundNote = "" }
        catch { backgroundNote = error.localizedDescription }
    }

    func loadCron() async {
        do { cron = try await api.listCron(); cronNote = "" }
        catch { cronNote = error.localizedDescription }
    }

    func loadTrace() async {
        guard !settings.sessionId.isEmpty else { traceNote = "先选一个会话"; return }
        do { traceText = try await api.toolTrace(sessionId: settings.sessionId); traceNote = "" }
        catch { traceNote = error.localizedDescription }
    }

    func loadGateways() async {
        do { gateways = try await api.listGateways(); gatewaysNote = "" }
        catch { gatewaysNote = error.localizedDescription }
    }

    func loadSkills() async {
        do {
            skills = try await api.listSkills().skills
            commands = try await api.listCommands()
            skillsNote = ""
        } catch { skillsNote = error.localizedDescription }
    }

    func loadMemory() async {
        do {
            let stats = try await api.memoryStats()
            memoryStatsText = stats.tiers?.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · ") ?? "count \(stats.count ?? 0)"
            if !memoryQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                memories = try await api.recall(query: memoryQuery)
            }
            let graph = try await api.memoryGraph()
            graphSummary = "\(graph.nodes.count) 个节点 · \(graph.edges.count) 条边"
            memoryNote = ""
        } catch { memoryNote = error.localizedDescription }
    }

    func probe() async {
        busy = true
        defer { busy = false }
        do {
            healthText = try await api.health()
            await loadSoul()
        } catch { healthText = error.localizedDescription }
    }

    // MARK: events

    private func handle(_ env: WsEnvelope) {
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
            let piece = env.data?.field("delta")?.string ?? env.data?.field("content")?.string ?? env.data?.string ?? ""
            guard !piece.isEmpty else { return }
            appendStream(kind: .reasoning, id: &reasoningLineId, piece: piece)
        case "tool_call", "tool", "running":
            let name = env.data?.field("name")?.string ?? env.data?.field("tool")?.string ?? "tool"
            let args = env.data?.field("arguments")?.pretty ?? env.data?.field("input")?.pretty ?? ""
            lines.append(ChatLine(kind: .tool, text: args, toolName: name, toolState: "running"))
        case "tool_result":
            let name = env.data?.field("name")?.string ?? "tool"
            let output = env.data?.field("output")?.pretty ?? env.data?.field("result")?.pretty ?? env.data?.pretty ?? ""
            if let index = lines.lastIndex(where: { $0.kind == .tool && $0.toolName == name && $0.toolState == "running" }) {
                lines[index].text = output
                lines[index].toolState = "done"
            } else {
                lines.append(ChatLine(kind: .tool, text: output, toolName: name, toolState: "done"))
            }
        case "status":
            let text = env.data?.field("message")?.string ?? env.data?.string ?? ""
            if !text.isEmpty { lines.append(ChatLine(kind: .status, text: text)) }
        case "approval":
            let approval = PendingApproval(
                id: env.data?.field("id")?.string ?? UUID().uuidString,
                requestId: env.data?.field("request_id")?.string,
                provider: env.data?.field("provider")?.string,
                title: env.data?.field("title")?.string,
                prompt: env.data?.field("prompt")?.string ?? env.data?.field("message")?.string,
                kind: env.data?.field("kind")?.string,
                sessionId: env.sessionId
            )
            approvals.append(approval)
        case "stream_end", "final", "done", "chat_done", "assistant_message":
            if let id = assistantLineId, let index = lines.firstIndex(where: { $0.id == id }) { lines[index].streaming = false }
            assistantLineId = nil
            reasoningLineId = nil
            let final = env.data?.field("content")?.string ?? env.data?.field("message")?.string
            if let final, !final.isEmpty, lines.last?.text != final {
                lines.append(ChatLine(kind: .assistant, text: final))
            }
        case "error":
            lines.append(ChatLine(kind: .error, text: env.error ?? env.data?.pretty ?? "出错了"))
        case "cancel", "cancelled":
            lines.append(ChatLine(kind: .system, text: "已停止"))
            assistantLineId = nil
        default:
            break
        }
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
        if role == "tool" || !message.toolCalls.isEmpty {
            for call in message.toolCalls {
                out.append(ChatLine(kind: .tool, text: call.arguments ?? "", toolName: call.name ?? "tool", toolState: "done"))
            }
        }
        let text = message.displayText
        if !text.isEmpty {
            let kind: ChatLine.Kind = role == "user" ? .user : (role == "system" ? .system : .assistant)
            out.append(ChatLine(kind: kind, text: text))
        }
        if let reasoning = message.reasoningContent, !reasoning.isEmpty {
            out.append(ChatLine(kind: .reasoning, text: reasoning))
        }
        return out
    }

    private func loadSoul() async {
        if let soul = try? await api.soul() { personaName = soul.name }
    }
}
