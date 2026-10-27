import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import LuckyAgent

@MainActor
final class ChatMarkdownViewTests: XCTestCase {
    private let width: CGFloat = 360

    func testMarkdownIsLimitedToAuthoredMessageRoles() {
        for role in [ChatLine.Kind.user, .assistant, .reasoning] {
            XCTAssertTrue(role.rendersMarkdown, "Authored content should support Markdown: \(role)")
        }
        for role in [ChatLine.Kind.tool, .status, .error, .system] {
            XCTAssertFalse(role.rendersMarkdown, "Operational text must preserve its literal syntax: \(role)")
        }
    }

    #if os(macOS)
    func testCommonGFMProducesVisibleFormattedPixelsInsteadOfLiteralSource() throws {
        let formatted = try renderMarkdown(Self.commonGFM, scheme: .light)
        let literal = try renderLiteral(Self.commonGFM, scheme: .light)
        assertUsable(formatted, maximumHeight: 1_800)
        XCTAssertGreaterThan(formatted.height, 100)
        XCTAssertNotEqual(formatted.pixels, literal.pixels)
        // A short heading has no source line wrapping; the heading's visual
        // hierarchy must change the layout as well as hiding its '#' marker.
        let heading = try renderMarkdown("# Visible heading\n\nParagraph.", scheme: .light)
        let literalHeading = try renderLiteral("# Visible heading\n\nParagraph.", scheme: .light)
        XCTAssertGreaterThan(heading.height, literalHeading.height)
    }

    func testShortCodeBlocksGrowForEveryAdditionalLine() throws {
        let lines = ["let one = 1", "let two = 2", "print(one + two)"]
        for scheme in [ColorScheme.light, .dark] {
            let snapshots = try (1...3).map { count in
                let source = "```swift\n" + lines.prefix(count).joined(separator: "\n") + "\n```"
                return try renderMarkdown(source, scheme: scheme)
            }
            for raster in snapshots { assertUsable(raster, maximumHeight: 400) }
            XCTAssertGreaterThan(snapshots[1].height, snapshots[0].height,
                                 "A two-line code block must not collapse into the single-line viewport")
            XCTAssertGreaterThan(snapshots[2].height, snapshots[1].height,
                                 "The third source line must receive its own vertical space")
        }
    }

    func testLongCodeStaysInsideTheMessageWidth() throws {
        for scheme in [ColorScheme.light, .dark] {
            let formatted = try renderMarkdown(Self.longCode, scheme: scheme)
            let literal = try renderLiteral(Self.longCode, scheme: scheme)
            assertUsable(formatted, maximumHeight: 500)
            // A long source line belongs to the horizontal code viewport, not
            // dozens of wrapped rows that stretch the whole conversation.
            XCTAssertLessThan(formatted.height, literal.height)
            XCTAssertNotEqual(formatted.pixels, literal.pixels)
            try assertNoViewportOverflow(Self.longCode, scheme: scheme)
        }
    }

    func testWideTableRendersIndependentOfCodeAndStaysInsideTheMessageWidth() throws {
        for scheme in [ColorScheme.light, .dark] {
            let table = try renderMarkdown(Self.wideTable, scheme: scheme)
            let literal = try renderLiteral(Self.wideTable, scheme: scheme)
            let empty = try renderEmptyMarkdown(scheme: scheme, height: table.height)
            assertUsable(table, maximumHeight: 500)
            XCTAssertGreaterThan(table.height, 50)
            XCTAssertEqual(table.width, empty.width)
            XCTAssertEqual(table.height, empty.height)
            XCTAssertNotEqual(table.pixels, empty.pixels, "An empty table viewport must not count as rendered table content")
            XCTAssertNotEqual(table.pixels, literal.pixels)
            XCTAssertLessThan(table.height, literal.height)
            try assertNoViewportOverflow(Self.wideTable, scheme: scheme)
        }
    }

    func testStreamingUnclosedMarkdownCanBecomeTheFinalRenderedMessage() throws {
        let renderer = MarkdownSnapshotRenderer(content: MarkdownRasterCard(text: "", scheme: .light, width: width))
        let updates = [
            "**正在生成",
            "**正在生成**\n\n```swift\nlet text = \"**literal**\"",
            "**正在生成**\n\n```swift\nlet text = \"**literal**\"\nprint(text)\n```\n\n| 项目 | 值 |\n| --- | --- |\n| 完成",
            Self.finishedStream
        ]
        var finalRaster: MarkdownRaster?
        for text in updates {
            renderer.content = MarkdownRasterCard(text: text, scheme: .light, width: width)
            let image = try XCTUnwrap(renderer.cgImage, "The current partial response must stay renderable")
            let raster = try MarkdownRaster(image: image)
            assertUsable(raster, maximumHeight: 1_200)
            finalRaster = raster
        }
        // Reusing the view across partial fences must not leave stale literal
        // markers or duplicate blocks after the canonical final response arrives.
        let freshFinal = try renderMarkdown(Self.finishedStream, scheme: .light)
        XCTAssertEqual(finalRaster?.width, freshFinal.width)
        XCTAssertEqual(finalRaster?.height, freshFinal.height)
        XCTAssertEqual(finalRaster?.pixels, freshFinal.pixels)
        XCTAssertNotEqual(freshFinal.pixels, try renderLiteral(Self.finishedStream, scheme: .light).pixels)
    }

