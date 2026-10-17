import XCTest
@testable import LuckyAgent

@MainActor
final class SocketClientTests: XCTestCase {
    func testSendWaitsForOpenAndUsesAuthenticationHeader() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        XCTAssertNil(client.sendChat(message: "too early", attachments: []))
        let connection = try XCTUnwrap(harness.connections.first)
        XCTAssertEqual(harness.requests.first?.value(forHTTPHeaderField: "X-API-Key"), "test-key")
        await restore(connection)
        XCTAssertNotNil(client.sendChat(message: "hello", attachments: []))
        let messages = try connection.messages()
        XCTAssertEqual(messages.map { $0["type"] as? String }, ["reconnect", "chat"])
        XCTAssertEqual(messages.last?["session_id"] as? String, "one")
        XCTAssertEqual(harness.states.last, .running)
        client.disconnect()
    }

    func testSessionSwitchIgnoresOldOpenCloseReceiveAndSendCallbacks() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let old = try XCTUnwrap(harness.connections.first)
        await restore(old)
        _ = client.sendChat(message: "first", attachments: [])
        client.connect(sessionId: "two")
        old.onOpen?()
        old.onClose?("old close")
        old.emit(#"{"type":"stream_chunk","session_id":"one","data":{"content":"stale"}}"#)
        old.sendCompletions.last?(URLError(.networkConnectionLost))
        await drainCallbacks()
        XCTAssertEqual(harness.connections.count, 2)
        XCTAssertEqual(harness.states.last, .connecting)
        XCTAssertFalse(harness.events.contains { $0.type == "stream_chunk" })
        XCTAssertTrue(harness.sendFailures.isEmpty)
        XCTAssertNil(client.sendChat(message: "too early", attachments: []))
        await restore(harness.connections[1], session: "two")
        XCTAssertNotNil(client.sendChat(message: "second", attachments: []))
        XCTAssertEqual(try harness.connections[1].messages().last?["session_id"] as? String, "two")
        client.disconnect()
    }

    func testReceiveAndCloseFailureScheduleOnlyOneReconnect() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let old = try XCTUnwrap(harness.connections.first)
        old.emitFailure()
        old.onClose?("closed 1000")
        await drainCallbacks()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(harness.connections.count, 2)
        XCTAssertEqual(old.closeCount, 1)
        client.disconnect()
    }

    func testDisconnectCancelsScheduledReconnect() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        harness.connections[0].onClose?("closed 1000")
        await drainCallbacks()
        client.disconnect()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(harness.connections.count, 1)
        XCTAssertEqual(harness.states.last, .closed)
    }

    func testExplicitConnectCancelsReconnectFromPreviousSession() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        harness.connections[0].emitFailure()
        await drainCallbacks()
        client.connect(sessionId: "two")
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(harness.connections.count, 2)
        XCTAssertEqual(harness.states.last, .connecting)
        client.disconnect()
    }

    func testSendFailureIsReportedEvenWhenReceiveFailedFirst() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let connection = harness.connections[0]
        await restore(connection)
        let requestId = try XCTUnwrap(client.sendChat(message: "hello", attachments: []))
        let completion = try XCTUnwrap(connection.sendCompletions.last)
        connection.emitFailure()
        await drainCallbacks()
        completion(URLError(.networkConnectionLost))
        await drainCallbacks()
        XCTAssertEqual(harness.sendFailures.map(\.0), [requestId])
        XCTAssertTrue(harness.sendFailures[0].1.contains("发送失败"))
        XCTAssertTrue(harness.callbacksOnMainThread)
        XCTAssertEqual(harness.states.last, .reconnecting)
        XCTAssertNil(client.sendChat(message: "offline", attachments: []))
        client.disconnect()
    }

    func testReconnectSendsCursorAndDeduplicatesReplay() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let first = harness.connections[0]
        await restore(first)
        first.emit(#"{"type":"stream_chunk","event_id":"e1","run_id":"run-1","session_id":"one","data":{"content":"A"}}"#)
        await drainCallbacks()
        first.emitFailure()
        await drainCallbacks()
        try await Task.sleep(nanoseconds: 40_000_000)
        let second = try XCTUnwrap(harness.connections.last)
        XCTAssertFalse(first === second)
        await restore(second)
        let handshake = try XCTUnwrap(second.messages().first)
        XCTAssertEqual((handshake["data"] as? [String: Any])?["last_message_id"] as? String, "e1")
        second.emit(#"{"type":"stream_chunk","event_id":"e1","run_id":"run-1","session_id":"one","data":{"content":"A"}}"#)
        await drainCallbacks()
        second.emit(#"{"type":"stream_chunk","event_id":"e2","session_id":"other","data":{"content":"wrong session"}}"#)
        await drainCallbacks()
        second.emit(#"{"type":"stream_chunk","event_id":"e2","run_id":"run-1","session_id":"one","data":{"content":"B"}}"#)
        await drainCallbacks()
        XCTAssertEqual(harness.events.compactMap(\.eventId), ["e1", "e2"])
        client.connect(sessionId: "two")
        await restore(harness.connections.last!, session: "two")
        let fresh = try XCTUnwrap(harness.connections.last?.messages().first)
        XCTAssertEqual((fresh["data"] as? [String: Any])?["last_message_id"] as? String, "")
        client.disconnect()
    }

    func testStatusMessagesDoNotTurnConnectionAndApprovalUpdatesIntoRuns() async {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let connection = harness.connections[0]
        await restore(connection)
        for state in ["connected", "approval_resolved", "lucky"] {
            connection.emit(status(state))
            await drainCallbacks()
            XCTAssertEqual(harness.states.last, .connected)
        }
        connection.emit(status("thinking"))
        await drainCallbacks()
        XCTAssertEqual(harness.states.last, .running)
        connection.emit(status("connected"))
        await drainCallbacks()
        XCTAssertEqual(harness.states.last, .running)
        connection.emit(status("idle"))
        await drainCallbacks()
        XCTAssertEqual(harness.states.last, .connected)
        connection.emit(status("error"))
        await drainCallbacks()
        XCTAssertEqual(harness.states.last, .error)
        XCTAssertEqual(harness.notes.last!, "status detail")
        client.disconnect()
    }

    func testTerminalEventDoesNotOverwriteNextTurnRunningState() async {
        let harness = SocketHarness()
        var client: SocketClient!
        client = harness.makeClient(onEvent: { event in
            if event.type == "stream_end" { _ = client.sendChat(message: "next", attachments: []) }
        })
        client.connect(sessionId: "one")
        let connection = harness.connections[0]
        await restore(connection)
        _ = client.sendChat(message: "first", attachments: [])
        connection.emit(#"{"type":"stream_end","session_id":"one","data":{"full_response":"done"}}"#)
        await drainCallbacks()
        XCTAssertEqual(harness.states.last, .running)
        client.disconnect()
    }

    func testReentrantDisconnectDoesNotDeliverAnEventAfterClose() async {
        let harness = SocketHarness()
        var client: SocketClient!
        client = harness.makeClient(onState: { state in
            if state == .running { client.disconnect() }
        })
        client.connect(sessionId: "one")
        await restore(harness.connections[0])
        harness.connections[0].emit(#"{"type":"stream_chunk","session_id":"one","data":{"content":"stop"}}"#)
        await drainCallbacks()
        XCTAssertFalse(harness.events.contains { $0.type == "stream_chunk" })
        XCTAssertEqual(harness.states.last, .closed)
    }

    func testRestoredActiveRunKeepsComposerBlockedUntilTerminalEvent() async {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let connection = harness.connections[0]
        connection.onOpen?()
        await drainCallbacks()
        XCTAssertFalse(client.canSendChat)
        connection.emit(status("running"))
        await drainCallbacks()
        connection.emit(status("connected"))
        await drainCallbacks()
        XCTAssertFalse(client.canSendChat)
        XCTAssertEqual(harness.states.last, .running)
        connection.emit(#"{"type":"stream_end","session_id":"one","data":{"full_response":"done"}}"#)
        await drainCallbacks()
        XCTAssertTrue(client.canSendChat)
        XCTAssertEqual(harness.states.last, .connected)
        client.disconnect()
    }

    func testTransientMessageIdsDoNotAdvanceReplayCursor() async throws {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let first = harness.connections[0]
        await restore(first)
        first.emit(#"{"type":"stream_chunk","event_id":"durable-1","run_id":"run-1","session_id":"one","data":{"content":"A"}}"#)
        await drainCallbacks()
        let transient = [
            #"{"type":"pong","event_id":"pong-1","session_id":"one","data":null}"#,
            #"{"type":"status","event_id":"approval-1","session_id":"one","data":{"state":"approval_resolved"}}"#,
            #"{"type":"error","event_id":"error-1","session_id":"one","data":{"code":"APPROVAL_FAILED","message":"retry"}}"#,
            #"{"type":"status","event_id":"connected-1","session_id":"one","data":{"state":"connected"}}"#,
        ]
        for message in transient {
            first.emit(message)
            await drainCallbacks()
        }
        first.emitFailure()
        await drainCallbacks()
        try await Task.sleep(nanoseconds: 40_000_000)
        let second = try XCTUnwrap(harness.connections.last)
        await restore(second)
        let handshake = try XCTUnwrap(second.messages().first)
        XCTAssertEqual((handshake["data"] as? [String: Any])?["last_message_id"] as? String, "durable-1")
        client.disconnect()
    }

    func testApprovalFailureKeepsTheWaitingRunActive() async {
        let harness = SocketHarness()
        let client = harness.makeClient()
        client.connect(sessionId: "one")
        let connection = harness.connections[0]
        await restore(connection)
        connection.emit(#"{"type":"approval","session_id":"one","data":{"request_id":"approval-1"}}"#)
        await drainCallbacks()
        connection.emit(#"{"type":"error","session_id":"one","data":{"code":"APPROVAL_FAILED","message":"approval is still pending"}}"#)
        await drainCallbacks()
        XCTAssertEqual(harness.states.last, .running)
        XCTAssertEqual(harness.notes.last!, "approval is still pending")
        XCTAssertFalse(client.canSendChat)
        XCTAssertTrue(client.sendApproval(requestId: "approval-1", provider: "runtime", decision: "allow", input: ""))
        client.disconnect()
    }

    private func restore(_ connection: FakeSocketConnection, session: String = "one") async {
        connection.onOpen?()
        await drainCallbacks()
        connection.emit(#"{"type":"status","session_id":"\#(session)","data":{"state":"connected"}}"#)
        await drainCallbacks()
    }

    private func status(_ state: String) -> String {
        #"{"type":"status","session_id":"one","data":{"state":"\#(state)","message":"status detail"}}"#
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class SocketHarness {
    var requests: [URLRequest] = []
    var connections: [FakeSocketConnection] = []
    var states: [SocketState] = []
    var notes: [String?] = []
    var events: [WsEnvelope] = []
    var sendFailures: [(String, String)] = []
    var callbacksOnMainThread = true

    func makeClient(onEvent: ((WsEnvelope) -> Void)? = nil, onState: ((SocketState) -> Void)? = nil) -> SocketClient {
        var settings = AppSettings()
        settings.apiBase = "http://localhost:9090"
        settings.apiKey = "test-key"
        settings.useBearer = false
        return SocketClient(api: APIClient(settings: settings), onEvent: { event in
            self.callbacksOnMainThread = self.callbacksOnMainThread && Thread.isMainThread
            self.events.append(event)
            onEvent?(event)
        }, onState: { state, note in
            self.callbacksOnMainThread = self.callbacksOnMainThread && Thread.isMainThread
            self.states.append(state)
            self.notes.append(note)
            onState?(state)
        }, onSendFailure: { requestId, reason in
            self.callbacksOnMainThread = self.callbacksOnMainThread && Thread.isMainThread
            self.sendFailures.append((requestId, reason))
        }, connectionFactory: { request in
            let connection = FakeSocketConnection()
            self.requests.append(request)
            self.connections.append(connection)
            return connection
        }, reconnectDelay: { _ in 0.01 })
    }
}

private final class FakeSocketConnection: SocketConnection {
    var onOpen: (() -> Void)?
    var onClose: ((String) -> Void)?
    var sent: [URLSessionWebSocketTask.Message] = []
    var sendCompletions: [(Error?) -> Void] = []
    var receiveCompletion: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    var closeCount = 0

    func resume() {}
    func close() { closeCount += 1 }
    func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveCompletion = completion
    }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        sent.append(message)
        sendCompletions.append(completion)
    }
    func emit(_ text: String) { receiveCompletion?(.success(.string(text))) }
    func emitFailure() { receiveCompletion?(.failure(URLError(.networkConnectionLost))) }
    func messages() throws -> [[String: Any]] {
        try sent.compactMap { message in
            guard case .string(let text) = message else { return nil }
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
    }
}
