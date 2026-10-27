import Foundation
import XCTest
@testable import LuckyAgent

private final class CompactionFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: PausedCompactionFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture?.receive(self) }
    override func stopLoading() {}

    func reply(_ json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PausedCompactionFixture: @unchecked Sendable {
    let compactStarted: XCTestExpectation
    let historyStarted: XCTestExpectation
    private let lock = NSLock()
    private var compactRequest: CompactionFixtureProtocol?
    private var historyRequest: CompactionFixtureProtocol?

    init(compactStarted: XCTestExpectation, historyStarted: XCTestExpectation) {
        self.compactStarted = compactStarted
        self.historyStarted = historyStarted
    }

    func receive(_ request: CompactionFixtureProtocol) {
        if request.request.httpMethod == "POST", request.request.url?.path == "/api/v1/sessions/session-1/compact" {
            lock.lock(); compactRequest = request; lock.unlock()
            compactStarted.fulfill()
        } else if request.request.httpMethod == "GET", request.request.url?.path == "/api/v1/sessions/session-1" {
            lock.lock(); historyRequest = request; lock.unlock()
            historyStarted.fulfill()
        } else {
            XCTFail("Unexpected request during compaction: \(request.request.httpMethod ?? "") \(request.request.url?.path ?? "")")
            request.reply("{}")
        }
    }

    func finishCompaction() {
        lock.lock(); let request = compactRequest; compactRequest = nil; lock.unlock()
        request?.reply(#"{"summary":"compacted"}"#)
    }

    func finishHistoryReload() {
        lock.lock(); let request = historyRequest; historyRequest = nil; lock.unlock()
        request?.reply(#"{"id":"session-1","messages":[],"message_count":0,"returned":0,"has_more":false}"#)
    }
}

@MainActor
private final class CompactionTestSocket: ChatSocket {
    var canSendChat = true
    var sent: [String] = []
    func disconnect() {}
    func sendChat(message: String, attachments: [MediaAttachment]) -> String? {
        guard canSendChat else { return nil }
        canSendChat = false
        sent.append(message)
        return "request-\(sent.count)"
    }
    func cancel() -> Bool { true }
    func sendApproval(requestId: String, provider: String, decision: String, input: String) -> Bool { true }
}

@MainActor
final class AppModelCompactionTests: XCTestCase {
    private var session: URLSession?
    private var model: AppModel?
    private var defaults: UserDefaults?
    private var suite: String?

    override func tearDown() {
        model?.suspendConnection()
        session?.invalidateAndCancel()
        CompactionFixtureProtocol.fixture = nil
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeModel() -> (AppModel, CompactionTestSocket, PausedCompactionFixture) {
        let suite = "LuckyAgentCompactionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.suite = suite
        self.defaults = defaults
        let settings = AppSettings(apiBase: "http://compaction.runtime.test", sessionId: "session-1")
        defaults.set(try! JSONEncoder().encode(settings), forKey: "luckyagent.settings")
        let store = SettingsStore(defaults: defaults, keychainService: suite)
        let fixture = PausedCompactionFixture(
            compactStarted: expectation(description: "compact request is pending"),
            historyStarted: expectation(description: "history reload is pending")
        )
        CompactionFixtureProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompactionFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let model = AppModel(store: store, api: APIClient(settings: store.settings, session: session))
        let socket = CompactionTestSocket()
        model.socket = socket
        model.socketState = .connected
        self.model = model
        self.session = session
        return (model, socket, fixture)
    }

    func testSendWaitsForCompactionAndFollowingHistoryReload() async {
        let (model, socket, fixture) = makeModel()
        let compacting = Task { await model.compactSession() }
        await fulfillment(of: [fixture.compactStarted], timeout: 2)
        XCTAssertTrue(model.isCompacting)
        model.draft = "question after compaction"
        model.send()
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertTrue(model.outbound.items.isEmpty)
        XCTAssertEqual(model.draft, "question after compaction")

        fixture.finishCompaction()
        await fulfillment(of: [fixture.historyStarted], timeout: 2)
        XCTAssertTrue(model.isCompacting)
        model.send()
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertTrue(model.outbound.items.isEmpty)

        fixture.finishHistoryReload()
        await compacting.value
        XCTAssertFalse(model.isCompacting)
        model.send()
        XCTAssertEqual(socket.sent, ["question after compaction"])
        XCTAssertEqual(model.outbound.items.map(\.status), [.sending])
        XCTAssertTrue(model.draft.isEmpty)
    }

    func testRetryStaysQueuedUntilCompactionAndHistoryReloadFinish() async {
        let (model, socket, fixture) = makeModel()
        model.outbound.enqueue(OutboundItem(id: "failed-item", sessionId: "session-1", preview: "retry me", message: "retry me", attachments: [], requestId: "previous-request", status: .failed, error: "transport failed"))
        let compacting = Task { await model.compactSession() }
        await fulfillment(of: [fixture.compactStarted], timeout: 2)
        model.retryOutbound("failed-item")
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(model.outbound.items.map(\.status), [.queued])

        fixture.finishCompaction()
        await fulfillment(of: [fixture.historyStarted], timeout: 2)
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertEqual(model.outbound.items.map(\.status), [.queued])

        fixture.finishHistoryReload()
        await compacting.value
        XCTAssertFalse(model.isCompacting)
        XCTAssertEqual(socket.sent, ["retry me"])
        XCTAssertEqual(model.outbound.items.map(\.status), [.sending])
    }
}
