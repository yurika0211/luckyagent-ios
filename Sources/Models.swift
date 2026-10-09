import Foundation

// Wire models for the LuckyAgent HTTP + WebSocket API.
// Field names match the Go runtime and the Android client. Unknown keys are ignored.

struct SoulInfo: Codable, Equatable {
    var name: String = ""
    var systemPrompt: String = ""
    enum CodingKeys: String, CodingKey { case name; case systemPrompt = "system_prompt" }
}

struct SessionsResponse: Codable {
    var sessions: [RuntimeSession] = []
    var count: Int?
}

struct RuntimeSession: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var pinned: Bool = false
    var project: String?
    var messageCount: Int?
    var byteSize: Int64?
    var format: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, pinned, project, format
        case messageCount = "message_count"
        case byteSize = "byte_size"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }
}

struct SessionHistory: Codable {
    var id: String?
    var title: String?
    var pinned: Bool = false
    var project: String?
    var messageCount: Int?
    var format: String?
    var byteSize: Int64?
    var contentTruncated: Bool?
    var messages: [ProviderMessage] = []
    var limit: Int?
    var offset: Int?
    var returned: Int?
    var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, pinned, project, format, messages, limit, offset, returned
        case messageCount = "message_count"
        case byteSize = "byte_size"
        case contentTruncated = "content_truncated"
        case hasMore = "has_more"
    }
}

struct SessionPatchRequest: Codable {
    var title: String?
    var pinned: Bool?
    var project: String?
}

struct CompactSessionRequest: Codable {
    var dryRun: Bool = false
    var forceLocal: Bool = false
    enum CodingKeys: String, CodingKey { case dryRun = "dry_run"; case forceLocal = "force_local" }
}

struct CompactSessionResult: Codable {
    var boundaryId: String?
    var trigger: String?
    var summary: String?
    var droppedMessages: Int?
    var retainedMessages: Int?
    var preTokenEstimate: Int?
    var postTokenEstimate: Int?
    var display: CompactDisplay?
    enum CodingKeys: String, CodingKey {
        case trigger, summary, display
        case boundaryId = "boundary_id"
        case droppedMessages = "dropped_messages"
        case retainedMessages = "retained_messages"
        case preTokenEstimate = "pre_token_estimate"
        case postTokenEstimate = "post_token_estimate"
    }
}

struct CompactDisplay: Codable {
    var title: String?
    var subtitle: String?
    var message: String?
}

struct ProviderMessage: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var role: String?
    var content: String?
    var reasoningContent: String?
    var contentParts: [ProviderContentPart] = []
    var attachments: [MediaAttachment] = []
    var createdAt: String?
    var name: String?
    var toolCallId: String?
    var toolCalls: [HistoryToolCall] = []
    var usage: TokenUsage?

    enum CodingKeys: String, CodingKey {
        case role, content, attachments, name, usage
        case reasoningContent = "reasoning_content"
        case contentParts = "content_parts"
        case createdAt = "created_at"
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    var displayText: String {
        if let content, !content.isEmpty { return content }
        let joined = contentParts.compactMap(\.text).joined(separator: "\n")
        return joined
    }
}

struct ProviderContentPart: Codable, Equatable {
    var type: String?
    var text: String?
}

struct HistoryToolCall: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String?
    var arguments: String?
    enum CodingKeys: String, CodingKey { case id, name, arguments }
}

struct TokenUsage: Codable, Equatable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct MediaAttachment: Codable, Identifiable, Equatable {
    var id: String { fileId ?? fileUrl ?? fileName ?? UUID().uuidString }
    var type: String = "document"
    var fileId: String?
    var fileUrl: String?
    var filePath: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int64?
    enum CodingKeys: String, CodingKey {
        case type
        case fileId = "file_id"
        case fileUrl = "file_url"
        case filePath = "file_path"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct UploadResponse: Codable { var attachments: [MediaAttachment] = [] }

struct ModelRef: Codable, Identifiable, Equatable {
    var id: String
    var kind: String
    var provider: String?
    var displayName: String?
    var apiBase: String?
    var protocolName: String?
    var current: Bool = false
    enum CodingKeys: String, CodingKey {
        case id, kind, provider, current
        case displayName = "display_name"
        case apiBase = "api_base"
        case protocolName = "protocol"
    }
    var label: String { displayName?.isEmpty == false ? displayName! : id }
}

struct ModelsResponse: Codable {
    var models: [ModelRef] = []
    var count: Int?
    var source: String?
    var error: String?
}

struct SwitchModelRequest: Codable {
    var kind: String
    var model: String
    var provider: String?
}

struct MemoryStats: Codable {
    var count: Int?
    var tiers: [String: Int]?
}

struct MemoryEntry: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var content: String = ""
    var category: String?
    var tier: String?
    var score: Double?
    var title: String?
}

struct MemoryGraphResponse: Codable {
    var nodes: [MemoryGraphNode] = []
    var edges: [MemoryGraphEdge] = []
}

struct MemoryGraphNode: Codable, Identifiable {
    var id: String = UUID().uuidString
    var label: String?
    var title: String?
    var category: String?
}

struct MemoryGraphEdge: Codable, Identifiable {
    var id: String = UUID().uuidString
    var source: String?
    var target: String?
    var label: String?
}

struct GatewayStatus: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var platform: String?
    var running: Bool = false
    var status: String?
    var error: String?
}

