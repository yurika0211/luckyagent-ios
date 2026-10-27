import XCTest
@testable import LuckyAgent

/// Fixtures follow the Go API at luckyagent/internal/{server,provider,task,tool}.
final class ModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testCreateAndUnpinnedSessionResponses() throws {
        let json = #"{"id":"s1","title":"New","message_count":0,"created_at":"2026-10-17T00:00:00Z"}"#
        let session = try decode(RuntimeSession.self, json)
        XCTAssertEqual(session.id, "s1")
        XCTAssertFalse(session.pinned)
        let list = try decode(SessionsResponse.self, #"{"sessions":[{"id":"s1"}],"count":1}"#)
        XCTAssertEqual(list.sessions.first?.id, "s1")
        XCTAssertThrowsError(try decode(RuntimeSession.self, #"{"title":"Missing identity"}"#))
    }

    func testPlainHistoryMessageOmitsOptionalCollections() throws {
        let history = try decode(SessionHistory.self, #"{"id":"s1","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{}"}]}]}"#)
        XCTAssertEqual(history.messages.first?.displayText, "hi")
        XCTAssertEqual(history.messages.first?.attachments, [])
        XCTAssertEqual(history.messages.last?.toolCalls.first?.name, "read_file")
        XCTAssertEqual(history.messages.last?.toolCalls.first?.id, "call-1")
        XCTAssertFalse(history.pinned)
    }

    func testHistoryRetainsAttachmentAndTokenUsage() throws {
        let message = try decode(ProviderMessage.self, #"{"role":"assistant","content":"Done","attachments":[{"type":"image","file_path":"/tmp/result.png","mime_type":"image/png"}],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#)
        XCTAssertEqual(message.attachments.first?.filePath, "/tmp/result.png")
        XCTAssertEqual(message.usage?.totalTokens, 16)
        let attachment = try XCTUnwrap(message.attachments.first)
        XCTAssertEqual(attachment.id, attachment.id)
    }

    func testNilGoSlicesBecomeEmptyCollections() throws {
        XCTAssertTrue(try decode(SessionHistory.self, #"{"messages":null}"#).messages.isEmpty)
        XCTAssertTrue(try decode(TaskListResponse.self, #"{"tasks":null}"#).tasks.isEmpty)
        XCTAssertTrue(try decode(TaskEventsResponse.self, #"{"events":null}"#).events.isEmpty)
        XCTAssertTrue(try decode(ModelsResponse.self, #"{"models":null}"#).models.isEmpty)
        XCTAssertTrue(try decode(SkillsResponse.self, #"{"skills":null}"#).skills.isEmpty)
        XCTAssertTrue(try decode(TaskTreeResponse.self, #"{"task":{"id":"t1","status":"running"}}"#).children.isEmpty)
    }

    func testGatewayAndGraphEdgesHaveClientIdentity() throws {
        let gateway = try decode(GatewayStatus.self, #"{"name":"telegram","running":true,"stats":{}}"#)
        XCTAssertEqual(gateway.id, "telegram")
        XCTAssertTrue(gateway.running)
        let graph = try decode(MemoryGraphResponse.self, #"{"nodes":[{"id":"a","title":"A"}],"edges":[{"source":"a","target":"b","weight":1}]}"#)
        XCTAssertEqual(graph.edges.first?.source, "a")
        XCTAssertEqual(graph.edges.first?.id, "a→b")
    }

    func testMemoryStatsUsesRuntimeStatsEnvelope() throws {
        let stats = try decode(MemoryStats.self, #"{"stats":{"short":2,"medium":3,"long":4}}"#)
        XCTAssertEqual(stats.count, 9)
        XCTAssertEqual(stats.tiers?["medium"], 3)
        let flat = try decode(MemoryStats.self, #"{"short_term":2,"medium_term":3,"long_term":4,"total":9}"#)
        XCTAssertEqual(flat.tiers, stats.tiers)
        XCTAssertEqual(flat.count, 9)
    }

    func testTaskEventUsesTimeWithoutServerID() throws {
        let event = try decode(TaskEvent.self, #"{"type":"task.progress","task_id":"t1","time":"2026-10-17T00:00:00Z","message":"working"}"#)
        XCTAssertEqual(event.timestamp, "2026-10-17T00:00:00Z")
        XCTAssertFalse(event.id.isEmpty)
    }

    func testAutonomyOmitsDescriptionAndMayReturnNilWorkers() throws {
        let dashboard = try decode(AutonomyDashboardResponse.self, #"{"workers":null,"tasks":[{"id":"t1","title":"Inspect","priority":"normal","state":"ready"}],"queue":{"ready":1,"in_progress":0,"blocked":0,"done":0},"pool":{"worker_count":0}}"#)
        XCTAssertTrue(dashboard.workers.isEmpty)
        XCTAssertEqual(dashboard.tasks.first?.description, "")
        XCTAssertEqual(dashboard.queue?.ready, 1)
    }

    func testHTTPApprovalAndRuntimeApprovalUseTheirOwnFields() throws {
        let http = try decode(PendingApproval.self, #"{"id":"external-1","provider":"codex","summary":"Run command","reason":"Needs access","method":"command","options":[{"id":"accept_once","label":"Allow once"}]}"#)
        XCTAssertEqual(http.stableId, "external-1")
        XCTAssertEqual(http.title, "Run command")
        XCTAssertEqual(http.prompt, "Needs access")
        XCTAssertEqual(http.options.first?.id, "accept_once")
        XCTAssertFalse(http.secure)
        let runtime = try decode(PendingApproval.self, #"{"request_id":"runtime-1","provider":"runtime","summary":"Credential","reason":"Connect","prompt":"Enter key","kind":"credential","secure":true}"#)
        XCTAssertEqual(runtime.id, "runtime-1")
        XCTAssertEqual(runtime.prompt, "Enter key")
        XCTAssertEqual(runtime.kind, "credential")
        XCTAssertTrue(runtime.options.isEmpty)
        XCTAssertTrue(runtime.secure)
    }

    func testChatExplicitlyRequestsStreaming() throws {
        let outbound = ChatOutbound(id: "message-1", sessionId: "s1", data: ChatOutboundData(message: "hi"))
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(outbound))
        XCTAssertEqual(json.field("data")?.field("stream"), .bool(true))
    }

    func testWebSocketKeepsRunAndParentIdentity() throws {
        let event = try decode(WsEnvelope.self, #"{"type":"stream_end","session_id":"s1","parent_id":"message-1","run_id":"run-1","data":{}}"#)
        XCTAssertEqual(event.parentId, "message-1")
        XCTAssertEqual(event.runId, "run-1")
    }

    func testSettingsSurviveAddingNewPreferences() throws {
        let settings = try decode(AppSettings.self, #"{"apiBase":"http://host:9090","useBearer":false}"#)
        XCTAssertEqual(settings.apiBase, "http://host:9090")
        XCTAssertFalse(settings.useBearer)
        XCTAssertEqual(settings.chromeOpacity, 100)
        XCTAssertEqual(settings.appearance, "system")
    }

    func testLargeJSONNumberCanBeDisplayedWithoutIntegerOverflow() {
        XCTAssertFalse(JSONValue.number(1e100).pretty.isEmpty)
    }
}
