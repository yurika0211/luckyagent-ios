import Foundation
import XCTest
@testable import LuckyAgent

private final class HistoryFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: HistoryHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else { return }
        let data = fixture.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HistoryHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var historyQueries: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return urls.filter { $0.path == "/api/v1/sessions/session-1" }.map { url in
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
    }

    func response(for request: URLRequest) -> Data {
        let url = request.url!
        lock.lock(); urls.append(url); lock.unlock()
        if url.path == "/api/v1/approvals" { return Data(#"{"approvals":[]}"#.utf8) }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let offset = Int(query["offset"] ?? "0") ?? 0
        let limit = Int(query["limit"] ?? "80") ?? 80
        let messages: [[String: Any]]
        let total: Int
        let hasMore: Bool
        if limit == 1 {
            messages = [["role": "assistant", "content": "newest message"]]
            total = 154
            hasMore = true
        } else if offset > 0 {
            messages = (0..<70).map { ["role": "user", "content": "older-\($0)"] }
            total = 154
            hasMore = false
        } else {
            var recent = (0..<80).map { ["role": "assistant", "content": "recent-\($0)"] as [String: Any] }
            // One provider message becomes three visible rows: tool, content, reasoning.
            recent[0]["reasoning_content"] = "history reasoning"
            recent[0]["tool_calls"] = [["id": "call-1", "name": "file_read", "arguments": "{}"]]
            messages = recent
            total = 150
            hasMore = true
        }
        return try! JSONSerialization.data(withJSONObject: [
            "id": "session-1", "messages": messages, "message_count": total,
            "returned": messages.count, "offset": offset, "limit": limit, "has_more": hasMore
        ])
    }
}

@MainActor
final class AppModelHistoryTests: XCTestCase {
    private var session: URLSession?
    private var model: AppModel?
    private var suite: String?

    override func tearDown() {
        model?.suspendConnection()
        session?.invalidateAndCancel()
        HistoryFixtureProtocol.fixture = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeModel() -> (AppModel, APIClient, HistoryHTTPFixture) {
        let suite = "LuckyAgentHistoryTests-\(UUID().uuidString)"
        self.suite = suite
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(apiBase: "http://history.runtime.test", sessionId: "session-1")
        defaults.set(try! JSONEncoder().encode(settings), forKey: "luckyagent.settings")
        let store = SettingsStore(defaults: defaults, keychainService: suite)
        let fixture = HistoryHTTPFixture()
        HistoryFixtureProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HistoryFixtureProtocol.self]
        let session = URLSession(configuration: config)
        self.session = session
        let api = APIClient(settings: store.settings, session: session)
        let model = AppModel(store: store, api: api)
        self.model = model
        return (model, api, fixture)
    }

    func testOlderHistoryUsesProviderOffsetAndAccountsForNewMessages() async {
        let (model, _, fixture) = makeModel()
        await model.loadHistory()
        XCTAssertEqual(model.lines.count, 82)
        XCTAssertEqual(model.lines.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(model.lines.filter { $0.kind == .reasoning }.count, 1)
        XCTAssertTrue(model.hasOlderHistory)

        await model.loadOlder()
        let queries = fixture.historyQueries
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[0]["offset"], "0")
        XCTAssertEqual(queries[0]["include"], "full")
        XCTAssertEqual(queries[1]["limit"], "1")
        // 80 wire messages already loaded, plus four messages added at the newest end.
        XCTAssertEqual(queries[2]["offset"], "84")
        XCTAssertEqual(queries[2]["include"], "full")
        XCTAssertEqual(model.lines.count, 152)
        XCTAssertEqual(model.lines.first?.text, "older-0")
        XCTAssertEqual(model.lines.last?.text, "recent-79")
        XCTAssertFalse(model.hasOlderHistory)
        await model.loadOlder()
        XCTAssertEqual(fixture.historyQueries.count, 3)
    }

    func testSessionRoundTripRestoresDraftStreamingRowsAndEachSessionsQueue() async {
        let (model, api, _) = makeModel()
        await model.loadHistory()
        model.handle(event("stream_chunk", session: "session-1", data: ["content": .string("partial")]))
        model.handle(event("reasoning", session: "session-1", data: ["content": .string("thought")]))
        model.handle(event("approval", session: "session-1", data: ["request_id": .string("approval-1"), "summary": .string("Confirm")]))
        model.draft = "unsent session one draft"
        var attachment = MediaAttachment()
        attachment.fileName = "draft.txt"
        attachment.fileUrl = "/api/v1/artifacts?path=draft.txt"
        model.pendingAttachments = [attachment]
        model.outbound.enqueue(item(id: "one-active", session: "session-1", status: .sending))
        model.outbound.enqueue(item(id: "one-queued", session: "session-1", status: .queued))
        let originalRows = model.lines
        let originalApprovals = model.approvals

        // Snapshot restoration is independent of transport. Invalidate only the
        // injected API client's address so selectSession cannot open a live socket.
        api.settings.apiBase = ""
        await model.selectSession(RuntimeSession(id: "session-2"))
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        model.draft = "session two draft"
        model.handle(event("stream_chunk", session: "session-2", data: ["content": .string("second partial")]))
        model.outbound.enqueue(item(id: "two-queued", session: "session-2", status: .queued))
        let allQueued = model.outbound.items

        await model.selectSession(RuntimeSession(id: "session-1"))
        XCTAssertEqual(model.draft, "unsent session one draft")
        XCTAssertEqual(model.lines, originalRows)
        XCTAssertEqual(model.approvals, originalApprovals)
        XCTAssertEqual(model.pendingAttachments, [attachment])
        XCTAssertTrue(model.hasOlderHistory)
        XCTAssertEqual(model.outbound.items, allQueued)
        XCTAssertEqual(model.outbound.visible(sessionId: "session-1").count, 2)
        model.handle(event("stream_chunk", session: "session-1", data: ["content": .string(" continued")]))
        model.handle(event("reasoning", session: "session-1", data: ["content": .string(" continued")]))
        XCTAssertEqual(model.lines.count, originalRows.count)
        XCTAssertEqual(model.lines.last { $0.kind == .assistant }?.text, "partial continued")
        XCTAssertEqual(model.lines.last { $0.kind == .reasoning }?.text, "thought continued")
        await model.selectSession(RuntimeSession(id: "session-2"))
        XCTAssertEqual(model.draft, "session two draft")
        XCTAssertEqual(model.lines.map(\.text), ["second partial"])
        XCTAssertEqual(model.outbound.items, allQueued)
    }

    func testReplayCompletesOfflineTurnBeforeHandshakeAndKeepsNextMessageQueued() async throws {
        let (model, api, _) = makeModel()
        var connections: [HistorySocketConnection] = []
        let socket = SocketClient(api: api, onEvent: { [weak model] in model?.handle($0) }, onState: { [weak model] state, _ in
            model?.socketState = state
        }, connectionFactory: { _ in
            let connection = HistorySocketConnection()
            connections.append(connection)
            return connection
        })
        model.socket = socket
        socket.connect(sessionId: "session-1")
        let first = try XCTUnwrap(connections.first)
        first.onOpen?()
        await drainCallbacks()
        first.emit(#"{"type":"status","session_id":"session-1","data":{"state":"connected"}}"#)
        await drainCallbacks()
        model.draft = "first question"; model.send()
        model.draft = "next question"; model.send()
        let requestId = try XCTUnwrap(model.outbound.items.first?.requestId)
        first.emit(#"{"type":"stream_chunk","session_id":"session-1","event_id":"durable-1","run_id":"run-1","parent_id":"\#(requestId)","data":{"content":"partial"}}"#)
        await drainCallbacks()
        socket.disconnect()
        socket.connect(sessionId: "session-1")
        let second = try XCTUnwrap(connections.last)
        XCTAssertFalse(first === second)
        second.onOpen?()
        await drainCallbacks()
        let handshake = try XCTUnwrap(second.messages().first)
        XCTAssertEqual((handshake["data"] as? [String: Any])?["last_message_id"] as? String, "durable-1")
        // The real server replays durable output before acknowledging reconnect.
        second.emit(#"{"type":"stream_end","session_id":"session-1","event_id":"durable-2","run_id":"run-1","parent_id":"\#(requestId)","data":{"full_response":"completed while offline"}}"#)
        await drainCallbacks()
        XCTAssertEqual(model.outbound.items.map(\.status), [.queued])
        XCTAssertEqual(model.lines.last { $0.kind == .assistant }?.text, "completed while offline")
        XCTAssertEqual(try second.messages().map { $0["type"] as? String }, ["reconnect"])
        second.emit(#"{"type":"status","session_id":"session-1","data":{"state":"connected"}}"#)
        await drainCallbacks()
        XCTAssertEqual(model.outbound.items.map(\.status), [.sending])
        XCTAssertEqual(try second.messages().map { $0["type"] as? String }, ["reconnect", "chat"])
        XCTAssertEqual((try second.messages().last?["data"] as? [String: Any])?["message"] as? String, "next question")
        socket.disconnect()
    }

    private func event(_ type: String, session: String, data: [String: JSONValue]) -> WsEnvelope {
        WsEnvelope(type: type, sessionId: session, data: .object(data))
    }

    private func item(id: String, session: String, status: OutboundStatus) -> OutboundItem {
        OutboundItem(id: id, sessionId: session, preview: id, message: id, attachments: [], requestId: status == .sending ? "request-1" : nil, status: status, error: nil)
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

private final class HistorySocketConnection: SocketConnection {
    var onOpen: (() -> Void)?
    var onClose: ((String) -> Void)?
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var received: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    func resume() {}
    func close() {}
    func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) { received = completion }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) { sent.append(message) }
    func emit(_ text: String) { received?(.success(.string(text))) }
    func messages() throws -> [[String: Any]] {
        try sent.map { message in
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let value): data = value
            @unknown default: data = Data()
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
}