struct SkillInfo: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String = ""
    var description: String?
    var enabled: Bool?
}

struct SkillsResponse: Codable {
    var skills: [SkillInfo] = []
    var count: Int?
}

struct RuntimeCommand: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String = ""
    var description: String?
    var usage: String?
}

struct CommandRequest: Codable {
    var command: String
    var args: String = ""
    var sessionId: String = ""
    enum CodingKeys: String, CodingKey {
        case command, args
        case sessionId = "session_id"
    }
}

struct CommandExecution: Codable {
    var ok: Bool?
    var output: String?
    var error: String?
    var result: String?
}

struct CronListResponse: Codable {
    var running: Bool = false
    var count: Int = 0
    var jobs: [CronJob] = []
}

struct CronJob: Codable, Identifiable, Equatable {
    var id: String = ""
    var name: String = ""
    var description: String = ""
    var schedule: String = ""
    var status: String = "unknown"
    var lastRun: String?
    var nextRun: String?
    var command: String?
    enum CodingKeys: String, CodingKey {
        case id, name, description, schedule, status, command
        case lastRun = "last_run"
        case nextRun = "next_run"
    }
}

struct TaskListResponse: Codable { var tasks: [TaskRecord] = [] }

struct TaskRecord: Codable, Identifiable, Equatable {
    var id: String = ""
    var parentId: String?
    var title: String?
    var description: String?
    var status: String = ""
    var mode: String?
    var source: String?
    var error: String?
    var result: String?
    var createdAt: String?
    var startedAt: String?
    var completedAt: String?
    var progress: Double?
    enum CodingKeys: String, CodingKey {
        case id, title, description, status, mode, source, error, result, progress
        case parentId = "parent_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
    var headline: String {
        let text = (title?.isEmpty == false ? title : description) ?? ""
        return text.isEmpty ? id : text
    }
}

struct TaskTreeResponse: Codable {
    var task: TaskRecord?
    var children: [TaskTreeResponse] = []
}

struct TaskEvent: Codable, Identifiable {
    var id: String = UUID().uuidString
    var type: String = ""
    var taskId: String?
    var message: String?
    var timestamp: String?
    enum CodingKeys: String, CodingKey {
        case id, type, message, timestamp
        case taskId = "task_id"
    }
}

struct TaskEventsResponse: Codable {
    var taskId: String?
    var events: [TaskEvent] = []
    enum CodingKeys: String, CodingKey { case events; case taskId = "task_id" }
}

struct AutonomyDashboardResponse: Codable {
    var generatedAt: String?
    var queue: AutonomyQueueCounts?
    var pool: AutonomyPoolStats?
    var workers: [AutonomyWorker] = []
    var tasks: [AutonomyTaskSummary] = []
    enum CodingKeys: String, CodingKey {
        case queue, pool, workers, tasks
        case generatedAt = "generated_at"
    }
}

struct AutonomyQueueCounts: Codable {
    var ready: Int = 0
    var inProgress: Int = 0
    var blocked: Int = 0
    var done: Int = 0
    enum CodingKeys: String, CodingKey {
        case ready, blocked, done
        case inProgress = "in_progress"
    }
}

struct AutonomyPoolStats: Codable {
    var workerCount: Int = 0
    enum CodingKeys: String, CodingKey { case workerCount = "worker_count" }
}

struct AutonomyWorker: Codable, Identifiable {
    var id: String = ""
    var state: String = ""
    var currentTaskId: String?
    enum CodingKeys: String, CodingKey {
        case id, state
        case currentTaskId = "current_task_id"
    }
}

struct AutonomyTaskSummary: Codable, Identifiable, Equatable {
    var id: String = ""
    var title: String = ""
    var description: String = ""
    var priority: String = ""
    var state: String = ""
    var assignedTo: String?
    enum CodingKeys: String, CodingKey {
        case id, title, description, priority, state
        case assignedTo = "assigned_to"
    }
}

struct PendingApproval: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var requestId: String?
    var provider: String?
    var title: String?
    var prompt: String?
    var kind: String?
    var sessionId: String?
    enum CodingKeys: String, CodingKey {
        case id, title, prompt, kind, provider
        case requestId = "request_id"
        case sessionId = "session_id"
    }
    var stableId: String { requestId ?? id }
}

struct ApprovalsResponse: Codable {
    var approvals: [PendingApproval] = []
}

struct ContextInspectResponse: Codable {
    var sessionId: String?
    var tokens: Int?
    var limit: Int?
    var summary: String?
    enum CodingKeys: String, CodingKey {
        case tokens, limit, summary
        case sessionId = "session_id"
    }
}

