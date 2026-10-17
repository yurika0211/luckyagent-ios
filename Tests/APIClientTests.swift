import Foundation
import XCTest
@testable import LuckyAgent

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static var handle: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handle)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        FixtureURLProtocol.handle = nil
        super.tearDown()
    }

    private func client(base: String = "http://runtime.test:9090", bearer: Bool = true) -> APIClient {
        APIClient(settings: AppSettings(apiBase: base, apiKey: "key", useBearer: bearer), session: session)
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func testAuthBasePrefixAndEncodedSessionPath() async throws {
        FixtureURLProtocol.handle = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            XCTAssertEqual(request.url?.path, "/proxy/api/v1/sessions/session?#")
            XCTAssertNil(request.url?.fragment)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "3")
            return (200, Data(#"{"id":"session?#","messages":[]}"#.utf8))
        }
        let history = try await client(base: "http://runtime.test:9090/proxy///").history(sessionId: "session?#", offset: 3)
        XCTAssertEqual(history.id, "session?#")
    }

    func testAPIKeyAndGatewayWithoutID() async throws {
        FixtureURLProtocol.handle = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(#"{"gateways":[{"name":"telegram","running":true,"stats":{}}]}"#.utf8))
        }
        let gateways = try await client(bearer: false).listGateways()
        XCTAssertEqual(gateways.first?.id, "telegram")
    }

    func testSessionListFollowsPaginationAndKeepsSearchQuery() async throws {
        var offsets: [String] = []
        FixtureURLProtocol.handle = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "query & text")
            XCTAssertEqual(query.first(where: { $0.name == "limit" })?.value, "200")
            let offset = query.first(where: { $0.name == "offset" })?.value ?? "missing"
            offsets.append(offset)
            if offset == "0" {
                return (200, Data(#"{"sessions":[{"id":"s1"}],"offset":0,"has_more":true,"total":2}"#.utf8))
            }
            XCTAssertEqual(offset, "1")
            return (200, Data(#"{"sessions":[{"id":"s2"}],"offset":1,"has_more":false,"total":2}"#.utf8))
        }
        let sessions = try await client().listSessions(query: "query & text")
        XCTAssertEqual(sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(offsets, ["0", "1"])
    }

    func testSessionPaginationRejectsNoProgressAndPropagatesLaterFailure() async throws {
        FixtureURLProtocol.handle = { _ in (200, Data(#"{"sessions":[],"has_more":true,"offset":0}"#.utf8)) }
        do {
            _ = try await client().listSessions()
            XCTFail("Invalid pagination must terminate with an error")
        } catch is DecodingError {}
        FixtureURLProtocol.handle = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.first(where: { $0.name == "offset" })?.value == "0" {
                return (200, Data(#"{"sessions":[{"id":"s1"}],"has_more":true,"offset":0}"#.utf8))
            }
            return (503, Data(#"{"error":"temporarily unavailable"}"#.utf8))
        }
        do {
            _ = try await client().listSessions()
            XCTFail("A partial page must not hide a later HTTP failure")
        } catch APIError.http(let status, _) {
            XCTAssertEqual(status, 503)
        }
    }

    func testMalformedListsAreReportedAndNilRecallIsEmpty() async throws {
        FixtureURLProtocol.handle = { _ in (200, Data(#"{"results":null}"#.utf8)) }
        let result = try await client().recall(query: "empty")
        XCTAssertTrue(result.isEmpty)
        FixtureURLProtocol.handle = { _ in (200, Data(#"{"gateways":[{"name":42}]}"#.utf8)) }
        do {
            _ = try await client().listGateways()
            XCTFail("A malformed runtime response must remain visible to the user")
        } catch is DecodingError {}
        FixtureURLProtocol.handle = { _ in (200, Data(#"{"unexpected":[]}"#.utf8)) }
        do {
            _ = try await client().listCommands()
            XCTFail("A missing envelope must not look like an empty catalog")
        } catch is DecodingError {}
    }

    func testTaskDetailAndSeparateResultEndpoint() async throws {
        FixtureURLProtocol.handle = { request in
            switch request.url?.path {
            case "/api/v1/tasks/t1":
                return (200, Data(#"{"id":"t1","status":"completed","description":"Inspect"}"#.utf8))
            case "/api/v1/tasks/t1/result":
                return (200, Data(#"{"task_id":"t1","result":"Completed report"}"#.utf8))
            default:
                XCTFail("Unexpected task path")
                return (404, Data())
            }
        }
        let api = client()
        let task = try await api.getTask(id: "t1")
        XCTAssertEqual(task.headline, "Inspect")
        let result = try await api.taskResult(id: "t1")
        XCTAssertEqual(result, "Completed report")
    }

    func testMultipartEscapesFilenameAndPreservesPayload() async throws {
        let bytes = Data([0, 1, 2, 254, 255])
        FixtureURLProtocol.handle = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/uploads")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=LuckyAgent-") == true)
            let body = try Self.bodyData(request)
            XCTAssertNotNil(body.range(of: bytes))
            let prefix = String(decoding: body.prefix(250), as: UTF8.self)
            XCTAssertTrue(prefix.contains(#"filename="report\"partX-Injected: yes.txt""#))
            XCTAssertFalse(prefix.contains("\r\nX-Injected:"))
            return (200, Data(#"{"attachments":[{"type":"document","file_path":"/runtime/uploads/file.txt","file_name":"report.txt","file_size":5}],"count":1}"#.utf8))
        }
        let attachment = try await client().upload(data: bytes, fileName: "report\"part\r\nX-Injected: yes.txt", mime: "text/plain")
        XCTAssertEqual(attachment.filePath, "/runtime/uploads/file.txt")
        XCTAssertEqual(attachment.fileSize, 5)
    }

    func testHTTPFailureRetainsStatusAndEmptyDeleteSucceeds() async throws {
        FixtureURLProtocol.handle = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do {
            _ = try await client().health()
            XCTFail("Expected HTTP failure")
        } catch APIError.http(let code, let body) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("unauthorized"))
        }
        FixtureURLProtocol.handle = { _ in (204, Data()) }
        try await client().deleteSession(id: "s1")
    }

    func testRuntimeArtifactDownloadUsesAuthenticationAndSafeLocalName() async throws {
        FixtureURLProtocol.handle = { request in
            XCTAssertEqual(request.url?.path, "/proxy/api/v1/artifacts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "key")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "path" })?.value, "uploads/day/file.pdf")
            return (200, Data("pdf bytes".utf8))
        }
        let attachment = MediaAttachment(fileUrl: "/api/v1/artifacts?path=uploads%2Fday%2Ffile.pdf", fileName: "../../report.pdf")
        let local = try await client(base: "http://runtime.test:9090/proxy", bearer: false).downloadAttachment(attachment)
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        XCTAssertEqual(local.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: local), Data("pdf bytes".utf8))
    }

    func testExternalDownloadNeverReceivesRuntimeCredentials() async throws {
        FixtureURLProtocol.handle = { request in
            XCTAssertEqual(request.url?.host, "external.test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            return (200, Data("image bytes".utf8))
        }
        let local = try await client().downloadAttachment(MediaAttachment(fileUrl: "https://external.test/image.png"))
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        XCTAssertEqual(local.lastPathComponent, "image.png")
        do {
            _ = try await client().downloadAttachment(MediaAttachment(filePath: "/server/uploads/file.pdf"))
            XCTFail("Server filesystem paths must not be read as local phone files")
        } catch APIError.attachmentUnavailable {}
    }

    func testWebSocketAndInvalidBaseURLs() {
        let api = client(base: "https://runtime.test/proxy/", bearer: false)
        let url = api.webSocketURL(sessionId: "session & one")
        XCTAssertEqual(url?.scheme, "wss")
        XCTAssertEqual(url?.path, "/proxy/api/v1/ws")
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "session" })?.value, "session & one")
        XCTAssertEqual(query?.first(where: { $0.name == "api_key" })?.value, "key")
        XCTAssertNil(client(base: "file:///tmp/runtime").webSocketURL(sessionId: "s"))
        XCTAssertNil(client(base: "http://").webSocketURL(sessionId: "s"))
        XCTAssertNil(client(base: "http://runtime.test?key=wrong").webSocketURL(sessionId: "s"))
    }
}
