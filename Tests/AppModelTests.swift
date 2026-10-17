import Foundation
import XCTest
@testable import LuckyAgent

@MainActor
final class AppModelTests: XCTestCase {
    func testFinalResponseReconcilesStreamAndFinishesReasoning() throws {
        let model = makeModel()
        model.handle(event("stream_chunk", data: ["content": .string("partial")]))
        model.handle(event("reasoning", data: ["summary": .string("thinking")]))
        model.handle(event("stream_end", data: ["full_response": .string("complete response")]))
        XCTAssertEqual(model.lines.filter { $0.kind == .assistant }.map(\.text), ["complete response"])
        XCTAssertEqual(model.lines.first { $0.kind == .reasoning }?.text, "thinking")
        XCTAssertFalse(model.lines.contains { $0.streaming })
    }

    func testNonStreamingFinalAndAttachmentOnlyMessagesAreVisible() {
        let model = makeModel()
        model.handle(event("stream_end", data: ["full_response": .string("final")]))
        model.handle(event("stream_end", data: ["attachments": .array([
            .object(["type": .string("image"), "file_url": .string("/api/v1/artifacts?path=a.png"), "file_name": .string("a.png")])
        ])]))
        XCTAssertEqual(model.lines.count, 2)
        XCTAssertEqual(model.lines.last?.attachments.first?.fileName, "a.png")
    }

    func testDifferentSessionEventsCannotChangeChat() {
        let model = makeModel()
        model.handle(WsEnvelope(type: "stream_chunk", sessionId: "other", data: .object(["content": .string("wrong session")])))
        XCTAssertTrue(model.lines.isEmpty)
    }

    func testQueueWaitsForTurnAndIgnoresOldTerminalEvents() throws {
        let (model, socket) = connectedModel()
        model.draft = "one"; model.send()
        model.draft = "two"; model.send()
        XCTAssertEqual(socket.messages, ["one"])
        XCTAssertEqual(model.outbound.items.map(\.status), [.sending, .queued])
        socket.canSendChat = true
        model.handle(event("stream_end", parent: "request-1", data: ["full_response": .string("first answer")]))
        XCTAssertEqual(socket.messages, ["one", "two"])
        XCTAssertEqual(model.outbound.items.first?.requestId, "request-2")
        model.handle(event("status", parent: "request-1", data: ["state": .string("idle")]))
        XCTAssertEqual(model.outbound.items.first?.requestId, "request-2")
        XCTAssertEqual(model.lines.filter { $0.kind == .assistant }.count, 1)
    }

    func testErrorKeepsFailedItemAndLetsNextTurnProceed() {
        let (model, socket) = connectedModel()
        model.draft = "one"; model.send()
        model.draft = "two"; model.send()
        socket.canSendChat = true
        model.handle(event("error", parent: "request-1", data: ["code": .string("CHAT_FAILED"), "message": .string("model unavailable")]))
        XCTAssertEqual(model.outbound.items.map(\.status), [.failed, .sending])
        XCTAssertEqual(model.outbound.items.first?.error, "model unavailable")
        XCTAssertEqual(socket.messages, ["one", "two"])
    }

    func testReconnectWithoutAcknowledgementMakesDeliveryUncertaintyVisible() {
        let (model, socket) = connectedModel()
        model.draft = "one"; model.send()
        socket.canSendChat = true
        model.handle(event("status", data: ["state": .string("connected")]))
        XCTAssertEqual(model.outbound.items.first?.status, .failed)
        XCTAssertTrue(model.outbound.items.first?.error?.contains("送达状态无法确认") == true)
        XCTAssertEqual(socket.messages, ["one"])
        XCTAssertEqual(model.socketState, .connected)
    }

    func testDurableCompletionConfirmsAnUncertainTransportSend() throws {
        let (model, socket) = connectedModel()
        model.draft = "one"; model.send()
        let item = try XCTUnwrap(model.outbound.items.first)
        model.outbound.markFailed(id: item.id, error: "transport disconnected")
        socket.canSendChat = true
        model.handle(event("stream_end", parent: "request-1", data: ["full_response": .string("delivered answer")]))
        XCTAssertTrue(model.outbound.items.isEmpty)
        XCTAssertEqual(socket.messages, ["one"])
        XCTAssertEqual(model.lines.last?.text, "delivered answer")
    }

