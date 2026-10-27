import Foundation

/// All connection state and consumer callbacks belong to the main actor.
@MainActor
final class SocketClient {
    private let api: APIClient
    private let onEvent: (WsEnvelope) -> Void
    private let onState: (SocketState, String?) -> Void
    private let onSendFailure: ((String, String) -> Void)?
    private let connectionFactory: (URLRequest) -> SocketConnection
    private let reconnectDelay: (Int) -> Double
    private var connection: SocketConnection?
    private var reconnectTask: Task<Void, Never>?
    private var sessionId = ""
    private var generation = UUID()
    private var attempt = 0
    private var userClosed = true
    private var isOpen = false
    private var handshakeComplete = false
    private var isRunning = false
    private var lastEventId = ""
    private var seenEventIds: Set<String> = []
    private var eventOrder: [String] = []

    var canSendChat: Bool { isOpen && handshakeComplete && !isRunning }

    init(
        api: APIClient,
        onEvent: @escaping (WsEnvelope) -> Void,
        onState: @escaping (SocketState, String?) -> Void,
        onSendFailure: ((String, String) -> Void)? = nil,
        connectionFactory: @escaping (URLRequest) -> SocketConnection = { URLSessionSocketConnection(request: $0) },
        reconnectDelay: @escaping (Int) -> Double = { min(0.4 * Double($0), 8) }
    ) {
        self.api = api
        self.onEvent = onEvent
        self.onState = onState
        self.onSendFailure = onSendFailure
        self.connectionFactory = connectionFactory
        self.reconnectDelay = reconnectDelay
    }

    deinit {
        reconnectTask?.cancel()
        connection?.close()
    }

    func connect(sessionId: String) {
        generation = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        closeConnection()
        if self.sessionId != sessionId {
            lastEventId = ""
            seenEventIds.removeAll()
            eventOrder.removeAll()
        }
        self.sessionId = sessionId
        userClosed = false
        attempt = 0
        open(isReconnect: false)
    }

    func disconnect() {
        userClosed = true
        generation = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        closeConnection()
        onState(.closed, nil)
    }

    func sendChat(message: String, attachments: [MediaAttachment]) -> String? {
        guard canSendChat else { return nil }
        let id = UUID().uuidString
        let outbound = ChatOutbound(id: id, sessionId: sessionId, data: ChatOutboundData(message: message, attachments: attachments))
        guard send(outbound, requestId: id) else { return nil }
        isRunning = true
        onState(.running, nil)
        return id
    }

    @discardableResult
    func cancel() -> Bool {
        send(CancelOutbound(sessionId: sessionId, data: CancelOutboundData(sessionId: sessionId)))
    }

    @discardableResult
    func sendApproval(requestId: String, provider: String, decision: String, input: String) -> Bool {
        send(ApprovalResponseOutbound(
            id: UUID().uuidString,
            sessionId: sessionId,
            data: ApprovalResponseData(requestId: requestId, provider: provider.isEmpty ? "runtime" : provider, decision: decision, input: input)
        ), requestId: requestId)
    }

    @discardableResult
    func sendLucky(action: String) -> Bool {
        send(LuckyOutbound(id: UUID().uuidString, sessionId: sessionId, data: LuckyOutboundData(action: action)))
    }

