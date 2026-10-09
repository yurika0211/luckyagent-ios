import Foundation

enum APIError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case empty
    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "地址不对：\(s)"
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(240))"
        case .empty: return "空响应"
        }
    }
}

/// Same HTTP surface as the Android client. Auth is Bearer or X-API-Key.
final class APIClient {
    var settings: AppSettings
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .useDefaultKeys
        self.decoder = dec
        let enc = JSONEncoder()
        self.encoder = enc
    }

    func health() async throws -> String { try await getRaw("/api/v1/health/live") }
    func soul() async throws -> SoulInfo { try await get("/api/v1/soul") }
    func listModels(kind: String? = nil) async throws -> ModelsResponse {
        var q: [String: String] = [:]
        if let kind, !kind.isEmpty { q["kind"] = kind }
        return try await get("/api/v1/models", query: q)
    }
    func switchModel(kind: String, model: String, provider: String?) async throws {
        let body = SwitchModelRequest(kind: kind, model: model, provider: provider)
        let _: JSONValue = try await send("POST", "/api/v1/models/switch", body: body)
    }
    func listSessions(query: String = "") async throws -> [RuntimeSession] {
        let q = query.isEmpty ? [:] : ["q": query]
        let resp: SessionsResponse = try await get("/api/v1/sessions", query: q)
        return resp.sessions
    }
    func createSession(title: String) async throws -> RuntimeSession {
        try await send("POST", "/api/v1/sessions", body: ["title": title])
    }
    func patchSession(id: String, patch: SessionPatchRequest) async throws -> RuntimeSession {
        try await send("PATCH", "/api/v1/sessions/\(id)", body: patch)
    }
    func deleteSession(id: String) async throws {
        let _: JSONValue = try await send("DELETE", "/api/v1/sessions/\(id)")
    }
    func history(sessionId: String, limit: Int = 40, offset: Int = 0, full: Bool = false) async throws -> SessionHistory {
        var q = ["limit": "\(limit)", "offset": "\(offset)"]
        if full { q["include"] = "full" }
        return try await get("/api/v1/sessions/\(sessionId)", query: q)
    }
    func compact(sessionId: String, dryRun: Bool = false) async throws -> CompactSessionResult {
        try await send("POST", "/api/v1/sessions/\(sessionId)/compact", body: CompactSessionRequest(dryRun: dryRun))
    }
    func memoryStats() async throws -> MemoryStats { try await get("/api/v1/memory") }
    func recall(query: String, limit: Int = 50) async throws -> [MemoryEntry] {
        let raw: JSONValue = try await get("/api/v1/memory/recall", query: ["q": query, "limit": "\(limit)"])
        return decodeList(raw, key: "memories") ?? decodeList(raw, key: "results") ?? []
    }
    func memoryGraph(limit: Int = 300) async throws -> MemoryGraphResponse {
        try await get("/api/v1/memory/graph", query: ["limit": "\(limit)"])
    }
    func listGateways() async throws -> [GatewayStatus] {
        let raw: JSONValue = try await get("/api/v1/gateways")
        if let list: [GatewayStatus] = decodeList(raw, key: "gateways") { return list }
        if case .array = raw, let data = try? JSONEncoder().encode(raw) {
            return (try? JSONDecoder().decode([GatewayStatus].self, from: data)) ?? []
        }
        return []
    }
    func listSkills() async throws -> SkillsResponse { try await get("/api/v1/skills") }
    func listCommands() async throws -> [RuntimeCommand] {
        let raw: JSONValue = try await get("/api/v1/commands")
        return decodeList(raw, key: "commands") ?? []
    }
    func runCommand(command: String, args: String, sessionId: String) async throws -> CommandExecution {
        try await send("POST", "/api/v1/commands", body: CommandRequest(command: command, args: args, sessionId: sessionId))
    }
    func listCron() async throws -> CronListResponse { try await get("/api/v1/cron") }
    func listTasks(limit: Int = 200) async throws -> [TaskRecord] {
        let resp: TaskListResponse = try await get("/api/v1/tasks", query: ["limit": "\(limit)"])
        return resp.tasks
    }
    func taskEvents(id: String) async throws -> [TaskEvent] {
        let resp: TaskEventsResponse = try await get("/api/v1/tasks/\(id)/events")
        return resp.events
    }
    func taskResult(id: String) async throws -> String {
        let raw: JSONValue = try await get("/api/v1/tasks/\(id)/result")
        return raw.field("result")?.string ?? raw.string ?? raw.pretty
    }
    func cancelTask(id: String) async throws {
        let _: JSONValue = try await send("POST", "/api/v1/tasks/\(id)/cancel", body: ["reason": "cancelled from iOS"])
    }
    func autonomyDashboard() async throws -> AutonomyDashboardResponse {
        try await get("/api/v1/autonomy/dashboard")
    }
    func listApprovals() async throws -> [PendingApproval] {
        let raw: JSONValue = try await get("/api/v1/approvals")
        return decodeList(raw, key: "approvals") ?? []
    }
    func inspectContext(sessionId: String) async throws -> ContextInspectResponse {
        try await get("/api/v1/context", query: ["session_id": sessionId, "inspect": "1"])
    }
    func toolTrace(sessionId: String) async throws -> String {
        try await getRaw("/api/v1/sessions/\(sessionId)/tools")
    }
    func getJSON(_ path: String) async throws -> String { try await getRaw(path) }

    func upload(data: Data, fileName: String, mime: String) async throws -> MediaAttachment {
        let boundary = "LuckyAgent-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (respData, _) = try await raw("POST", "/api/v1/uploads", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let decoded = try decoder.decode(UploadResponse.self, from: respData)
        guard let first = decoded.attachments.first else { throw APIError.empty }
        return first
    }

    // MARK: - transport

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await raw("GET", path, query: query)
        return try decoder.decode(T.self, from: data)
    }

    private func getRaw(_ path: String, query: [String: String] = [:]) async throws -> String {
        let (data, _) = try await raw("GET", path, query: query)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B) async throws -> T {
        let payload = try encoder.encode(body)
        let (data, _) = try await raw(method, path, body: payload, contentType: "application/json")
        if T.self == JSONValue.self, data.isEmpty { return JSONValue.null as! T }
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    private func send<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        let (data, _) = try await raw(method, path)
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    private func raw(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(string: absolute(path)) else { throw APIError.badURL(path) }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.badURL(path) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            if settings.useBearer {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            } else {
                req.setValue(key, forHTTPHeaderField: "X-API-Key")
            }
        }
        if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    func absolute(_ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        let base = settings.apiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return base + suffix
    }

    func webSocketURL(sessionId: String) -> URL? {
        let base = absolute("/api/v1/ws")
        guard var components = URLComponents(string: base) else { return nil }
        if components.scheme == "https" { components.scheme = "wss" }
        if components.scheme == "http" { components.scheme = "ws" }
        var items = components.queryItems ?? []
        if !sessionId.isEmpty { items.append(URLQueryItem(name: "session", value: sessionId)) }
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !settings.useBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    private func decodeList<T: Decodable>(_ value: JSONValue, key: String) -> [T]? {
        let payload: JSONValue
        if case .array = value { payload = value }
        else if let nested = value.field(key) { payload = nested }
        else { return nil }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }
}