    func testStopRequiresRuntimeAcknowledgementBeforeNextSend() {
        let (model, socket) = connectedModel()
        model.draft = "one"; model.send()
        model.draft = "two"; model.send()
        model.stop()
        XCTAssertTrue(model.isStopping)
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertTrue(model.outbound.items.isEmpty)
        model.draft = "three"; model.send()
        XCTAssertEqual(socket.messages, ["one"])
        socket.canSendChat = true
        model.handle(event("status", parent: "request-1", data: ["state": .string("idle"), "message": .string("cancelled")]))
        XCTAssertFalse(model.isStopping)
        model.send()
        XCTAssertEqual(socket.messages, ["one", "three"])
    }

    func testToolProgressUpdatesSameStepAndFailureIsPreserved() {
        let model = makeModel()
        model.handle(event("tool_call", data: ["name": .string("shell"), "step_id": .string("step-1"), "args": .string("ls")]))
        model.handle(event("tool_call", data: ["name": .string("shell"), "step_id": .string("step-1"), "display": .string("working")]))
        model.handle(event("tool_result", data: ["name": .string("shell"), "step_id": .string("step-1"), "output": .string("denied"), "success": .bool(false)]))
        XCTAssertEqual(model.lines.count, 1)
        XCTAssertEqual(model.lines.first?.toolState, "failed")
        XCTAssertEqual(model.lines.first?.text, "denied")
    }

    func testApprovalStaysUntilAcknowledgedAndCanRetryAfterFailure() throws {
        let (model, _) = connectedModel()
        let approvalEvent = event("approval", data: ["request_id": .string("approval-1"), "summary": .string("Run command"), "reason": .string("Permission required")])
        model.handle(approvalEvent); model.handle(approvalEvent)
        let approval = try XCTUnwrap(model.approvals.first)
        XCTAssertEqual(model.approvals.count, 1)
        model.resolve(approval: approval, decision: "allow", input: "")
        XCTAssertEqual(model.approvals.count, 1)
        model.handle(event("error", data: ["code": .string("APPROVAL_FAILED"), "message": .string("try again")]))
        XCTAssertNil(model.resolvingApprovalId)
        XCTAssertEqual(model.socketState, .running)
        model.resolve(approval: approval, decision: "allow", input: "")
        model.handle(event("status", data: ["state": .string("approval_resolved")]))
        XCTAssertTrue(model.approvals.isEmpty)
        XCTAssertNil(model.resolvingApprovalId)
    }

    private func event(_ type: String, parent: String? = nil, data: [String: JSONValue]) -> WsEnvelope {
        WsEnvelope(type: type, sessionId: "session-1", parentId: parent, data: .object(data))
    }

    private func makeModel() -> AppModel {
        let suite = "LuckyAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(try! JSONEncoder().encode(AppSettings(sessionId: "session-1")), forKey: "luckyagent.settings")
        let store = SettingsStore(defaults: defaults, keychainService: suite)
        defaults.removePersistentDomain(forName: suite)
        return AppModel(store: store)
    }

    private func connectedModel() -> (AppModel, ModelTestSocket) {
        let model = makeModel()
        let socket = ModelTestSocket()
        socket.onSend = { [weak model] in model?.socketState = .running }
        model.socket = socket
        model.socketState = .connected
        return (model, socket)
    }
}

@MainActor
private final class ModelTestSocket: ChatSocket {
    var canSendChat = true
    var messages: [String] = []
    var cancelCount = 0
    var onSend: (() -> Void)?
    func disconnect() {}
    func sendChat(message: String, attachments: [MediaAttachment]) -> String? {
        guard canSendChat else { return nil }
        messages.append(message)
        canSendChat = false
        onSend?()
        return "request-\(messages.count)"
    }
    func cancel() -> Bool { cancelCount += 1; return true }
    func sendApproval(requestId: String, provider: String, decision: String, input: String) -> Bool { true }
}
