import Foundation

/// Client-side FIFO for one chat session.
///
/// The runtime runs one turn per session. While that turn is in flight, later
/// composer submits stay queued. A failed item stays until retry and does not
/// block messages queued after it. This matches the Android `OutboundChatQueue`.
enum OutboundStatus: String, Equatable {
    case queued
    case sending
    case failed
}

struct OutboundItem: Identifiable, Equatable {
    var id: String
    var sessionId: String
    var preview: String
    var message: String
    var attachments: [MediaAttachment]
    var requestId: String?
    var status: OutboundStatus
    var error: String?
}

struct OutboundQueue: Equatable {
    private(set) var items: [OutboundItem] = []

    mutating func enqueue(_ item: OutboundItem) {
        items.append(item)
    }

    /// Next sendable message. One in-flight item blocks the rest of that session.
    func nextSendable(sessionId: String) -> OutboundItem? {
        let mine = items.filter { $0.sessionId == sessionId }
        if mine.contains(where: { $0.status == .sending }) { return nil }
        return mine.first { $0.status == .queued }
    }

    func visible(sessionId: String) -> [OutboundItem] {
        items.filter { $0.sessionId == sessionId }
    }

    var waitingCount: Int {
        items.filter { $0.status == .queued || $0.status == .sending }.count
    }

    mutating func markSending(id: String) {
        update(id) { item in
            item.status = .sending
            item.error = nil
        }
    }

    mutating func markSent(id: String, requestId: String) {
        update(id) { item in
            item.status = .sending
            item.requestId = requestId
            item.error = nil
        }
    }

    mutating func markFailed(id: String, error: String) {
        update(id) { item in
            item.status = .failed
            item.error = error
        }
    }

    /// Put a failed item back at the front of the waiting line.
    mutating func retry(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .failed else { return }
        var item = items.remove(at: index)
        item.status = .queued
        item.error = nil
        item.requestId = nil
        let insertAt = items.firstIndex { $0.sessionId == item.sessionId && $0.status == .queued } ?? items.endIndex
        items.insert(item, at: insertAt)
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    /// Stop drops the in-flight item and everything still waiting for this session.
    /// Failed items stay so they can be retried.
    mutating func dropActive(sessionId: String) {
        items.removeAll { $0.sessionId == sessionId && $0.status != .failed }
    }

    mutating func removeSession(_ sessionId: String) {
        items.removeAll { $0.sessionId == sessionId }
    }

    func item(id: String) -> OutboundItem? {
        items.first { $0.id == id }
    }

    private mutating func update(id: String, _ change: (inout OutboundItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
