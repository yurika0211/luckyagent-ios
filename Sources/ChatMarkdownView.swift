import SwiftUI
import MarkdownUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension ChatLine.Kind {
    var rendersMarkdown: Bool {
        switch self {
        case .user, .assistant, .reasoning: return true
        case .tool, .status, .error, .system: return false
        }
    }
}

/// The source remains untouched so streaming, copying and quoting use the same text.
struct ChatMarkdownView: View {
    let text: String
    var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Markdown(text.isEmpty ? "…" : text)
            .markdownTheme(theme)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var theme: Theme {
        Theme.gitHub
            .text {
                FontSize(compact ? 13 : 16)
                ForegroundColor(.primary)
                BackgroundColor(nil)
            }
            .link {
                ForegroundColor(scheme == .dark ? Clover.darkAccent : Clover.accent)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(scheme == .dark ? Clover.darkSurface : Clover.tool)
            }
            .codeBlock { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(configuration.language ?? "代码")
                            .font(.caption.monospaced())
                        Spacer()
                        Button("复制代码") { copyCode(configuration.content) }
                            .font(.caption)
                            .buttonStyle(.plain)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                    ScrollView(.horizontal) {
                        configuration.label
                            .fixedSize(horizontal: true, vertical: false)
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.9))
                                BackgroundColor(nil)
                            }
                            .padding(12)
                    }
                }
                .background(scheme == .dark ? Clover.darkSurface : Clover.tool)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .markdownMargin(top: 0, bottom: 12)
            }
            .table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: false)
                        .markdownTableBorderStyle(.init(color: scheme == .dark ? Clover.darkLine : Clover.line))
                        .markdownTableBackgroundStyle(.alternatingRows(.clear, scheme == .dark ? Clover.darkSurface : Clover.tool))
                }
                .markdownMargin(top: 0, bottom: 12)
            }
    }

    @MainActor private func copyCode(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        #endif
    }
}
