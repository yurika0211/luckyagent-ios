import SwiftUI

struct ChatTimelineSection: Identifiable {
    var lines: [ChatLine]
    var isActivity: Bool
    var id: String { lines[0].id }

    static func group(_ lines: [ChatLine]) -> [Self] {
        var sections: [Self] = []
        for line in lines {
            let activity = line.kind == .reasoning || line.kind == .tool
            if activity, sections.last?.isActivity == true {
                sections[sections.count - 1].lines.append(line)
            } else {
                sections.append(Self(lines: [line], isActivity: activity))
            }
        }
        return sections
    }
}

struct ChatActivityGroup: View {
    var lines: [ChatLine]
    var downloading = false
    var onCopy: (ChatLine) -> Void = { _ in }
    var onQuote: (ChatLine) -> Void = { _ in }
    var onPreview: (MediaAttachment) -> Void = { _ in }
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    ChatMessageContent(line: line, downloading: downloading,
                                       onCopy: { onCopy(line) }, onQuote: { onQuote(line) }, onPreview: onPreview)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.subheadline)
                Text("思考与执行").font(.subheadline.weight(.medium))
                Text("\(lines.count) 项").font(.caption).monospacedDigit()
                Spacer()
                if failedCount > 0 {
                    Text("\(failedCount) 项失败").font(.caption).foregroundStyle(Clover.error)
                } else if lines.contains(where: { $0.streaming || $0.toolState == "running" }) {
                    Text("执行中").font(.caption)
                }
            }
            .padding(.vertical, 8)
        }
        .foregroundStyle(.secondary)
    }

    private var failedCount: Int {
        lines.filter { ["error", "failed"].contains($0.toolState?.lowercased() ?? "") }.count
    }
}

/// Message presentation is shared by the app and windowless rendering checks.
struct ChatMessageContent: View {
    var line: ChatLine
    var downloading = false
    var onCopy: () -> Void = {}
    var onQuote: () -> Void = {}
    var onPreview: (MediaAttachment) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var detailsExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.kind == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 10) {
                message
                if !line.attachments.isEmpty { attachments }
                if line.kind == .assistant && !line.text.isEmpty { actions }
            }
            .padding(line.kind == .user ? 14 : 0)
            .background(line.kind == .user ? (scheme == .dark ? Clover.darkUser : Clover.user) : .clear,
                        in: RoundedRectangle(cornerRadius: 22))
            .contextMenu {
                Button(action: onCopy) { Label("复制", systemImage: "doc.on.doc") }
                Button(action: onQuote) { Label("引用", systemImage: "text.quote") }
            }
            if line.kind != .user { Spacer(minLength: 8) }
        }
    }

    @ViewBuilder private var message: some View {
        switch line.kind {
        case .user, .assistant:
            ChatMarkdownView(text: line.text, expandsHorizontally: line.kind != .user)
                .fixedSize(horizontal: false, vertical: true)
        case .reasoning, .tool:
            DisclosureGroup(isExpanded: $detailsExpanded) {
                Group {
                    if line.kind == .reasoning {
                        ChatMarkdownView(text: line.text, compact: true)
                    } else {
                        Text(verbatim: line.text.isEmpty ? "等待工具结果…" : line.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(scheme == .dark ? Clover.darkSurface : Clover.tool,
                            in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 8)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: line.kind == .reasoning ? "sparkle" : "wrench.and.screwdriver")
                        .font(.system(size: 15, weight: .medium))
                    Text(line.kind == .reasoning ? (line.streaming ? "正在思考" : "思考过程") : (line.toolName ?? "工具调用"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if line.kind == .tool {
                        Text(toolState).font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 9)
            }
            .tint(scheme == .dark ? Clover.darkAccent : Clover.accent)
        case .error:
            Label {
                Text(verbatim: line.text).textSelection(.enabled)
            } icon: { Image(systemName: "exclamationmark.circle") }
            .font(.callout)
            .foregroundStyle(Clover.error)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Clover.error.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        case .status, .system:
            Text(verbatim: line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.vertical, 4)
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(line.attachments) { attachment in
                Button { onPreview(attachment) } label: {
                    Label(attachment.fileName ?? attachment.type, systemImage: "doc.text")
                        .font(.subheadline)
                        .lineLimit(2)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(scheme == .dark ? Clover.darkSurface : Clover.surface.opacity(0.8),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(downloading)
            }
            if downloading { ProgressView("下载附件…").font(.caption) }
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("复制回复")
            Button(action: onQuote) { Image(systemName: "text.quote") }
                .accessibilityLabel("引用回复")
            if line.streaming {
                Text("正在回复…").font(.caption).padding(.leading, 8)
            }
        }
        .buttonStyle(CloverIconButtonStyle())
        .foregroundStyle(.secondary)
    }

    private var toolState: String {
        switch line.toolState?.lowercased() {
        case "running": return "执行中"
        case "done", "success", "completed": return "已完成"
        case "error", "failed": return "失败"
        default: return line.toolState ?? ""
        }
    }
}

struct ChatComposerBar<Leading: View>: View {
    @Binding var text: String
    var canSend: Bool
    var queued = false
    @ViewBuilder var leading: () -> Leading
    var onSend: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            leading()
                .buttonStyle(CloverIconButtonStyle())
                .foregroundStyle(.secondary)
            TextField("问 LuckyAgent", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .padding(.vertical, 12)
                .padding(.horizontal, 3)
                .frame(minHeight: 48)
                .accessibilityLabel("消息内容")
            Button(action: onSend) {
                Image(systemName: queued ? "text.line.first.and.arrowtriangle.forward" : "paperplane")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : (scheme == .dark ? Clover.darkText2 : Clover.text2))
                    .frame(width: 44, height: 44)
                    .background(canSend ? Clover.accent : (scheme == .dark ? Clover.darkUser : Clover.user), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(queued ? "排队发送" : "发送")
            .padding(2)
        }
        .padding(6)
        .background(scheme == .dark ? Clover.darkSurface : Clover.surface, in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(scheme == .dark ? Clover.darkLine : Clover.line.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.035), radius: 16, y: 4)
    }
}