    func testLightDarkAndCompactRenderingRemainReadable() throws {
        let light = try renderMarkdown(Self.finishedStream, scheme: .light)
        let dark = try renderMarkdown(Self.finishedStream, scheme: .dark)
        let compact = try renderMarkdown(Self.finishedStream, scheme: .light, compact: true)
        for raster in [light, dark, compact] { assertUsable(raster, maximumHeight: 1_200) }
        XCTAssertNotEqual(light.pixels, dark.pixels)
        XCTAssertGreaterThan(light.backgroundBrightness, dark.backgroundBrightness)
        XCTAssertLessThanOrEqual(compact.height, light.height)
        XCTAssertNotEqual(light.pixels, compact.pixels)
    }

    func testWriteCombinedMarkdownPreview() throws {
        let content = HStack(alignment: .top, spacing: 12) {
            MarkdownRasterCard(text: Self.previewSource, scheme: .light, width: width, showsLayoutGuides: true)
                .padding(12)
                .background(Color.pink.opacity(0.15))
            MarkdownRasterCard(text: Self.previewSource, scheme: .dark, width: width, showsLayoutGuides: true)
                .padding(12)
                .background(Color.pink.opacity(0.15))
        }
        let renderer = MarkdownSnapshotRenderer(content: content)
        let image = try XCTUnwrap(renderer.cgImage)
        // Each 360px viewport has 12px inspection gutters outside its bounds.
        XCTAssertEqual(image.width, Int(width * 2) + 60)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let destination = root.appendingPathComponent("build/markdown-preview.png")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let png = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let bytes = try XCTUnwrap(CFDataGetBytePtr(png))
        try Data(bytes: bytes, count: CFDataGetLength(png)).write(to: destination)
    }

    private func renderMarkdown(_ source: String, scheme: ColorScheme, compact: Bool = false) throws -> MarkdownRaster {
        let renderer = MarkdownSnapshotRenderer(content: MarkdownRasterCard(text: source, scheme: scheme, width: width, compact: compact))
        return try MarkdownRaster(image: XCTUnwrap(renderer.cgImage, "Markdown should render without an app window or simulator"))
    }

    private func assertNoViewportOverflow(_ source: String, scheme: ColorScheme,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let gutter = 12
        let content = MarkdownRasterCard(text: source, scheme: scheme, width: width)
            .padding(CGFloat(gutter))
            .background(Color(red: 1, green: 0, blue: 1))
        let renderer = MarkdownSnapshotRenderer(content: content)
        let raster = try MarkdownRaster(image: XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(raster.width, Int(width) + gutter * 2, file: file, line: line)
        // The inspection gutter is outside the row's fixed viewport. Any text
        // or code/table background painted here escaped its layout boundary.
        XCTAssertEqual(raster.changedSideGutterPixels(gutter), 0, file: file, line: line)
    }

    private func renderEmptyMarkdown(scheme: ColorScheme, height: Int) throws -> MarkdownRaster {
        let content = MarkdownRasterCard(text: "", scheme: scheme, width: width)
            .frame(height: CGFloat(height), alignment: .top)
            .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        let renderer = MarkdownSnapshotRenderer(content: content)
        return try MarkdownRaster(image: XCTUnwrap(renderer.cgImage))
    }

    private func renderLiteral(_ source: String, scheme: ColorScheme) throws -> MarkdownRaster {
        let content = HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: source)
                    .font(.system(size: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            Spacer(minLength: 24)
        }
            .padding(12)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(scheme == .dark ? Clover.darkBg : Clover.bg)
            .environment(\.colorScheme, scheme)
        let renderer = MarkdownSnapshotRenderer(content: content)
        return try MarkdownRaster(image: XCTUnwrap(renderer.cgImage))
    }

    private func assertUsable(_ raster: MarkdownRaster, maximumHeight: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(raster.width, Int(width), "Horizontal content must remain inside the message viewport", file: file, line: line)
        XCTAssertGreaterThan(raster.height, 32, file: file, line: line)
        XCTAssertLessThan(raster.height, maximumHeight, file: file, line: line)
        XCTAssertGreaterThan(raster.foregroundPixelCount, 100, "A nonempty bitmap with only background is not rendered text", file: file, line: line)
    }

    private static let commonGFM = """
    # Markdown 消息

    **粗体**、*斜体*、~~删除线~~、`value_name` 与 [文档](https://example.com/docs)。

    > 引用第一行
    >
    > 引用第二段

    1. 第一项
    2. 第二项

    - 普通条目
      - 嵌套条目
    - [x] 已完成
    - [ ] 待完成

    ---

    中文段落不会丢失；标点、空行和链接仍可阅读。
    """

    private static var longCode: String {
        let longLine = "let payload = \"" + String(repeating: "a_long_literal_value_", count: 80) + "\""
        return """
        ```swift
        \(longLine)
            print(payload)
        ```
        """
    }

    private static var wideTable: String {
        let headers = (1...8).map { "Column \($0)" }.joined(separator: " | ")
        let divider = Array(repeating: "---", count: 8).joined(separator: " | ")
        let values = (1...8).map { "Long value in column \($0)" }.joined(separator: " | ")
        return """
        | \(headers) |
        | \(divider) |
        | \(values) |
        """
    }

    private static let finishedStream = """
    ## 完成的回复

    **结果已生成**，代码中的 Markdown 字符保持原样。

    ```swift
    let text = "**literal**"
    print(text)
    ```

    | 项目 | 值 |
    | --- | --- |
    | 状态 | 完成 |
    | 内容 | `value_name` |
    """

    private static var previewSource: String {
        commonGFM + "\n\n" + finishedStream + "\n\n" + longCode + "\n\n" + wideTable
    }
    #endif
}

#if os(macOS)
@MainActor
private struct MarkdownRasterCard: View {
    var text: String
    var scheme: ColorScheme
    var width: CGFloat
    var compact = false
    var showsLayoutGuides = false