    private func open(isReconnect: Bool) {
        guard !userClosed else { return }
        guard let url = api.webSocketURL(sessionId: sessionId), ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            onState(.error, "WebSocket 地址无效")
            return
        }
        var request = URLRequest(url: url)
        let key = api.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue(api.settings.useBearer ? "Bearer \(key)" : key, forHTTPHeaderField: api.settings.useBearer ? "Authorization" : "X-API-Key")
        }
        let current = connectionFactory(request)
        let token = generation
        connection = current
        current.onOpen = { [weak self, weak current] in
            DispatchQueue.main.async {
                guard let self, let current, self.isCurrent(current, token: token) else { return }
                self.attempt = 0
                self.isOpen = true
                // Durable output is replayed only after the runtime receives this handshake.
                _ = self.send(ReconnectOutbound(sessionId: self.sessionId, data: ReconnectData(lastMessageId: self.lastEventId)))
            }
        }
        current.onClose = { [weak self, weak current] reason in
            DispatchQueue.main.async {
                guard let self, let current, self.isCurrent(current, token: token) else { return }
                self.fail(reason)
            }
        }
        onState(isReconnect ? .reconnecting : .connecting, nil)
        current.resume()
        receive(current, token: token)
    }

    private func isCurrent(_ candidate: SocketConnection, token: UUID) -> Bool {
        !userClosed && generation == token && connection === candidate
    }

    private func closeConnection() {
        let old = connection
        connection = nil
        isOpen = false
        handshakeComplete = false
        isRunning = false
        old?.close()
    }

    private func receive(_ current: SocketConnection, token: UUID) {
        current.receive { [weak self, weak current] result in
            DispatchQueue.main.async {
                guard let self, let current, self.isCurrent(current, token: token) else { return }
                switch result {
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = Data()
                    }
                    if let envelope = try? JSONDecoder().decode(WsEnvelope.self, from: data) {
                        self.accept(envelope, from: current, token: token)
                    }
                    if self.isCurrent(current, token: token) { self.receive(current, token: token) }
                case .failure(let error):
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    private func accept(_ envelope: WsEnvelope, from current: SocketConnection, token: UUID) {
        let boundSession = sessionId.isEmpty ? "default" : sessionId
        guard envelope.sessionId?.isEmpty != false || envelope.sessionId == boundSession else { return }
        if let id = envelope.eventId ?? envelope.id, !id.isEmpty {
            guard seenEventIds.insert(id).inserted else { return }
            // Pong and approval replies also carry IDs, but only run events
            // are persisted by the runtime and can be used as replay cursors.
            if envelope.runId?.isEmpty == false { lastEventId = id }
            eventOrder.append(id)
            if eventOrder.count > 2048 { seenEventIds.remove(eventOrder.removeFirst()) }
        }
        // A terminal event may synchronously dispatch the next turn from the consumer.
        note(envelope)
        if isCurrent(current, token: token) { onEvent(envelope) }
    }

    private func note(_ envelope: WsEnvelope) {
        switch envelope.type {
        case "stream_chunk", "assistant_delta", "delta", "chunk", "tool_call", "tool_result", "tool", "running", "reasoning", "approval":
            isRunning = true
            onState(.running, nil)
        case "status":
            switch envelope.data?.field("state")?.string {
            case "idle":
                isRunning = false
                if handshakeComplete { onState(.connected, nil) }
            case "connected":
                handshakeComplete = true
                onState(isRunning ? .running : .connected, nil)
            case "error":
                isRunning = false
                onState(.error, envelope.data?.field("message")?.string)
            case "thinking", "executing", "running", "queued":
                isRunning = true
                onState(.running, nil)
            default:
                break
            }
        case "stream_end", "final", "done", "chat_done", "assistant_message", "cancel", "cancelled":
            isRunning = false
            if handshakeComplete { onState(.connected, nil) }
        case "error":
            let message = envelope.error ?? envelope.data?.field("message")?.string
            if envelope.data?.field("code")?.string == "APPROVAL_FAILED" {
                isRunning = true
                onState(.running, message)
            } else {
                isRunning = false
                onState(.error, message)
            }
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        guard !userClosed, connection != nil else { return }
        closeConnection()
        attempt += 1
        let delay = max(0, reconnectDelay(attempt))
        let token = generation
        onState(.reconnecting, "\(reason)；第 \(attempt) 次重连，\(String(format: "%.1f", delay))s")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled, !self.userClosed, self.generation == token else { return }
            self.reconnectTask = nil
            self.open(isReconnect: true)
        }
    }

    @discardableResult
    private func send<T: Encodable>(_ value: T, requestId: String? = nil) -> Bool {
        guard isOpen, let current = connection else { return false }
        let text: String
        do { text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        catch {
            onState(.error, "消息编码失败：\(error.localizedDescription)")
            return false
        }
        let token = generation
        current.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, !self.userClosed, self.generation == token else { return }
                let reason = "发送失败：\(error.localizedDescription)"
                if self.connection === current { self.fail(reason) }
                if let requestId { self.onSendFailure?(requestId, reason) }
            }
        }
        return true
    }
}

/// A small transport boundary for deterministic connection lifecycle tests.
protocol SocketConnection: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    func resume()
    func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void)
    func close()
}

private final class URLSessionSocketConnection: NSObject, SocketConnection, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((String) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(request: URLRequest) {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.webSocketTask(with: request)
    }

    func resume() { task?.resume() }
    func receive(completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task?.receive(completionHandler: completion)
    }
    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        task?.send(message, completionHandler: completion)
    }
    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(String(data: reason ?? Data(), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "连接已关闭（\(closeCode.rawValue)）")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onClose?(error.localizedDescription) }
    }
}

private struct ReconnectOutbound: Encodable {
    var type = "reconnect"
    var sessionId: String
    var data: ReconnectData
    enum CodingKeys: String, CodingKey { case type, data; case sessionId = "session_id" }
}

private struct ReconnectData: Encodable {
    var lastMessageId: String
    enum CodingKeys: String, CodingKey { case lastMessageId = "last_message_id" }
}