// MARK: - WebSocket envelopes

struct WsEnvelope: Codable {
    var type: String = ""
    var id: String?
    var eventId: String?
    var sessionId: String?
    var error: String?
    var data: JSONValue?
    enum CodingKeys: String, CodingKey {
        case type, id, error, data
        case eventId = "event_id"
        case sessionId = "session_id"
    }
}

struct ChatOutbound: Codable {
    var type: String = "chat"
    var id: String
    var sessionId: String
    var data: ChatOutboundData
    enum CodingKeys: String, CodingKey {
        case type, id, data
        case sessionId = "session_id"
    }
}

struct ChatOutboundData: Codable {
    var message: String
    var maxIterations: Int = 8
    var attachments: [MediaAttachment] = []
    enum CodingKeys: String, CodingKey {
        case message, attachments
        case maxIterations = "max_iterations"
    }
}

struct CancelOutbound: Codable {
    var type: String = "cancel"
    var sessionId: String
    var data: CancelOutboundData
    enum CodingKeys: String, CodingKey { case type, data; case sessionId = "session_id" }
}

struct CancelOutboundData: Codable {
    var sessionId: String
    enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
}

struct ApprovalResponseOutbound: Codable {
    var type: String = "approval_response"
    var id: String
    var sessionId: String
    var data: ApprovalResponseData
    enum CodingKeys: String, CodingKey { case type, id, data; case sessionId = "session_id" }
}

struct ApprovalResponseData: Codable {
    var requestId: String
    var provider: String
    var decision: String
    var input: String
    enum CodingKeys: String, CodingKey {
        case decision, input, provider
        case requestId = "request_id"
    }
}

struct LuckyOutbound: Codable {
    var type: String = "lucky"
    var id: String
    var sessionId: String
    var data: LuckyOutboundData
    enum CodingKeys: String, CodingKey { case type, id, data; case sessionId = "session_id" }
}

struct LuckyOutboundData: Codable { var action: String }

enum SocketState: String, Equatable {
    case idle, connecting, connected, running, reconnecting, closed, error
}

/// A small JSON value so WebSocket `data` can be decoded without a fixed schema.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var string: String? { if case .string(let v) = self { return v }; return nil }
    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }

    func field(_ key: String) -> JSONValue? { object?[key] }

    var pretty: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .bool(let v): return v ? "true" : "false"
        case .null: return ""
        case .object, .array:
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(self), let text = String(data: data, encoding: .utf8) { return text }
            return ""
        }
    }
}

struct ChatLine: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, reasoning, tool, status, error, system }
    var id: String = UUID().uuidString
    var kind: Kind
    var text: String
    var toolName: String?
    var toolState: String?
    var streaming: Bool = false
    var createdAt: Date = Date()
}

enum AppDestination: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case tasks = "Tasks"
    case background = "Background"
    case cron = "Cron"
    case trace = "Trace"
    case gateways = "Gateways"
    case skills = "Skills"
    case memory = "Memory"
    case settings = "Settings"
    var id: String { rawValue }

    var group: String {
        switch self {
        case .chat: return "WORKSPACE"
        case .settings: return "SYSTEM"
        default: return "RUNTIME"
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left"
        case .tasks: return "checklist"
        case .background: return "square.stack.3d.up"
        case .cron: return "clock"
        case .trace: return "point.topleft.down.to.point.bottomright.curvepath"
        case .gateways: return "point.3.connected.trianglepath.dotted"
        case .skills: return "puzzlepiece.extension"
        case .memory: return "brain"
        case .settings: return "gearshape"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var apiBase: String = "http://127.0.0.1:9090"
    var apiKey: String = ""
    var useBearer: Bool = true
    var sessionId: String = ""
    var appearance: String = "system" // system / light / dark
    var chromeOpacity: Double = 100
    var cardOpacity: Double = 100
}

struct PairingPayload: Equatable {
    var apiBase: String
    var apiKey: String
    var name: String
}

/// `lh qr` prints JSON: {"v":1,"url":"http://...","token":"...","expires_at":"...","ttl_hours":N,"name":"..."}.
/// The token is a process-local key and the Android client sends it as X-API-Key, not Bearer.
struct PairingQrWire: Decodable {
    var v: Int = 0
    var url: String = ""
    var token: String = ""
    var expiresAt: String = ""
    var ttlHours: Int = 0
    var name: String = ""
    enum CodingKeys: String, CodingKey {
        case v, url, token, name
        case expiresAt = "expires_at"
        case ttlHours = "ttl_hours"
    }
}

enum PairingQR {
    static func parse(_ raw: String) -> PairingPayload? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PairingQrWire.self, from: data) else { return nil }
        guard parsed.v == 1 else { return nil }
        let url = parsed.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = parsed.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://"), !token.isEmpty else { return nil }
        let label = parsed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingPayload(apiBase: String(url.dropLast(url.hasSuffix("/") ? 1 : 0)), apiKey: token, name: label.isEmpty ? "LuckyAgent" : label)
    }
}

