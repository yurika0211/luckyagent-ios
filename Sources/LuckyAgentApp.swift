import SwiftUI

@main
struct LuckyAgentApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var store = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(store)
                .tint(Clover.accent)
                .preferredColorScheme(preferred)
                .task { await model.bootstrap() }
        }
    }

    private var preferred: ColorScheme? {
        switch store.settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var size
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if size == .regular {
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: 280)
                    Divider()
                    content
                }
            } else {
                NavigationStack {
                    content
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Menu {
                                    Picker("页面", selection: $model.destination) {
                                        ForEach(AppDestination.allCases) { dest in
                                            Label(dest.rawValue, systemImage: dest.symbol).tag(dest)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "line.3.horizontal")
                                }
                            }
                        }
                }
            }
        }
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .overlay(alignment: .top) { banner }
    }

    @ViewBuilder private var content: some View {
        switch model.destination {
        case .chat: ChatView()
        case .tasks: TasksView()
        case .background: BackgroundView()
        case .cron: CronView()
        case .trace: TraceView()
        case .gateways: GatewaysView()
        case .skills: SkillsView()
        case .memory: MemoryView()
        case .settings: SettingsView()
        }
    }

    @ViewBuilder private var banner: some View {
        if let text = model.banner {
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .onTapGesture { model.banner = nil }
                .task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if model.banner == text { model.banner = nil }
                }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Clover.leaf).frame(width: 28, height: 28)
                    .overlay(Text("汐").font(.caption).foregroundStyle(Clover.leaf == Clover.leaf ? Color(hex: 0x172018) : .white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.personaName.isEmpty ? "LuckyAgent" : model.personaName).font(.headline)
                    Text(stateLabel).font(.caption).foregroundStyle(stateColor)
                }
                Spacer()
            }
            .padding(16)
            List(selection: $model.destination) {
                ForEach(groups, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items) { dest in
                            Label(dest.rawValue, systemImage: dest.symbol).tag(dest)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(scheme == .dark ? Clover.darkSide : Clover.side)
    }

    private var groups: [(String, [AppDestination])] {
        let order = ["WORKSPACE", "RUNTIME", "SYSTEM"]
        return order.map { name in (name, AppDestination.allCases.filter { $0.group == name }) }
    }

    private var stateLabel: String {
        switch model.socketState {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "在线"
        case .running: return "运行中"
        case .reconnecting: return model.statusNote.isEmpty ? "重连中" : model.statusNote
        case .closed: return "已断开"
        case .error: return "出错"
        }
    }

    private var stateColor: Color {
        switch model.socketState {
        case .connected, .running: return Clover.accent
        case .reconnecting, .connecting: return Clover.warning
        case .error, .closed, .idle: return Clover.error
        }
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoteText: View {
    var text: String
    var body: some View {
        if text.isEmpty { EmptyView() }
        else { Text(text).font(.footnote).foregroundStyle(Clover.error).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
