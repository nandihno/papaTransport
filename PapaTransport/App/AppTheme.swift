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
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let buttonForeground: Color

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
            colors: [accentStrong.opacity(0.24), AppTheme.outline],
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
    static let outline = Color.white.opacity(0.08)
    static let shadow = Color.black.opacity(0.34)

    static let success = Color(red: 0.314, green: 0.839, blue: 0.506)
    static let warning = Color(red: 1.000, green: 0.741, blue: 0.322)
    static let danger = Color(red: 1.000, green: 0.450, blue: 0.360)
    static let info = Color(red: 0.420, green: 0.760, blue: 1.000)

    static let transport = ThemeSet(
        light: ThemePalette(
            backgroundBase: Color(red: 0.988, green: 0.949, blue: 0.902),
            backgroundTop: Color(red: 0.976, green: 0.878, blue: 0.741),
            surface: Color(red: 0.992, green: 0.965, blue: 0.929),
            surfaceRaised: Color(red: 0.953, green: 0.871, blue: 0.784),
            surfaceOverlay: Color(red: 0.937, green: 0.808, blue: 0.675),
            accent: Color(red: 0.898, green: 0.431, blue: 0.000),
            accentStrong: Color(red: 1.000, green: 0.624, blue: 0.133),
            textPrimary: Color(red: 0.220, green: 0.122, blue: 0.055),
            textSecondary: Color(red: 0.420, green: 0.259, blue: 0.141),
            textTertiary: Color(red: 0.588, green: 0.420, blue: 0.286),
            buttonForeground: Color.white.opacity(0.97)
        ),
        dark: ThemePalette(
        backgroundBase: Color(red: 0.106, green: 0.055, blue: 0.027),
        backgroundTop: Color(red: 0.176, green: 0.082, blue: 0.031),
        surface: Color(red: 0.161, green: 0.078, blue: 0.031),
        surfaceRaised: Color(red: 0.216, green: 0.102, blue: 0.039),
        surfaceOverlay: Color(red: 0.275, green: 0.133, blue: 0.047),
        accent: Color(red: 1.000, green: 0.541, blue: 0.000),
        accentStrong: Color(red: 1.000, green: 0.663, blue: 0.180),
        textPrimary: Color(red: 1.000, green: 0.949, blue: 0.890),
        textSecondary: Color(red: 0.906, green: 0.702, blue: 0.541),
        textTertiary: Color(red: 0.725, green: 0.557, blue: 0.431),
        buttonForeground: Color.black.opacity(0.82)
        )
    )

    static let weather = ThemeSet(
        light: ThemePalette(
            backgroundBase: Color(red: 0.929, green: 0.973, blue: 1.000),
            backgroundTop: Color(red: 0.741, green: 0.906, blue: 1.000),
            surface: Color(red: 0.902, green: 0.957, blue: 1.000),
            surfaceRaised: Color(red: 0.773, green: 0.894, blue: 0.980),
            surfaceOverlay: Color(red: 0.655, green: 0.851, blue: 0.965),
            accent: Color(red: 0.145, green: 0.573, blue: 0.937),
            accentStrong: Color(red: 0.420, green: 0.792, blue: 1.000),
            textPrimary: Color(red: 0.055, green: 0.220, blue: 0.369),
            textSecondary: Color(red: 0.176, green: 0.365, blue: 0.541),
            textTertiary: Color(red: 0.345, green: 0.529, blue: 0.694),
            buttonForeground: Color.white.opacity(0.97)
        ),
        dark: ThemePalette(
        backgroundBase: Color(red: 0.031, green: 0.118, blue: 0.235),
        backgroundTop: Color(red: 0.082, green: 0.267, blue: 0.451),
        surface: Color(red: 0.071, green: 0.208, blue: 0.357),
        surfaceRaised: Color(red: 0.110, green: 0.286, blue: 0.463),
        surfaceOverlay: Color(red: 0.149, green: 0.365, blue: 0.561),
        accent: Color(red: 0.420, green: 0.792, blue: 1.000),
        accentStrong: Color(red: 0.675, green: 0.894, blue: 1.000),
        textPrimary: Color(red: 0.937, green: 0.980, blue: 1.000),
        textSecondary: Color(red: 0.698, green: 0.835, blue: 0.949),
        textTertiary: Color(red: 0.514, green: 0.698, blue: 0.824),
        buttonForeground: Color(red: 0.027, green: 0.149, blue: 0.286)
        )
    )

    static let health = ThemeSet(
        light: ThemePalette(
            backgroundBase: Color(red: 1.000, green: 0.949, blue: 0.953),
            backgroundTop: Color(red: 1.000, green: 0.820, blue: 0.835),
            surface: Color(red: 1.000, green: 0.929, blue: 0.937),
            surfaceRaised: Color(red: 0.980, green: 0.796, blue: 0.820),
            surfaceOverlay: Color(red: 0.953, green: 0.655, blue: 0.694),
            accent: Color(red: 0.851, green: 0.200, blue: 0.235),
            accentStrong: Color(red: 1.000, green: 0.353, blue: 0.322),
            textPrimary: Color(red: 0.369, green: 0.071, blue: 0.114),
            textSecondary: Color(red: 0.549, green: 0.176, blue: 0.224),
            textTertiary: Color(red: 0.682, green: 0.333, blue: 0.380),
            buttonForeground: Color.white.opacity(0.97)
        ),
        dark: ThemePalette(
        backgroundBase: Color(red: 0.149, green: 0.027, blue: 0.051),
        backgroundTop: Color(red: 0.267, green: 0.043, blue: 0.082),
        surface: Color(red: 0.235, green: 0.051, blue: 0.086),
        surfaceRaised: Color(red: 0.333, green: 0.071, blue: 0.118),
        surfaceOverlay: Color(red: 0.427, green: 0.102, blue: 0.165),
        accent: Color(red: 1.000, green: 0.353, blue: 0.322),
        accentStrong: Color(red: 1.000, green: 0.569, blue: 0.529),
        textPrimary: Color(red: 1.000, green: 0.941, blue: 0.941),
        textSecondary: Color(red: 0.961, green: 0.733, blue: 0.741),
        textTertiary: Color(red: 0.761, green: 0.502, blue: 0.510),
        buttonForeground: Color.white.opacity(0.96)
        )
    )
}

extension Font {
    static func transit(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct TransitPrimaryButtonStyle: ButtonStyle {
    @Environment(\.themePalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.transit(18, weight: .bold))
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
            .shadow(color: AppTheme.shadow, radius: 22, y: 10)
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
