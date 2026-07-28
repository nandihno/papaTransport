import SwiftUI

struct ThemeSet {
    let light: ThemePalette
    let dark: ThemePalette

    func palette(for colorScheme: ColorScheme) -> ThemePalette {
        colorScheme == .dark ? dark : light
    }
}

struct ThemePalette {
    let backgroundBase: Color
    let backgroundTop: Color
    let surface: Color
    let surfaceRaised: Color
    let surfaceOverlay: Color
    let accent: Color
    let accentStrong: Color
    /// Accent tuned for *text*. `accent` and `accentStrong` are fill colours —
    /// they only reach 3:1 against the light surfaces, so they must not carry
    /// type. Use this for headings and any accented label.
    let accentText: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let buttonForeground: Color

    // Semantic status colours. These are per-scheme because a colour that reads
    // well on the near-black dark surfaces washes out completely on the cream
    // light ones — the light variants below are the darkest hues that still
    // clear 4.5:1 against both `surface` and `surfaceRaised`.
    let success: Color
    let warning: Color
    let danger: Color
    let info: Color

    let outline: Color
    let shadow: Color

    func color(for status: BusDepartureStatus) -> Color {
        switch status {
        case .onTime: success
        case .early: info
        case .late: warning
        case .noData: textSecondary
        case .skipped: danger
        }
    }

    var screenBackground: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBase],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var cardBackground: LinearGradient {
        LinearGradient(
            colors: [surfaceOverlay, surface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var cardBorder: LinearGradient {
        LinearGradient(
            colors: [accentStrong.opacity(0.24), outline],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var buttonBackground: LinearGradient {
        LinearGradient(
            colors: [accentStrong, accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var mutedPanelBackground: LinearGradient {
        LinearGradient(
            colors: [surfaceRaised, surface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AppTheme {
    static let transport = ThemeSet(
        light: ThemePalette(
            backgroundBase: Color(red: 0.988, green: 0.949, blue: 0.902),
            backgroundTop: Color(red: 0.976, green: 0.878, blue: 0.741),
            surface: Color(red: 0.992, green: 0.965, blue: 0.929),
            surfaceRaised: Color(red: 0.953, green: 0.871, blue: 0.784),
            surfaceOverlay: Color(red: 0.937, green: 0.808, blue: 0.675),
            accent: Color(red: 0.898, green: 0.431, blue: 0.000),
            accentStrong: Color(red: 1.000, green: 0.624, blue: 0.133),
            accentText: Color(red: 0.585, green: 0.254, blue: 0.000),
            textPrimary: Color(red: 0.220, green: 0.122, blue: 0.055),
            textSecondary: Color(red: 0.420, green: 0.259, blue: 0.141),
            textTertiary: Color(red: 0.588, green: 0.420, blue: 0.286),
            buttonForeground: Color.white.opacity(0.97),
            success: Color(red: 0.057, green: 0.410, blue: 0.175),
            warning: Color(red: 0.540, green: 0.288, blue: 0.000),
            danger: Color(red: 0.700, green: 0.105, blue: 0.014),
            info: Color(red: 0.000, green: 0.347, blue: 0.695),
            outline: Color.black.opacity(0.10),
            shadow: Color.black.opacity(0.10)
        ),
        dark: ThemePalette(
            backgroundBase: Color(red: 0.106, green: 0.055, blue: 0.027),
            backgroundTop: Color(red: 0.176, green: 0.082, blue: 0.031),
            surface: Color(red: 0.161, green: 0.078, blue: 0.031),
            surfaceRaised: Color(red: 0.216, green: 0.102, blue: 0.039),
            surfaceOverlay: Color(red: 0.275, green: 0.133, blue: 0.047),
            accent: Color(red: 1.000, green: 0.541, blue: 0.000),
            accentStrong: Color(red: 1.000, green: 0.663, blue: 0.180),
            accentText: Color(red: 1.000, green: 0.663, blue: 0.180),
            textPrimary: Color(red: 1.000, green: 0.949, blue: 0.890),
            textSecondary: Color(red: 0.906, green: 0.702, blue: 0.541),
            textTertiary: Color(red: 0.725, green: 0.557, blue: 0.431),
            buttonForeground: Color.black.opacity(0.82),
            success: Color(red: 0.314, green: 0.839, blue: 0.506),
            warning: Color(red: 1.000, green: 0.741, blue: 0.322),
            danger: Color(red: 1.000, green: 0.450, blue: 0.360),
            info: Color(red: 0.420, green: 0.760, blue: 1.000),
            outline: Color.white.opacity(0.08),
            shadow: Color.black.opacity(0.34)
        )
    )
}

// MARK: - Type scale

extension Font {
    /// Semantic type scale. Every role is built on a `TextStyle` so it responds
    /// to Dynamic Type; the rounded design is baked in so a role stays correct
    /// regardless of any ancestor `fontDesign` modifier.
    static let transitDisplay = Font.system(.title, design: .rounded, weight: .heavy)
    static let transitTitle = Font.system(.title2, design: .rounded, weight: .heavy)
    static let transitHeadline = Font.system(.title3, design: .rounded, weight: .bold)
    static let transitBody = Font.system(.subheadline, design: .rounded, weight: .semibold)
    static let transitLabel = Font.system(.footnote, design: .rounded, weight: .semibold)
    static let transitCaption = Font.system(.caption, design: .rounded, weight: .regular)
    static let transitBadge = Font.system(.caption2, design: .rounded, weight: .bold)
}

extension Int {
    /// Returns a display-friendly duration tuple.
    /// < 60 min  →  ("23", "min")
    /// ≥ 60 min  →  ("1h", "30m")  or  ("2h", "") for exact hours
    var durationComponents: (value: String, unit: String) {
        guard self >= 60 else { return ("\(self)", "min") }
        let hours = self / 60
        let remaining = self % 60
        return remaining == 0 ? ("\(hours)h", "") : ("\(hours)h", "\(remaining)m")
    }
}

struct TransitPrimaryButtonStyle: ButtonStyle {
    @Environment(\.themePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.transitHeadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(palette.buttonBackground)
            .foregroundStyle(palette.buttonForeground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.accentStrong.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: palette.accent.opacity(0.28), radius: 16, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct TransitCardModifier: ViewModifier {
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            }
            .shadow(color: palette.shadow, radius: 22, y: 10)
    }
}

private struct TransitScreenModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let theme: ThemeSet

    private var palette: ThemePalette {
        theme.palette(for: colorScheme)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.themePalette, palette)
            .foregroundStyle(palette.textPrimary)
            .tint(palette.accent)
            .background(palette.screenBackground.ignoresSafeArea())
            .toolbarBackground(palette.backgroundBase, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = AppTheme.transport.light
}

extension EnvironmentValues {
    var themePalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

extension View {
    func transitCardStyle() -> some View {
        modifier(TransitCardModifier())
    }

    func transitScreenStyle() -> some View {
        modifier(TransitScreenModifier(theme: AppTheme.transport))
    }

    func screenTheme(_ theme: ThemeSet) -> some View {
        modifier(TransitScreenModifier(theme: theme))
    }
}
