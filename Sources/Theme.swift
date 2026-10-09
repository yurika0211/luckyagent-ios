import SwiftUI

enum Clover {
    static let bg = Color(hex: 0xF8F5EE)
    static let side = Color(hex: 0xF2EFE8)
    static let surface = Color(hex: 0xFFFCF7)
    static let user = Color(hex: 0xE8F0DE)
    static let line = Color(hex: 0xE5E0D8)
    static let text = Color(hex: 0x2B2925)
    static let text2 = Color(hex: 0x77736C)
    static let text3 = Color(hex: 0x918C84)
    static let accent = Color(hex: 0x356F42)
    static let leaf = Color(hex: 0x9DC74B)
    static let error = Color(hex: 0xB42318)
    static let warning = Color(hex: 0xB26A2D)
    static let codeBg = Color(hex: 0x1E2218)
    static let codeFg = Color(hex: 0xE8ECDC)
    static let tool = Color(hex: 0xF0F2EA)

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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(scheme == .dark ? Clover.darkSurface : Clover.surface)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(scheme == .dark ? Clover.darkLine : Clover.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
