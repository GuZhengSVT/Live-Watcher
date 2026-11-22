import SwiftUI

enum Ink {
    static let pine = Color(red: 0.078, green: 0.173, blue: 0.145)
    static let paper = Color(red: 0.974, green: 0.973, blue: 0.950)
    static let mint = Color(red: 0.806, green: 0.920, blue: 0.760)
    static let soft = Color(red: 0.907, green: 0.927, blue: 0.875)
    static let muted = Color(red: 0.345, green: 0.403, blue: 0.355)
    static let line = pine.opacity(0.16)
}

private struct WatcherAppearanceKey: EnvironmentKey {
    static let defaultValue = Appearance()
}

extension EnvironmentValues {
    var watcherAppearance: Appearance {
        get { self[WatcherAppearanceKey.self] }
        set { self[WatcherAppearanceKey.self] = newValue }
    }
}

struct AppTheme {
    let page: Color
    let text: Color
    let secondary: Color
    let card: Color
    let line: Color
    let accent: Color
    let onAccent: Color

    init(palette: AppearancePalette, scheme: ColorScheme) {
        // Page, text, secondary text, card, border, accent, text on accent.
        let colors: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
        switch (palette, scheme) {
        case (.mint, .dark):   colors = (0x1B211E, 0xCDD6CF, 0xA3ADA6, 0x252D29, 0x39453E, 0x91AD9C, 0x18231C)
        case (.mint, _):       colors = (0xEFF4E8, 0x192E25, 0x506358, 0xFAFCF7, 0xD3DECD, 0x33664D, 0xFFFFFF)
        case (.white, .dark):  colors = (0x161719, 0xF7F7F7, 0xB2B3B7, 0x232426, 0x404146, 0xE8E8EA, 0x1D1E20)
        case (.white, _):      colors = (0xFFFFFF, 0x1B1C1F, 0x595D64, 0xF8F9FB, 0xE0E3E8, 0x3F4652, 0xFFFFFF)
        case (.black, .dark):  colors = (0x000000, 0xFFFFFF, 0xB5B5B5, 0x131313, 0x383838, 0xFFFFFF, 0x000000)
        case (.black, _):      colors = (0xF0F0F0, 0x0B0B0B, 0x565656, 0xFAFAFA, 0xD6D6D6, 0x151515, 0xFFFFFF)
        case (.claude, .dark): colors = (0x211E1B, 0xFAEEE0, 0xC4B5A5, 0x302823, 0x554438, 0xF0A682, 0x291B15)
        case (.claude, _):     colors = (0xF5EFE6, 0x332920, 0x6D5E52, 0xFFF9F1, 0xE2D5C8, 0xA34B30, 0xFFFFFF)
        case (.winter, .dark): colors = (0x1B2129, 0xCDD5DF, 0xA1ADBC, 0x252D38, 0x3A4655, 0x90A8BF, 0x19242F)
        case (.winter, _):     colors = (0xECF4FC, 0x162A45, 0x4C6180, 0xF9FCFF, 0xCFDFEE, 0x2A5C8B, 0xFFFFFF)
        }
        (page, text, secondary, card, line, accent, onAccent) = (
            Self.color(colors.0), Self.color(colors.1), Self.color(colors.2), Self.color(colors.3),
            Self.color(colors.4), Self.color(colors.5), Self.color(colors.6)
        )
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}

struct Aster: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        for i in 0..<8 {
            let leaf = Path(roundedRect: CGRect(x: -s * 0.086, y: -s * 0.49, width: s * 0.172, height: s * 0.42), cornerRadius: s * 0.08)
            let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: .pi * CGFloat(i) / 4)
            path.addPath(leaf, transform: transform)
        }
        return path
    }
}
