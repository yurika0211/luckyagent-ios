import SwiftUI

enum Clover {
    static let bg = Color(hex: 0xF4F5ED)
    static let side = Color(hex: 0xEEF2E5)
    static let surface = Color(hex: 0xFFFFFF)
    static let user = Color(hex: 0xE6EED8)
    static let line = Color(hex: 0xDFE5D7)
    static let text = Color(hex: 0x252B22)
    static let text2 = Color(hex: 0x727B6B)
    static let text3 = Color(hex: 0x89917F)
    static let accent = Color(hex: 0x43863B)
    static let leaf = Color(hex: 0x99BE53)
    static let error = Color(hex: 0xB42318)
    static let warning = Color(hex: 0xB26A2D)
    static let codeBg = Color(hex: 0x1E2218)
    static let codeFg = Color(hex: 0xE8ECDC)
    static let tool = Color(hex: 0xEDF2E5)

    static let darkBg = Color(hex: 0x171C18)
    static let darkSide = Color(hex: 0x121713)
    static let darkSurface = Color(hex: 0x202821)
    static let darkUser = Color(hex: 0x2D3B31)
    static let darkLine = Color(hex: 0x354239)
    static let darkText = Color(hex: 0xEAF0E9)
    static let darkText2 = Color(hex: 0xBAC7BC)
    static let darkAccent = Color(hex: 0xA9CA80)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

struct CloverBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Clover.darkBg : Clover.bg).ignoresSafeArea()
    }
}

extension View {
    func cloverCard() -> some View {
        modifier(CloverCard())
    }
}

private struct CloverCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Clover.darkSurface : Clover.surface)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(scheme == .dark ? Clover.darkLine : Clover.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

struct CloverIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .medium))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
            .background(configuration.isPressed ? (scheme == .dark ? Clover.darkUser : Clover.user) : .clear, in: Circle())
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct CloverActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? .white : (scheme == .dark ? Clover.darkAccent : Clover.accent))
            .background(prominent ? Clover.accent : (scheme == .dark ? Clover.darkUser : Clover.user), in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
