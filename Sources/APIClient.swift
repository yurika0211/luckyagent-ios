import Foundation

enum APIError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case empty
    case invalidUpload(String)
    case attachmentUnavailable
    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "地址不对：\(s)"
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(240))"
        case .empty: return "空响应"
        case .invalidUpload(let reason): return reason
        case .attachmentUnavailable: return "服务端未提供附件的可下载地址"
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
        var sessions: [RuntimeSession] = []
        var seen: Set<String> = []
        var offset = 0
        while true {
            var q = ["limit": "200", "offset": "\(offset)"]
            if !query.isEmpty { q["q"] = query }
            let page: SessionsResponse = try await get("/api/v1/sessions", query: q)
            let newSessions = page.sessions.filter { seen.insert($0.id).inserted }
            sessions.append(contentsOf: newSessions)
            guard page.hasMore == true else { return sessions }
            let nextOffset = (page.offset ?? offset) + page.sessions.count
            guard !newSessions.isEmpty, nextOffset > offset, page.offset == nil || page.offset == offset else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Session pagination made no progress"))
            }
            offset = nextOffset
        }
    }
    func createSession(title: String) async throws -> RuntimeSession {
        try await send("POST", "/api/v1/sessions", body: ["title": title])
    }
    func patchSession(id: String, patch: SessionPatchRequest) async throws -> RuntimeSession {
        try await send("PATCH", "/api/v1/sessions/\(pathComponent(id))", body: patch)
    }
    func deleteSession(id: String) async throws {
        let _: JSONValue = try await send("DELETE", "/api/v1/sessions/\(pathComponent(id))")
    }
    func history(sessionId: String, limit: Int = 40, offset: Int = 0, full: Bool = false) async throws -> SessionHistory {
        var q = ["limit": "\(limit)", "offset": "\(offset)"]
        if full { q["include"] = "full" }
        return try await get("/api/v1/sessions/\(pathComponent(sessionId))", query: q)
    }
    func compact(sessionId: String, dryRun: Bool = false) async throws -> CompactSessionResult {
        try await send("POST", "/api/v1/sessions/\(pathComponent(sessionId))/compact", body: CompactSessionRequest(dryRun: dryRun))
    }
    func memoryStats() async throws -> MemoryStats { try await get("/api/v1/memory") }
    func recall(query: String, limit: Int = 50) async throws -> [MemoryEntry] {
        let raw: JSONValue = try await get("/api/v1/memory/recall", query: ["q": query, "limit": "\(limit)"])
        return try decodeList(raw, keys: ["results", "memories"])
    }
    func memoryGraph(limit: Int = 300) async throws -> MemoryGraphResponse {
        try await get("/api/v1/memory/graph", query: ["limit": "\(limit)"])
    }
    func listGateways() async throws -> [GatewayStatus] {
        let raw: JSONValue = try await get("/api/v1/gateways")
        return try decodeList(raw, keys: ["gateways"])
    }
    func listSkills() async throws -> SkillsResponse { try await get("/api/v1/skills") }
    func listCommands() async throws -> [RuntimeCommand] {
        let raw: JSONValue = try await get("/api/v1/commands")
        return try decodeList(raw, keys: ["commands"])
    }
    func runCommand(command: String, args: String, sessionId: String) async throws -> CommandExecution {
        try await send("POST", "/api/v1/commands", body: CommandRequest(command: command, args: args, sessionId: sessionId))
    }
    func listCron() async throws -> CronListResponse { try await get("/api/v1/cron") }
    func listTasks(limit: Int = 200) async throws -> [TaskRecord] {
        let resp: TaskListResponse = try await get("/api/v1/tasks", query: ["limit": "\(limit)"])
        return resp.tasks
    }
    func getTask(id: String) async throws -> TaskRecord {
        try await get("/api/v1/tasks/\(pathComponent(id))")
    }
    func taskEvents(id: String) async throws -> [TaskEvent] {
        let resp: TaskEventsResponse = try await get("/api/v1/tasks/\(pathComponent(id))/events")
        return resp.events
    }
    func taskResult(id: String) async throws -> String {
        let raw: JSONValue = try await get("/api/v1/tasks/\(pathComponent(id))/result")
        return raw.field("result")?.string ?? raw.string ?? raw.pretty
    }
    func cancelTask(id: String) async throws {
        let _: JSONValue = try await send("POST", "/api/v1/tasks/\(pathComponent(id))/cancel", body: ["reason": "cancelled from iOS"])
    }
    func autonomyDashboard() async throws -> AutonomyDashboardResponse {
        try await get("/api/v1/autonomy/dashboard")
    }
    func listApprovals() async throws -> [PendingApproval] {
        let raw: JSONValue = try await get("/api/v1/approvals")
        return try decodeList(raw, keys: ["approvals"])
    }
    func inspectContext(sessionId: String) async throws -> ContextInspectResponse {
        try await get("/api/v1/context", query: ["session_id": sessionId, "inspect": "1"])
    }
    func toolTrace(sessionId: String) async throws -> String {
        try await getRaw("/api/v1/sessions/\(pathComponent(sessionId))/tools")
    }
    func getJSON(_ path: String) async throws -> String { try await getRaw(path) }

    func upload(data: Data, fileName: String, mime: String) async throws -> MediaAttachment {
        // Quote multipart parameters so a selected filename cannot create extra headers.
        let safeName = fileName.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeMIME = mime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeMIME.contains("\r"), !safeMIME.contains("\n") else { throw APIError.invalidUpload("附件 MIME 类型无效") }
        let boundary = "LuckyAgent-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName.isEmpty ? "upload" : safeName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(safeMIME.isEmpty ? "application/octet-stream" : safeMIME)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        guard body.count <= 32 << 20 else { throw APIError.invalidUpload("附件超过服务端 32 MiB 上传限制") }
        let (respData, _) = try await raw("POST", "/api/v1/uploads", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let decoded = try decoder.decode(UploadResponse.self, from: respData)
        guard let first = decoded.attachments.first else { throw APIError.empty }
        return first
    }

    func downloadAttachment(_ attachment: MediaAttachment) async throws -> URL {
        guard let reference = attachment.fileUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else { throw APIError.attachmentUnavailable }
        guard let url = URL(string: absolute(reference)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.fragment == nil else { throw APIError.badURL(reference) }
        let backend = BackendURL.normalize(settings.apiBase).flatMap(URL.init(string:))
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let backend, Self.sameOrigin(url, backend) { authorize(&request) }
        let delegate = AttachmentDownloadDelegate(backend: backend)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw APIError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(decoding: data.prefix(240), as: UTF8.self))
        }
        let rawName = attachment.fileName ?? url.lastPathComponent
        let name = (rawName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LuckyAgent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name.isEmpty ? "attachment" : String(name.suffix(120)))
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
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
            components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw APIError.badURL(path) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&req)
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
        if let scheme = URLComponents(string: path)?.scheme {
            return ["http", "https"].contains(scheme.lowercased()) ? path : ""
        }
        guard let base = BackendURL.normalize(settings.apiBase) else { return "" }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return base + suffix
    }

    func webSocketURL(sessionId: String) -> URL? {
        let base = absolute("/api/v1/ws")
        guard var components = URLComponents(string: base), components.host?.isEmpty == false else { return nil }
        if components.scheme == "https" { components.scheme = "wss" }
        else if components.scheme == "http" { components.scheme = "ws" }
        else { return nil }
        var items = components.queryItems ?? []
        if !sessionId.isEmpty { items.append(URLQueryItem(name: "session", value: sessionId)) }
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, !settings.useBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    private func authorize(_ request: inout URLRequest) {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if settings.useBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        else { request.setValue(key, forHTTPHeaderField: "X-API-Key") }
    }

    fileprivate static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftScheme = lhs.scheme?.lowercased()
        let rightScheme = rhs.scheme?.lowercased()
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return leftScheme == rightScheme && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? value
    }

    private func decodeList<T: Decodable>(_ value: JSONValue, keys: [String]) throws -> [T] {
        let payload: JSONValue
        if case .array = value { payload = value }
        else if let nested = keys.compactMap({ value.field($0) }).first { payload = nested }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing list field: \(keys.joined(separator: ", "))"))
        }
        if payload == .null { return [] } // A nil Go slice is a valid empty result.
        let data = try encoder.encode(payload)
        return try decoder.decode([T].self, from: data)
    }
}

/// URLSession can carry custom headers through redirects; never forward a runtime key to another origin.
private final class AttachmentDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let backend: URL?
    init(backend: URL?) { self.backend = backend }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              target.user == nil, target.password == nil else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if let backend, APIClient.sameOrigin(target, backend) {
            completionHandler(redirected)
            return
        }
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "X-API-Key")
        completionHandler(redirected)
    }
}
