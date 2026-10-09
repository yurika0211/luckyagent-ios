import Foundation

/// One WebSocket to `/api/v1/ws`. Reconnects with the same backoff the Android client uses.
final class SocketClient: NSObject, URLSessionWebSocketDelegate {
    private let api: APIClient
    private let onEvent: (WsEnvelope) -> Void
    private let onState: (SocketState, String?) -> Void

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var sessionId: String = ""
    private var attempt = 0
    private var userClosed = false
    private var receiveLoop = false

    private let baseDelay: Double = 0.4
    private let maxDelay: Double = 8

    init(api: APIClient, onEvent: @escaping (WsEnvelope) -> Void, onState: @escaping (SocketState, String?) -> Void) {
        self.api = api
        self.onEvent = onEvent
        self.onState = onState
        super.init()
    }

    func connect(sessionId: String) {
        self.sessionId = sessionId
        userClosed = false
        attempt = 0
        open(isReconnect: false)
    }

    func disconnect() {
        userClosed = true
        receiveLoop = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onState(.closed, nil)
    }

    func sendChat(message: String, attachments: [MediaAttachment]) -> String? {
        guard task != nil else { return nil }
        let id = UUID().uuidString
        let outbound = ChatOutbound(
            id: id,
            sessionId: sessionId,
            data: ChatOutboundData(message: message, attachments: attachments)
        )
        send(outbound)
        onState(.running, nil)
        return id
    }

    func cancel() {
        send(CancelOutbound(sessionId: sessionId, data: CancelOutboundData(sessionId: sessionId)))
    }

    func sendApproval(requestId: String, provider: String, decision: String, input: String) {
        send(ApprovalResponseOutbound(
            id: UUID().uuidString,
            sessionId: sessionId,
            data: ApprovalResponseData(requestId: requestId, provider: provider.isEmpty ? "runtime" : provider, decision: decision, input: input)
        ))
    }

    func sendLucky(action: String) {
        send(LuckyOutbound(id: UUID().uuidString, sessionId: sessionId, data: LuckyOutboundData(action: action)))
    }

    private func open(isReconnect: Bool) {
        guard !userClosed, let url = api.webSocketURL(sessionId: sessionId) else {
            onState(.error, "WebSocket 地址无效")
            return
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        let key = api.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty, api.settings.useBearer {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        onState(isReconnect ? .reconnecting : .connecting, nil)
        task.resume()
        receiveLoop = true
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, self.receiveLoop else { return }
            switch result {
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                if let data = text.data(using: .utf8),
                   let env = try? JSONDecoder().decode(WsEnvelope.self, from: data) {
                    DispatchQueue.main.async { self.onEvent(env) }
                    self.note(env)
                }
                self.receive()
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func note(_ env: WsEnvelope) {
        let state: SocketState
        switch env.type {
        case "stream_chunk", "assistant_delta", "delta", "chunk", "tool_call", "tool", "running", "status", "reasoning", "approval":
            let hint = env.data?.field("state")?.string
            state = hint == "idle" ? .connected : .running
        case "stream_end", "final", "done", "chat_done", "assistant_message", "cancel", "cancelled":
            state = .connected
        case "error":
            state = .error
        default:
            return
        }
        DispatchQueue.main.async { self.onState(state, env.error) }
    }

    private func fail(_ reason: String) {
        guard !userClosed else { return }
        attempt += 1
        let delay = min(baseDelay * Double(attempt), maxDelay)
        DispatchQueue.main.async {
            self.onState(.reconnecting, "第 \(self.attempt) 次重连，\(String(format: "%.1f", delay))s")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.userClosed else { return }
            self.open(isReconnect: true)
        }
    }

    private func send<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        attempt = 0
        DispatchQueue.main.async { self.onState(.connected, nil) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard !userClosed, closeCode != .normalClosure else { return }
        fail("closed \(closeCode.rawValue)")
    }
}
