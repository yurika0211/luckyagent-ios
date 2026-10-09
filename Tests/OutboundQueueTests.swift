import XCTest
@testable import LuckyAgent

final class OutboundQueueTests: XCTestCase {
    func testOneInFlightBlocksTheRest() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.enqueue(item("b", session: "s1"))

        XCTAssertEqual(queue.nextSendable(sessionId: "s1")?.id, "a")
        queue.markSending(id: "a")
        XCTAssertNil(queue.nextSendable(sessionId: "s1"))

        queue.remove(id: "a")
        XCTAssertEqual(queue.nextSendable(sessionId: "s1")?.id, "b")
    }

    func testFailedDoesNotBlockLaterMessages() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.enqueue(item("b", session: "s1"))
        queue.markFailed(id: "a", error: "断了")

        XCTAssertEqual(queue.nextSendable(sessionId: "s1")?.id, "b")
        XCTAssertEqual(queue.item(id: "a")?.status, .failed)
    }

    func testSessionsDoNotBlockEachOther() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.enqueue(item("b", session: "s2"))
        queue.markSending(id: "a")

        XCTAssertNil(queue.nextSendable(sessionId: "s1"))
        XCTAssertEqual(queue.nextSendable(sessionId: "s2")?.id, "b")
    }

    func testRetryGoesBackToTheFront() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.enqueue(item("b", session: "s1"))
        queue.markFailed(id: "a", error: "断了")
        queue.retry(id: "a")

        XCTAssertEqual(queue.nextSendable(sessionId: "s1")?.id, "a")
        XCTAssertEqual(queue.visible(sessionId: "s1").map(\.id), ["a", "b"])
        XCTAssertNil(queue.item(id: "a")?.error)
    }

    func testRetryIgnoresItemsThatAreNotFailed() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.markSending(id: "a")
        queue.retry(id: "a")
        XCTAssertEqual(queue.item(id: "a")?.status, .sending)
    }

    func testStopDropsActiveButKeepsFailed() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.enqueue(item("b", session: "s1"))
        queue.enqueue(item("c", session: "s1"))
        queue.markFailed(id: "a", error: "断了")
        queue.markSending(id: "b")
        queue.dropActive(sessionId: "s1")

        XCTAssertEqual(queue.visible(sessionId: "s1").map(\.id), ["a"])
    }

    func testRemoveSessionDoesNotTouchAnother() {
        var queue = OutboundQueue()
        queue.enqueue(item("a", session: "s1"))
        queue.enqueue(item("b", session: "s2"))
        queue.removeSession("s1")
        XCTAssertEqual(queue.items.map(\.id), ["b"])
    }

    private func item(_ id: String, session: String) -> OutboundItem {
        OutboundItem(
            id: id,
            sessionId: session,
            preview: id,
            message: id,
            attachments: [],
            requestId: nil,
            status: .queued,
            error: nil
        )
    }
}
