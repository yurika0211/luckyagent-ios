import SwiftUI
import XCTest
@testable import LuckyAgent
#if os(macOS)
import AppKit
#endif

@MainActor
final class ChatDesignPreviewTests: XCTestCase {
    func testGroupingRetainsEveryLineAndUsesConversationBoundaries() {
        let lines = [
            line("u1", .user), line("r1", .reasoning), line("t1", .tool), line("r2", .reasoning),
            line("a1", .assistant), line("t2", .tool), line("e1", .error), line("r3", .reasoning),
            line("u2", .user), line("s1", .status), line("t3", .tool), line("sys1", .system)
        ]
        let grouped = ChatTimelineSection.group(lines)
        XCTAssertEqual(grouped.flatMap(\.lines), lines)
        XCTAssertEqual(grouped.map(\.id), ["u1", "r1", "a1", "t2", "e1", "r3", "u2", "s1", "t3", "sys1"])
        XCTAssertEqual(grouped.filter(\.isActivity).map { $0.lines.map(\.id) }, [["r1", "t1", "r2"], ["t2"], ["r3"], ["t3"]])
        XCTAssertTrue(ChatTimelineSection.group([]).isEmpty)
    }

    func testStreamingUpdatesAndNewActivityKeepTheFirstLinesIdentity() {
        var lines = [line("r1", .reasoning), line("t1", .tool)]
        let firstID = ChatTimelineSection.group(lines).first?.id
        lines[0].text += "\n新增测试片段"
        lines[0].streaming = true
        lines.append(line("r2", .reasoning))
        lines.append(line("a1", .assistant))
        let grouped = ChatTimelineSection.group(lines)
        XCTAssertEqual(grouped.first?.id, firstID)
        XCTAssertEqual(grouped.first?.lines.map(\.id), ["r1", "t1", "r2"])
        XCTAssertEqual(grouped.first?.lines.first?.text, lines[0].text)
        XCTAssertEqual(grouped.flatMap(\.lines), lines)
    }

    private func line(_ id: String, _ kind: ChatLine.Kind) -> ChatLine {
        ChatLine(id: id, kind: kind, text: "测试文案 \(id)")
    }

    #if os(macOS)
    func testNativeChatDesignAtPhoneWidthsAndLargeType() throws {
        for width: CGFloat in [390, 320] {
            for scheme in [ColorScheme.light, .dark] {
                try check(ChatDesignPreview(width: width, scheme: scheme), width: width)
            }
        }
        try check(ChatDesignPreview(width: 390, scheme: .light, type: .accessibility3), width: 390)
        let paired = HStack(alignment: .top, spacing: 12) {
            ChatDesignPreview(width: 390, scheme: .light)
            ChatDesignPreview(width: 390, scheme: .dark)
        }
        try write(render(paired), name: "chat-design-preview.png")
        try write(render(ChatDesignPreview(width: 390, scheme: .light, type: .accessibility3)),
                  name: "chat-design-accessibility-preview.png")
    }

    private func check<Content: View>(_ content: Content, width: CGFloat) throws {
        let bitmap = try render(content)
        XCTAssertEqual(bitmap.pixelsWide, Int(width))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
        XCTAssertLessThan(bitmap.pixelsHigh, 4_000)
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        var changed = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                if abs(Int(bytes[offset]) - Int(bytes[0])) + abs(Int(bytes[offset + 1]) - Int(bytes[1]))
                    + abs(Int(bytes[offset + 2]) - Int(bytes[2])) > 24 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 500, "The actual message/composer views must draw visible content")
        let probe = try render(content.padding(12).background(Color(red: 1, green: 0, blue: 1)))
        XCTAssertEqual(probe.pixelsWide, Int(width) + 24)
        let pixels = try XCTUnwrap(probe.bitmapData)
        var escaped = 0
        let columns = Array(0..<12) + Array((probe.pixelsWide - 12)..<probe.pixelsWide)
        for y in 0..<probe.pixelsHigh {
            for x in columns {
                let offset = y * probe.bytesPerRow + x * 4
                if abs(Int(pixels[offset]) - Int(pixels[0])) + abs(Int(pixels[offset + 1]) - Int(pixels[1]))
                    + abs(Int(pixels[offset + 2]) - Int(pixels[2])) > 24 { escaped += 1 }
            }
        }
        XCTAssertEqual(escaped, 0, "Chat content must not paint outside the phone viewport")
    }

    private func render<Content: View>(_ content: Content) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        XCTAssertTrue(size.width.isFinite && size.height.isFinite)
        host.setFrameSize(NSSize(width: ceil(size.width), height: ceil(size.height)))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertNotNil(bitmap.cgImage)
        return bitmap
    }

    private func write(_ bitmap: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("build").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
    }
    #endif
}

#if os(macOS)
@MainActor
private struct ChatDesignPreview: View {
    var width: CGFloat
    var scheme: ColorScheme
    var type: DynamicTypeSize = .large
    @State private var text = "测试文案：补充第三项计划"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("聊天组件预览 · 全部为测试文案")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ChatTimelineSection.group(Self.sample)) { section in
                if section.isActivity {
                    ChatActivityGroup(lines: section.lines)
                } else {
                    ForEach(section.lines) { ChatMessageContent(line: $0) }
                }
            }
            ChatComposerBar(text: $text, canSend: true, leading: {
                Button {} label: { Image(systemName: "plus").font(.system(size: 24)) }
            }, onSend: {})
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, type)
    }

    private static let sample = [
        ChatLine(id: "preview-user", kind: .user, text: "【测试文案】帮我整理三项计划。"),
        ChatLine(id: "preview-reasoning", kind: .reasoning, text: "【测试文案】检查折叠分组，不代表真实推理。"),
        ChatLine(id: "preview-tool", kind: .tool, text: "{\"preview\": true}", toolName: "测试工具", toolState: "done"),
        ChatLine(id: "preview-assistant", kind: .assistant, text: """
        ### 计划示例（测试文案）

        1. **明确目标**，记下需要完成的事项。
        2. 安排一段专注时间。

        > 以上内容仅用于界面测试。

        ```swift
        let preview = true
        print(preview)
        ```
        """)
    ]
}
#endif
