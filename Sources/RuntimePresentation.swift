import Foundation

/// Presentation rules shared by runtime pages; wire fields mirror session_tool_trace.go.
enum RuntimePresentation {
    static func canCancelTask(status: String) -> Bool {
        !["completed", "failed", "cancelled"].contains(status.lowercased()) && !status.isEmpty
    }

    static func normalizedAPIBase(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url, url.host != nil else { return nil }
        if let port = parts.port, !(1...65535).contains(port) { return nil }
        parts.scheme = scheme
        return parts.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct RuntimeToolTrace: Decodable {
    var tools: [RuntimeToolTraceEntry]
    var totalCalls: Int?
    var successes: Int?
    var failures: Int?

    enum CodingKeys: String, CodingKey {
        case tools, successes, failures
        case totalCalls = "total_calls"
    }

    static func parse(_ text: String) -> RuntimeToolTrace? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct RuntimeToolTraceEntry: Decodable {
    var name: String
    var arguments: String?
    var result: String?
    var success: Bool
    var error: String?
    var durationMS: Int64?
    var annotation: String?

    enum CodingKeys: String, CodingKey {
        case name, arguments, result, success, error, annotation
        case durationMS = "duration_ms"
    }
}
