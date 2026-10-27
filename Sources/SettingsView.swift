import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = AppSettings()
    @State private var revealKey = false
    @State private var pairingExpanded = false
    @State private var pairingText = ""
    @State private var pairingNote = ""
    @State private var pairingFailed = false
    @State private var settingsNote = ""
    @State private var invalidSettings = false
    @State private var copiedSession = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                connectionCard
                sessionCard
                pairingCard
                diagnosticsCard
                appearanceCard
                aboutCard
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = model.settings }
        .onChange(of: model.activeSessionId) { previous, current in
            if draft.sessionId == previous { draft.sessionId = current }
            copiedSession = false
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text("基础设置")
                    .font(.title.weight(.bold))
                Text("连接电脑上的 LuckyAgent，管理会话、配对与显示偏好。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionCard: some View {
        card("运行时连接", systemImage: "server.rack", description: "当前服务：\(runtimeHost)") {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("服务地址")
                TextField("http://127.0.0.1:9090", text: $draft.apiBase)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(SettingsInputStyle())
                Text("模拟器可使用本机地址；真机请填写电脑的局域网地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    fieldLabel("API Key")
                    Spacer(minLength: 8)
                    Button { revealKey.toggle() } label: {
                        Label(revealKey ? "隐藏" : "显示", systemImage: revealKey ? "eye.slash" : "eye")
                            .font(.subheadline)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .accessibilityLabel(revealKey ? "隐藏 API Key" : "显示 API Key")
                }
                Group {
                    if revealKey { TextField("服务端配置的密钥，可留空", text: $draft.apiKey) }
                    else { SecureField("服务端配置的密钥，可留空", text: $draft.apiKey) }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .modifier(SettingsInputStyle())
                Text("密钥保存在设备钥匙串中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("鉴权方式")
                Picker("鉴权方式", selection: $draft.useBearer) {
                    Text("Bearer Token").tag(true)
                    Text("X-API-Key").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SettingsInputStyle())
                Text("与电脑端的鉴权配置保持一致。配对临时密钥使用 X-API-Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { _ = save() } label: {
                Label("保存连接设置", systemImage: "checkmark")
            }
            .buttonStyle(CloverActionButtonStyle(prominent: true))
            if !settingsNote.isEmpty {
                feedback(settingsNote, failed: invalidSettings)
            }
        }
        .disabled(model.busy)
    }

    private var sessionCard: some View {
        card("当前会话", systemImage: "bubble.left.and.bubble.right", description: "会话保存在电脑端，切换后会加载对应的聊天记录。") {
            if model.activeSessionId.isEmpty {
                Text("尚未选择会话")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.activeSessionId)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    UIPasteboard.general.string = model.activeSessionId
                    copiedSession = true
                } label: {
                    Label(copiedSession ? "已复制当前会话 ID" : "复制当前会话 ID", systemImage: copiedSession ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(CloverActionButtonStyle())
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("会话 ID（可选）")
                TextField("留空时自动选择或创建会话", text: $draft.sessionId, axis: .vertical)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(SettingsInputStyle())
                    .disabled(model.busy)
                Text("会话 ID 的修改会随连接设置一起保存。也可以在聊天页选择会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairingCard: some View {
        card("配对", systemImage: "link", description: "在电脑端运行 lh qr，粘贴生成的 JSON 即可填入连接信息。") {
            DisclosureGroup(isExpanded: $pairingExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Button { pastePairing() } label: {
                        Label("粘贴配对内容", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(CloverActionButtonStyle())
                    TextField("在此粘贴 lh qr 输出的完整 JSON", text: $pairingText, axis: .vertical)
                        .font(.footnote.monospaced())
                        .lineLimit(5...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .modifier(SettingsInputStyle())
                    Button { applyPairing() } label: {
                        Label("应用配对信息", systemImage: "link.badge.plus")
                    }
                    .buttonStyle(CloverActionButtonStyle(prominent: true))
                    .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 14)
            } label: {
                Text("使用配对文本")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.vertical, 4)
            }
            if !pairingNote.isEmpty { feedback(pairingNote, failed: pairingFailed) }
        }
        .disabled(model.busy)
    }

    private var diagnosticsCard: some View {
        card("连接诊断", systemImage: "waveform.path.ecg", description: "检查已保存的运行时连接。") {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("HTTP 健康检查")
                Text(model.healthText == "还没探测" ? "尚未探测" : model.healthText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(inputBackground, in: RoundedRectangle(cornerRadius: 14))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: socketSymbol)
                    .font(.system(size: 24))
                    .foregroundStyle(socketColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text("WebSocket")
                        .font(.subheadline.weight(.semibold))
                    Text(socketDescription)
                        .font(.subheadline)
                        .foregroundStyle(socketColor)
                    if !model.statusNote.isEmpty {
                        Text(model.statusNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button {
                guard save() else { return }
                Task { await model.probe() }
            } label: {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(.white) }
                    Label(model.busy ? "正在探测…" : "保存并探测", systemImage: "heart.text.square")
                }
            }
            .buttonStyle(CloverActionButtonStyle(prominent: true))
            .disabled(model.busy)
            Button { model.reconnect() } label: {
                Label("重连 WebSocket", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CloverActionButtonStyle())
            .disabled(model.busy)
            if invalidSettings && !settingsNote.isEmpty {
                feedback(settingsNote, failed: true)
            }
        }
    }

    private var appearanceCard: some View {
        card("外观", systemImage: "circle.lefthalf.filled", description: "切换后立即生效，并保留你的选择。") {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    appearancePicker.pickerStyle(.menu)
                } else {
                    appearancePicker.pickerStyle(.segmented)
                }
            }
            .onChange(of: draft.appearance) { _, appearance in
                var next = model.settings
                next.appearance = appearance
                guard model.applySettings(next) else {
                    draft.appearance = model.settings.appearance
                    invalidSettings = true
                    settingsNote = model.banner ?? "外观设置未能保存，请重试。"
                    return
                }
            }
        }
        .disabled(model.busy)
    }

    private var appearancePicker: some View {
        Picker("显示模式", selection: $draft.appearance) {
            Text("跟随系统").tag("system")
            Text("浅色").tag("light")
            Text("深色").tag("dark")
        }
        .tint(accent)
    }

    private var aboutCard: some View {
        card("关于", systemImage: "leaf", description: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LuckyAgent for iOS")
                    .font(.headline)
                Text("版本 \(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("手机是客户端。Agent、模型、记忆和工具运行在电脑的 lh serve 上。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(_ title: String, systemImage: String, description: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    if let description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .cloverCard()
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold))
    }

    private func feedback(_ text: String, failed: Bool) -> some View {
        Label(text, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
            .font(.footnote)
            .foregroundStyle(failed ? Clover.error : accent)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private var accent: Color { scheme == .dark ? Clover.darkAccent : Clover.accent }
    private var inputBackground: Color { scheme == .dark ? Clover.darkBg : Clover.bg }

    private var runtimeHost: String {
        guard let components = URLComponents(string: model.settings.apiBase), let host = components.host else {
            return "尚未配置"
        }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var socketDescription: String {
        switch model.socketState {
        case .idle: return "尚未连接"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .running: return "任务执行中"
        case .reconnecting: return "正在重新连接"
        case .closed: return "连接已关闭"
        case .error: return "连接异常"
        }
    }

    private var socketSymbol: String {
        switch model.socketState {
        case .connected, .running: return "checkmark.circle"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.circle"
        case .idle, .closed: return "network"
        }
    }

    private var socketColor: Color {
        switch model.socketState {
        case .connected, .running: return accent
        case .connecting, .reconnecting: return Clover.warning
        case .error: return Clover.error
        case .idle, .closed: return .secondary
        }
    }

    @discardableResult private func save() -> Bool {
        guard let base = RuntimePresentation.normalizedAPIBase(draft.apiBase) else {
            invalidSettings = true
            settingsNote = "地址无效：请填写完整的 http:// 或 https:// 地址，不要包含账号、查询参数或 #。"
            return false
        }
        draft.apiBase = base
        draft.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.sessionId = draft.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.applySettings(draft) else {
            invalidSettings = true
            settingsNote = model.banner ?? "连接设置未能保存，请重试。"
            return false
        }
        invalidSettings = false
        settingsNote = "连接设置已保存。"
        return true
    }

    private func pastePairing() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            pairingFailed = true
            pairingNote = "剪贴板中没有可用的文本。"
            return
        }
        pairingText = text
        pairingFailed = false
        pairingNote = "已粘贴，请确认后应用配对信息。"
    }

    private func applyPairing() {
        guard let payload = PairingQR.parse(pairingText) else {
            pairingFailed = true
            pairingNote = "配对文本无法解析，请粘贴 lh qr 输出的完整 JSON。"
            return
        }
        draft.apiBase = payload.apiBase
        draft.apiKey = payload.apiKey
        draft.useBearer = false
        if save() {
            pairingText = ""
            pairingFailed = false
            pairingNote = "已保存配对：\(payload.name)"
        } else {
            pairingFailed = true
            pairingNote = settingsNote
        }
    }
}

private struct SettingsInputStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .frame(minHeight: 24)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Clover.darkBg : Clover.bg, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(scheme == .dark ? Clover.darkLine : Clover.line, lineWidth: 1)
            }
    }
}
