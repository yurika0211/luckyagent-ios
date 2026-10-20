import SwiftUI
import UIKit

@main
struct LuckyAgentApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var store = SettingsStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(store)
                .tint(Clover.accent)
                .preferredColorScheme(preferred)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.resumeConnection() }
                    if phase == .background { model.suspendConnection() }
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerPresented = false

    var body: some View {
        Group {
            if size == .regular {
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: 280)
                    Divider()
                    NavigationStack { content }
                }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        NavigationStack {
                            content
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button(action: openDrawer) {
                                            Image(systemName: "line.3.horizontal")
                                                .font(.system(size: 19, weight: .medium))
                                                .frame(width: 32, height: 36)
                                        }
                                        .accessibilityLabel("打开导航菜单")
                                    }
                                }
                        }
                        .allowsHitTesting(!drawerPresented)
                        .accessibilityHidden(drawerPresented)

                        if drawerPresented {
                            Button(action: closeDrawer) {
                                Color.black.opacity(scheme == .dark ? 0.48 : 0.24)
                            }
                            .buttonStyle(.plain)
                            .ignoresSafeArea()
                            .accessibilityHidden(true)
                            .transition(.opacity)

                            Sidebar(onNavigate: closeDrawer, onClose: closeDrawer)
                                .frame(width: min(max(geometry.size.width - 40, 0), 340))
                                .frame(maxHeight: .infinity)
                                .shadow(color: .black.opacity(0.12), radius: 24, x: 8, y: 0)
                                .transition(.move(edge: .leading))
                                .accessibilityAddTraits(.isModal)
                                .accessibilityAction(.escape, closeDrawer)
                        }
                    }
                }
            }
        }
        .background(scheme == .dark ? Clover.darkBg : Clover.bg)
        .overlay(alignment: .top) { banner }
        .onChange(of: size) { _, next in
            if next == .regular { drawerPresented = false }
        }
        .onChange(of: model.destination) { _, _ in closeDrawer() }
    }

    private func openDrawer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            drawerPresented = true
        }
    }

    private func closeDrawer() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            drawerPresented = false
        }
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
    var onNavigate: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 22)
            runtimeCard
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    destinationButton(.chat)
                    ForEach(groups, id: \.0) { name, destinations in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(scheme == .dark ? Clover.darkText2 : Clover.text2)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 5)
                            ForEach(destinations) { destination in
                                destinationButton(destination)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            Divider()
                .overlay(scheme == .dark ? Clover.darkLine : Clover.line)
                .padding(.horizontal, 20)
            destinationButton(.settings)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .background((scheme == .dark ? Clover.darkSide : Clover.side).ignoresSafeArea())
    }

    private var brand: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Clover.accent)
                ForEach(0..<4) { index in
                    Image(systemName: "leaf.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(45))
                        .offset(x: -6, y: -6)
                        .rotationEffect(.degrees(Double(index) * 90))
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("LuckyAgent")
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(scheme == .dark ? Clover.darkText : Clover.text)
                Text("本地客户端")
                    .font(.system(size: 12))
                    .foregroundStyle(scheme == .dark ? Clover.darkText2 : Clover.text2)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(scheme == .dark ? Clover.darkText2 : Clover.text2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭导航菜单")
            }
        }
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 12, weight: .medium))
                Text("电脑运行时")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle().fill(stateColor).frame(width: 5, height: 5)
                    Text(stateLabel)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(stateColor)
            }
            .foregroundStyle(scheme == .dark ? Clover.darkText2 : Clover.text2)
            Text(runtimeHost)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(scheme == .dark ? Clover.darkText : Clover.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(13)
        .background(scheme == .dark ? Clover.darkSurface : Clover.surface, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .combine)
    }

    private func destinationButton(_ destination: AppDestination) -> some View {
        let selected = model.destination == destination
        return Button {
            model.destination = destination
            onNavigate?()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                Text(destination.rawValue)
                    .font(.system(size: 15, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(width: 4, height: 18)
                }
            }
            .foregroundStyle(selected ? accent : (scheme == .dark ? Clover.darkText : Clover.text))
            .padding(.horizontal, 14)
            .frame(minHeight: 47)
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .background(selected ? accent.opacity(scheme == .dark ? 0.16 : 0.1) : .clear, in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var groups: [(String, [AppDestination])] {
        [
            ("运行与自动化", [.tasks, .background, .cron, .trace]),
            ("资源与连接", [.skills, .memory, .gateways])
        ]
    }

    private var accent: Color { scheme == .dark ? Clover.darkAccent : Clover.accent }

    private var runtimeHost: String {
        guard let components = URLComponents(string: model.settings.apiBase),
              let host = components.host, !host.isEmpty else { return "未配置地址" }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return components.port.map { "\(address):\($0)" } ?? address
    }

    private var stateLabel: String {
        switch model.socketState {
        case .idle, .closed: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .running: return "运行中"
        case .reconnecting: return "重连中"
        case .error: return "连接异常"
        }
    }

    private var stateColor: Color {
        switch model.socketState {
        case .connected, .running: return accent
        case .reconnecting, .connecting: return Clover.warning
        case .error: return Clover.error
        case .closed, .idle: return scheme == .dark ? Clover.darkText2 : Clover.text2
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
