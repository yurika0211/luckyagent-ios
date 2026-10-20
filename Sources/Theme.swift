import SwiftUI

enum Clover {
    // luckyagent-android Color.kt, revision 678c0a0 (see docs/ANDROID_UI_REFERENCE.md).
    static let bg = Color(hex: 0xF9FAF4)
    static let side = Color(hex: 0xEEF1E5)
    static let surface = Color(hex: 0xFFFFFF)
    static let user = Color(hex: 0xE9EFD9)
    static let line = Color(hex: 0xE0E5D2)
    static let text = Color(hex: 0x161811)
    static let text2 = Color(hex: 0x565A4B)
    static let text3 = Color(hex: 0x737866)
    static let accent = Color(hex: 0x3F8A37)
    static let leaf = Color(hex: 0x9DC74B)
    static let error = Color(hex: 0xBF4D4D)
    static let warning = Color(hex: 0xB0762A)
    static let codeBg = Color(hex: 0x1E211A)
    static let codeFg = Color(hex: 0xE8EBDC)
    static let tool = Color(hex: 0xF0F3E7)

    static let darkBg = Color(hex: 0x23241F)
    static let darkSide = Color(hex: 0x1C1D19)
    static let darkSurface = Color(hex: 0x2D2F28)
    static let darkUser = Color(hex: 0x32352C)
    static let darkLine = Color(hex: 0x3A3D33)
    static let darkText = Color(hex: 0xECEFDF)
    static let darkText2 = Color(hex: 0xB0B4A2)
    static let darkAccent = Color(hex: 0x9FCE53)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Clover.darkSurface : Clover.surface)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke((scheme == .dark ? Clover.darkLine : Clover.line).opacity(0.35), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
