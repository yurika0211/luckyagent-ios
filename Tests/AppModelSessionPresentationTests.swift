import Foundation
import XCTest
@testable import LuckyAgent

private enum SessionListReply {
    case json(status: Int, body: String)
    case cancellation
}

private final class SessionPresentationProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: SessionPresentationFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture?.receive(self) }
    override func stopLoading() {}

    func reply(_ reply: SessionListReply) {
        switch reply {
        case .json(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .cancellation:
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }
}

private final class SessionPresentationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [SessionListReply]
    private var firstRequest: SessionPresentationProtocol?
    private var receivedFirst = false
    let firstStarted: XCTestExpectation?

    init(replies: [SessionListReply], holdingFirst started: XCTestExpectation? = nil) {
        self.replies = replies
        firstStarted = started
    }

    func receive(_ request: SessionPresentationProtocol) {
        lock.lock()
        if !receivedFirst, let firstStarted {
            receivedFirst = true
            firstRequest = request
            lock.unlock()
            firstStarted.fulfill()
            return
        }
        receivedFirst = true
        let reply = replies.isEmpty ? .json(status: 503, body: #"{"error":"unavailable"}"#) : replies.removeFirst()
        lock.unlock()
        request.reply(reply)
    }

    func releaseFirst(_ reply: SessionListReply) {
        lock.lock()
        let request = firstRequest
        firstRequest = nil
        lock.unlock()
        request?.reply(reply)
    }
}

@MainActor
final class AppModelSessionPresentationTests: XCTestCase {
    private var session: URLSession?
    private var model: AppModel?
    private var defaults: UserDefaults?
    private var suite: String?

    override func tearDown() {
        model?.suspendConnection()
        session?.invalidateAndCancel()
        SessionPresentationProtocol.fixture = nil
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func makeModel(_ fixture: SessionPresentationFixture) -> AppModel {
        let suite = "LuckyAgentSessionPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.suite = suite
        self.defaults = defaults
        let settings = AppSettings(apiBase: "http://sessions.runtime.test", sessionId: "existing-session")
        defaults.set(try! JSONEncoder().encode(settings), forKey: "luckyagent.settings")
        let store = SettingsStore(defaults: defaults, keychainService: suite)
        SessionPresentationProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionPresentationProtocol.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        let model = AppModel(store: store, api: APIClient(settings: store.settings, session: session))
        self.model = model
        return model
    }

    func testFailedListAndSuccessfulEmptyListHaveDifferentPresentationState() async {
        let model = makeModel(SessionPresentationFixture(replies: [
            .json(status: 503, body: #"{"error":"unavailable"}"#),
            .json(status: 200, body: #"{"sessions":[],"has_more":false}"#)
        ]))
        await model.refreshSessions()
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.sessionsNote.contains("503"))
        XCTAssertEqual(model.banner, model.sessionsNote)

        await model.refreshSessions()
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.sessionsNote.isEmpty)
    }

    func testOlderSuccessForSameQueryCannotReplaceNewerResult() async {
        let started = expectation(description: "older request is pending")
        let fixture = SessionPresentationFixture(replies: [
            .json(status: 200, body: #"{"sessions":[{"id":"new-result"}],"has_more":false}"#)
        ], holdingFirst: started)
        let model = makeModel(fixture)
        model.sessionQuery = "same query"
        let older = Task { await model.refreshSessions() }
        await fulfillment(of: [started], timeout: 2)
        await model.refreshSessions()
        XCTAssertEqual(model.sessions.map(\.id), ["new-result"])
        fixture.releaseFirst(.json(status: 200, body: #"{"sessions":[{"id":"old-result"}],"has_more":false}"#))
        await older.value
        XCTAssertEqual(model.sessions.map(\.id), ["new-result"])
        XCTAssertTrue(model.sessionsNote.isEmpty)
    }

    func testOlderFailureForSameQueryCannotReplaceNewerSuccess() async {
        let started = expectation(description: "older request is pending")
        let fixture = SessionPresentationFixture(replies: [
            .json(status: 200, body: #"{"sessions":[{"id":"new-result"}],"has_more":false}"#)
        ], holdingFirst: started)
        let model = makeModel(fixture)
        let older = Task { await model.refreshSessions() }
        await fulfillment(of: [started], timeout: 2)
        await model.refreshSessions()
        fixture.releaseFirst(.json(status: 503, body: #"{"error":"old failure"}"#))
        await older.value
        XCTAssertEqual(model.sessions.map(\.id), ["new-result"])
        XCTAssertTrue(model.sessionsNote.isEmpty)
        XCTAssertNil(model.banner)
    }

    func testCancellationDoesNotBecomeAVisibleLoadFailure() async {
        let model = makeModel(SessionPresentationFixture(replies: [.cancellation]))
        await model.refreshSessions()
        XCTAssertTrue(model.sessionsNote.isEmpty)
        XCTAssertNil(model.banner)
    }

    func testSelectingCurrentSessionRetriesFailedHistoryBeforeClearingTheError() async {
        let model = makeModel(SessionPresentationFixture(replies: [
            .json(status: 503, body: #"{"error":"history unavailable"}"#),
            .json(status: 200, body: #"{"id":"existing-session","messages":[{"role":"assistant","content":"history restored"}],"message_count":1,"has_more":false}"#)
        ]))
        await model.loadHistory()
        XCTAssertFalse(model.sessionsNote.isEmpty)
        XCTAssertTrue(model.lines.isEmpty)

        await model.selectSession(RuntimeSession(id: "existing-session"))
        XCTAssertTrue(model.sessionsNote.isEmpty)
        XCTAssertEqual(model.activeSessionId, "existing-session")
        XCTAssertEqual(model.lines.map(\.text), ["history restored"])
    }

    func testSessionMutationFailuresAreVisibleEvenWhenErrorTextRepeats() async {
        let model = makeModel(SessionPresentationFixture(replies: []))
        let existing = RuntimeSession(id: "existing-session")
        model.sessions = [existing]
        await model.newSession()
        XCTAssertEqual(model.activeSessionId, existing.id)
        XCTAssertEqual(model.sessions, [existing])
        XCTAssertFalse(model.sessionsNote.isEmpty)
        let firstError = model.sessionsNote
        model.sessionsNote = ""
        await model.renameSession(existing, title: "new title")
        XCTAssertEqual(model.sessionsNote, firstError)
        model.sessionsNote = ""
        await model.togglePin(existing)
        XCTAssertEqual(model.sessionsNote, firstError)
        model.sessionsNote = ""
        await model.deleteSession(existing)
        XCTAssertEqual(model.sessionsNote, firstError)
        XCTAssertEqual(model.sessions, [existing])
    }
}
