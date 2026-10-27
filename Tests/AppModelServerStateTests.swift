import Foundation
import XCTest
@testable import LuckyAgent

/// Hold one request across a settings change, while allowing the replacement
/// server's bootstrap to finish without opening a real WebSocket.
private final class PausedStateProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: PausedStateFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture?.receive(self) }
    override func stopLoading() {}

    func reply(status: Int = 200, json: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PausedStateFixture: @unchecked Sendable {
    let started: XCTestExpectation
    let bootstrapFinished: XCTestExpectation
    let path: String
    let method: String
    private let lock = NSLock()
    private var held: PausedStateProtocol?
    private var didHold = false

    init(path: String, method: String, started: XCTestExpectation, bootstrapFinished: XCTestExpectation) {
        self.path = path
        self.method = method
        self.started = started
        self.bootstrapFinished = bootstrapFinished
    }

    func receive(_ request: PausedStateProtocol) {
        lock.lock()
        let shouldHold = !didHold && request.request.url?.host == "old.runtime.test" && request.request.url?.path == path && request.request.httpMethod == method
        if shouldHold { held = request; didHold = true }
        lock.unlock()
        if shouldHold { started.fulfill(); return }
        switch (request.request.httpMethod, request.request.url?.path) {
        case ("GET", "/api/v1/sessions"): request.reply(json: #"{"sessions":[]}"#)
        case ("GET", "/api/v1/soul"):
            request.reply(json: #"{"name":"New runtime"}"#)
            bootstrapFinished.fulfill()
        // Stop the automatic bootstrap before it could create a real socket.
        default: request.reply(status: 503, json: #"{"error":"fixture unavailable"}"#)
        }
    }

    func release(status: Int = 200, json: String) {
        lock.lock()
        let request = held
        held = nil
        lock.unlock()
        request?.reply(status: status, json: json)
    }
}

@MainActor
final class AppModelServerStateTests: XCTestCase {
    private var session: URLSession!
    private var suite: String!
    private var model: AppModel?

    override func tearDown() {
        model?.suspendConnection()
        session?.invalidateAndCancel()
        PausedStateProtocol.fixture = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeModel() -> AppModel {
        suite = "LuckyAgentServerStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, keychainService: suite)
        store.update { $0.apiBase = "http://old.runtime.test"; $0.sessionId = ""; $0.apiKey = "" }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PausedStateProtocol.self]
        session = URLSession(configuration: config)
        let model = AppModel(store: store, api: APIClient(settings: store.settings, session: session))
        self.model = model
        return model
    }

    private func pause(path: String, method: String = "GET") -> PausedStateFixture {
        let fixture = PausedStateFixture(path: path, method: method,
            started: expectation(description: "old request started"),
            bootstrapFinished: expectation(description: "replacement bootstrap finished"))
        PausedStateProtocol.fixture = fixture
        return fixture
    }

    private func changeServer(_ model: AppModel) {
        var next = model.settings
        next.apiBase = "http://new.runtime.test"
        XCTAssertTrue(model.applySettings(next))
    }

    func testOldTaskSuccessCannotRepopulateNewServerState() async {
        let model = makeModel()
        let fixture = pause(path: "/api/v1/tasks")
        let loading = Task { await model.loadTasks() }
        await fulfillment(of: [fixture.started], timeout: 2)
        changeServer(model)
        fixture.release(json: #"{"tasks":[{"id":"old-task","status":"completed"}]}"#)
        await loading.value
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(model.tasksNote.isEmpty)
        await fulfillment(of: [fixture.bootstrapFinished], timeout: 2)
    }

    func testOldGatewayErrorCannotReplaceNewServerFeedback() async {
        let model = makeModel()
        let fixture = pause(path: "/api/v1/gateways")
        let loading = Task { await model.loadGateways() }
        await fulfillment(of: [fixture.started], timeout: 2)
        changeServer(model)
        model.gatewaysNote = "new server feedback"
        fixture.release(status: 500, json: #"{"error":"old failure"}"#)
        await loading.value
        XCTAssertEqual(model.gatewaysNote, "new server feedback")
        await fulfillment(of: [fixture.bootstrapFinished], timeout: 2)
    }

    func testOldCreateCannotSelectSessionOnNewServer() async {
        let model = makeModel()
        let fixture = pause(path: "/api/v1/sessions", method: "POST")
        let creating = Task { await model.newSession() }
        await fulfillment(of: [fixture.started], timeout: 2)
        changeServer(model)
        fixture.release(json: #"{"id":"created-on-old-runtime","title":"Old session"}"#)
        await creating.value
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.activeSessionId.isEmpty)
        await fulfillment(of: [fixture.bootstrapFinished], timeout: 2)
    }

    func testAuthChangeInvalidatesSessionsEvenWhenBaseIsUnchanged() async {
        let model = makeModel()
        let fixture = pause(path: "/api/v1/sessions")
        let loading = Task { await model.refreshSessions() }
        await fulfillment(of: [fixture.started], timeout: 2)
        var next = model.settings
        next.useBearer.toggle()
        XCTAssertTrue(model.applySettings(next))
        fixture.release(json: #"{"sessions":[{"id":"old-identity-session"}]}"#)
        await loading.value
        XCTAssertTrue(model.sessions.isEmpty)
        await fulfillment(of: [fixture.bootstrapFinished], timeout: 2)
    }
}