    var body: some View {
        // Match assistant MessageRow's HStack/VStack, bubble padding and trailing
        // spacer, inside ChatView's 12px content padding. Constrain the viewport,
        // rather than imposing a width directly on the Markdown view.
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                ChatMarkdownView(text: text, compact: compact)
            }
            .padding(10)
            .overlay {
                if showsLayoutGuides { Rectangle().stroke(Color.orange, lineWidth: 1) }
            }
            Spacer(minLength: 24)
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .overlay {
            if showsLayoutGuides { Rectangle().stroke(Color.cyan, lineWidth: 1) }
        }
        .environment(\.colorScheme, scheme)
    }
}

private struct MarkdownRaster {
    let width: Int
    let height: Int
    let pixels: Data
    let foregroundPixelCount: Int
    let backgroundBrightness: Int

    func changedSideGutterPixels(_ gutter: Int) -> Int {
        let bytes = [UInt8](pixels)
        var changed = 0
        for y in 0..<height {
            for x in Array(0..<gutter) + Array((width - gutter)..<width) {
                let offset = (y * width + x) * 4
                let difference = abs(Int(bytes[offset]) - Int(bytes[0]))
                    + abs(Int(bytes[offset + 1]) - Int(bytes[1]))
                    + abs(Int(bytes[offset + 2]) - Int(bytes[2]))
                if difference > 24 { changed += 1 }
            }
        }
        return changed
    }

    init(image: CGImage) throws {
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var pixels = Data(count: width * height * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.pixels = pixels
        let bytes = [UInt8](pixels)
        // Sample inside the bottom padding, rather than a potentially
        // transparent viewport corner on the windowless host.
        let background = ((height - 4) * width + width / 2) * 4
        backgroundBrightness = Int(bytes[background]) + Int(bytes[background + 1]) + Int(bytes[background + 2])
        var foreground = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let difference = abs(Int(bytes[offset]) - Int(bytes[background]))
                + abs(Int(bytes[offset + 1]) - Int(bytes[background + 1]))
                + abs(Int(bytes[offset + 2]) - Int(bytes[background + 2]))
            if difference > 24 { foreground += 1 }
        }
        foregroundPixelCount = foreground
    }
}

/// ImageRenderer omits native NSScrollView content on this macOS host. Render
/// the actual SwiftUI view through a windowless NSHostingView instead.
@MainActor
private final class MarkdownSnapshotRenderer<Content: View> {
    private let host: NSHostingView<Content>

    init(content: Content) {
        host = NSHostingView(rootView: content)
    }

    var content: Content {
        get { host.rootView }
        set { host.rootView = newValue }
    }

    var cgImage: CGImage? {
        let size = host.fittingSize
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width < 8_192, size.height < 8_192 else { return nil }
        host.setFrameSize(NSSize(width: ceil(size.width), height: ceil(size.height)))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.cgImage
    }
}
#endif
