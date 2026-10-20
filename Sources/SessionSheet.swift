import SwiftUI

@MainActor
struct SessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedGroups: Set<String> = []
    @State private var renaming: RuntimeSession?
    @State private var deleting: RuntimeSession?
    @State private var newTitle = ""
    @State private var operation: String?
    @State private var isRefreshing = false
    @State private var refreshRequest = UUID()

    private struct SessionGroup: Identifiable {
        var id: String
        var title: String
        var sessions: [RuntimeSession]
        var isPinned = false
    }

    private var groups: [SessionGroup] {
        let pinned = model.sessions.filter(\.pinned)
        let projects = Dictionary(grouping: model.sessions.filter { !$0.pinned }) {
            ($0.project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let names = projects.keys.sorted { left, right in
            if left.isEmpty { return false }
            if right.isEmpty { return true }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        var result: [SessionGroup] = []
        if !pinned.isEmpty {
            result.append(SessionGroup(id: "pinned", title: "置顶", sessions: pinned, isPinned: true))
        }
        result += names.map {
            SessionGroup(id: "project:\($0)", title: $0.isEmpty ? "未分类" : $0, sessions: projects[$0] ?? [])
        }
        return result
    }

    private var background: Color { scheme == .dark ? Clover.darkBg : Clover.bg }
    private var surface: Color { scheme == .dark ? Clover.darkSurface : .white }
    private var primaryText: Color { scheme == .dark ? Clover.darkText : Clover.text }
    private var secondaryText: Color { scheme == .dark ? Clover.darkText2 : Clover.text2 }
    private var accent: Color { scheme == .dark ? Clover.darkAccent : Clover.accent }
    private var isMutating: Bool { operation != nil }
    private var hasQuery: Bool { !model.sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                if !model.sessionsNote.isEmpty {
                    Text(model.sessionsNote)
                        .font(.footnote)
                        .foregroundStyle(Clover.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if model.sessions.isEmpty {
                            emptyState
                        } else {
                            ForEach(groups) { group in
                                sessionGroup(group)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await refresh() }
            }
            .background(background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .alert("重命名会话", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("会话标题", text: $newTitle)
                Button("保存") {
                    guard let session = renaming else { return }
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    renaming = nil
                    perform(for: session.id) { await model.renameSession(session, title: title) }
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("删除会话？", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { session in
                Button("删除会话", role: .destructive) {
                    deleting = nil
                    perform(for: session.id) { await model.deleteSession(session) }
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { session in
                Text("将从服务端删除“\(session.displayTitle)”及其历史消息。")
            }
            .task(id: model.sessionQuery) {
                if hasQuery {
                    do { try await Task.sleep(nanoseconds: 300_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(background)
        .interactiveDismissDisabled(isMutating)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("会话")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(primaryText)
            Spacer(minLength: 12)
            Button {
                let previous = model.activeSessionId
                perform {
                    await model.newSession()
                    if model.sessionsNote.isEmpty, !model.activeSessionId.isEmpty, model.activeSessionId != previous {
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if operation == "create" { ProgressView().controlSize(.small) }
                    else { Image(systemName: "plus") }
                    Text("新建")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(CloverActionButtonStyle(prominent: true))
            .disabled(isMutating)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(CloverIconButtonStyle())
            .accessibilityLabel("关闭会话列表")
            .disabled(isMutating)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(secondaryText)
            TextField("搜索会话", text: $model.sessionQuery)
                .font(.subheadline)
                .foregroundStyle(primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await refresh() } }
            if hasQuery {
                Button { model.sessionQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(secondaryText.opacity(0.65))
                        .frame(width: 28, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
            Button { Task { await refresh() } } label: {
                if isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .medium)) }
            }
            .buttonStyle(CloverIconButtonStyle())
            .accessibilityLabel("刷新会话列表")
            .disabled(isRefreshing || isMutating)
        }
        .padding(.leading, 15)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(surface, in: RoundedRectangle(cornerRadius: 16))
        .disabled(isMutating)
    }

    private func sessionGroup(_ group: SessionGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        return VStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    if collapsed { collapsedGroups.remove(group.id) }
                    else { collapsedGroups.insert(group.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: group.isPinned ? "pin.fill" : "folder.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 24)
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(group.sessions.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(secondaryText)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.title)，\(group.sessions.count) 个会话")
            .accessibilityHint(collapsed ? "展开分组" : "折叠分组")
            if !collapsed {
                ForEach(group.sessions) { session in
                    sessionRow(session)
                }
            }
        }
    }

    private func sessionRow(_ session: RuntimeSession) -> some View {
        let selected = model.activeSessionId == session.id
        return HStack(spacing: 2) {
            Button {
                perform(for: session.id) {
                    await model.selectSession(session)
                    if model.sessionsNote.isEmpty, model.activeSessionId == session.id { dismiss() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(updatedTime(session.updatedAt))
                        if let count = session.messageCount {
                            Text("·")
                            Text("\(count) 条消息").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.leading, 16)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(selected ? "当前会话" : "")
            if operation == "session:\(session.id)" {
                ProgressView().controlSize(.small).frame(width: 44)
            } else {
                Menu {
                    Button {
                        newTitle = session.displayTitle
                        renaming = session
                    } label: { Label("重命名", systemImage: "pencil") }
                    Button {
                        perform(for: session.id) { await model.togglePin(session) }
                    } label: {
                        Label(session.pinned ? "取消置顶" : "置顶", systemImage: session.pinned ? "pin.slash" : "pin")
                    }
                    Divider()
                    Button(role: .destructive) { deleting = session } label: {
                        Label("删除会话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(session.displayTitle)的更多操作")
            }
        }
        .padding(.trailing, 6)
        .background(selected ? (scheme == .dark ? Clover.darkUser : Clover.user) : surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(selected ? accent.opacity(0.65) : .clear, lineWidth: 1)
        }
        .disabled(isMutating)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if isRefreshing {
                ProgressView("正在加载会话")
            } else if !model.sessionsNote.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Clover.error)
                Text("会话暂不可用")
                    .font(.headline)
                    .foregroundStyle(primaryText)
                Button("刷新重试") { Task { await refresh() } }
                    .buttonStyle(CloverActionButtonStyle())
                    .disabled(isMutating)
            } else {
                Image(systemName: hasQuery ? "magnifyingglass" : "bubble.left.and.bubble.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(accent.opacity(0.7))
                Text(hasQuery ? "没有找到会话" : "还没有会话")
                    .font(.headline)
                    .foregroundStyle(primaryText)
                Text(hasQuery ? "换个关键词，或刷新列表。" : "新建一个会话，开始对话。")
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func refresh() async {
        guard !isMutating else { return }
        let request = UUID()
        refreshRequest = request
        isRefreshing = true
        defer { if refreshRequest == request { isRefreshing = false } }
        await model.refreshSessions()
    }

    private func perform(for sessionId: String? = nil, _ action: @escaping @MainActor () async -> Void) {
        guard !isMutating else { return }
        operation = sessionId.map { "session:\($0)" } ?? "create"
        Task {
            defer { operation = nil }
            await action()
        }
    }

    private func updatedTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "暂无更新时间" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = parser.date(from: raw)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? parser.date(from: raw) else { return raw }
        let calendar = Calendar.autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        if calendar.isDateInToday(date) { formatter.dateFormat = "'今天' HH:mm" }
        else if calendar.isDateInYesterday(date) { formatter.dateFormat = "'昨天' HH:mm" }
        else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else { formatter.dateFormat = "yyyy年M月d日 HH:mm" }
        return formatter.string(from: date)
    }
}
