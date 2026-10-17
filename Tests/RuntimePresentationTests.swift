import XCTest
@testable import LuckyAgent

final class RuntimePresentationTests: XCTestCase {
    func testConnectionInputNormalization() {
        XCTAssertEqual(RuntimePresentation.normalizedAPIBase("  https://desktop.local:9090/\n"), "https://desktop.local:9090")
        XCTAssertEqual(RuntimePresentation.normalizedAPIBase("HTTPS://host.local/"), "https://host.local")
        XCTAssertEqual(RuntimePresentation.normalizedAPIBase("http://[::1]:9090"), "http://[::1]:9090")
        XCTAssertEqual(RuntimePresentation.normalizedAPIBase("https://host.local/lucky/"), "https://host.local/lucky")
    }

    func testRejectsUnusableConnectionAddresses() {
        for value in ["desktop:9090", "ftp://host", "http://", "https://user:password@host", "http://host?api_key=secret", "http://host/#fragment", "http://host:0", "http://host:65536"] {
            XCTAssertNil(RuntimePresentation.normalizedAPIBase(value), value)
        }
    }

    func testCancellationMatchesServerTerminalStatuses() {
        for status in ["completed", "failed", "cancelled", ""] {
            XCTAssertFalse(RuntimePresentation.canCancelTask(status: status), status)
        }
        for status in ["pending", "running", "blocked"] {
            XCTAssertTrue(RuntimePresentation.canCancelTask(status: status), status)
        }
    }

    func testSessionToolTraceWireResponse() throws {
        // Contract from internal/server/session_tool_trace.go and internal/tool/trace.go.
        let raw = #"{"session_id":"test","tools":[{"name":"file_read","arguments":"{}","result":"contents","success":true,"annotation":"Read file","duration_ms":8},{"name":"shell","success":false,"error":"exit 1","annotation":"Run command"}],"total_calls":2,"successes":1,"failures":1,"success_rate":0.5}"#
        let trace = try XCTUnwrap(RuntimeToolTrace.parse(raw))
        XCTAssertEqual(trace.totalCalls, 2)
        XCTAssertEqual(trace.tools.count, 2)
        XCTAssertEqual(trace.tools[0].durationMS, 8)
        XCTAssertTrue(trace.tools[0].success)
        XCTAssertEqual(trace.tools[1].error, "exit 1")
        XCTAssertNil(trace.tools[1].result)
    }

    func testEmptyTraceAndUnknownPayloadFallback() throws {
        XCTAssertEqual(try XCTUnwrap(RuntimeToolTrace.parse(#"{"tools":[],"total_calls":0,"successes":0,"failures":0}"#)).tools.count, 0)
        XCTAssertNil(RuntimeToolTrace.parse(#"{"unexpected":"payload"}"#))
        XCTAssertNil(RuntimeToolTrace.parse("server returned text"))
    }
}
