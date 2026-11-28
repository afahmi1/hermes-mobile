import SwiftUI
import CoreMotion
#if canImport(ThinkingOrbs)
import ThinkingOrbs
#endif
import UIKit

/// Shared values for the native SwiftUI surfaces. Colors come from the active theme (see HMThemeSpec).
enum HMDesign {
    static let micro: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let gutter: CGFloat = 16
    static let section: CGFloat = 24
    static let touch: CGFloat = 44

    static var panelRadius: CGFloat { HMTheme.isThermocline ? Thermocline.Radius.md : 12 }
    /// Message bubbles and the message box: Thermocline's lg radius (18, continuous); Classic keeps 20.
    static var messageRadius: CGFloat { HMTheme.isThermocline ? Thermocline.Radius.lg : 20 }

    static let rowTitle: Font = .body.weight(.semibold)
    static let metadata: Font = .footnote
    /// Data lines (bot · source · model, schedules, paths, sizes): mono in Thermocline, footnote in Classic.
    static var data: Font { HMTheme.isThermocline ? HMType.meta : .footnote }

    private static var spec: HMThemeSpec { HMTheme.spec }
    static var canvas: Color { spec.canvas }
    static var panel: Color { spec.panel }
    /// List rows and cards. Thermocline lifts them off the canvas: surface-2 on paper, surface-1 on ink.
    static var card: Color { spec.card }
    static var raised: Color { spec.raised }
    static var separator: Color { spec.separator }
    static var ink: Color { spec.ink }
    static var text2: Color { spec.text2 }
    static var text3: Color { spec.text3 }
    static var accent: Color { spec.accent }
    static var link: Color { spec.link }
    static var success: Color { spec.success }
    /// Gold spark in Thermocline: once per screen, as a fill or symbol, never as text on light.
    static var warning: Color { spec.warning }
    /// Warning copy. Thermocline uses the finch-cheek warm (gold fails as text on paper); Classic keeps its amber.
    static var warningText: Color { HMTheme.isThermocline ? spec.caution : spec.warning }
    /// Readable caution text and symbols.
    static var caution: Color { spec.caution }
    /// In-between states: checking, starting, restarting.
    static var pending: Color { spec.pending }
    /// Errors and destructive actions (finch beak red in Thermocline). Dark-mode beak is for marks, not copy.
    static var danger: Color { spec.danger }
    /// Copy beside a danger mark: text in Thermocline (the mark carries the red), red in Classic.
    static var dangerText: Color { HMTheme.isThermocline ? spec.ink : spec.danger }
    static var plum: Color { spec.plum }
    static var bar: Color { spec.bar }
    static var selectedFill: Color { accent.opacity(0.16) }
    /// A solid accent surface with text on it (selected chips, prominent buttons): Thermocline's fill role (in
    /// Dark, Crown and Wing fill with Light's deep blue while `accent` is their lifted tint), Classic's accent.
    static var accentFill: Color { HMTheme.isThermocline ? HMTheme.thermoclineAccent.fill : spec.accent }
    /// The outgoing message bubble: the accent's fill with its on-fill text in Thermocline.
    static var bubbleFill: Color { HMTheme.isThermocline ? HMTheme.thermoclineAccent.fill : selectedFill }
    static var bubbleText: Color { HMTheme.isThermocline ? HMTheme.thermoclineAccent.onFill : ink }
    /// Shadows are tinted from the ink #13181D in both modes, never black.
    static let shadowInk = Color(uiColor: UIColor(Thermocline.text).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    /// Counts and figures: mono with tabular digits in Thermocline, system tabular digits in Classic. Scales with Dynamic Type.
    static func number(_ style: Font.TextStyle = .footnote, weight: Font.Weight = .regular) -> Font {
        HMTheme.isThermocline ? HMType.mono(style, weight: weight).monospacedDigit()
            : .system(style, weight: weight).monospacedDigit()
    }
}

/// Thermocline type that scales with Dynamic Type. JetBrains Mono when the app bundles it, SF Mono otherwise.
enum HMType {
    private static let jetBrains = Thermocline.Font.isRegistered("JetBrainsMono-Regular")

    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        if jetBrains {
            let size: CGFloat = switch style {
            case .caption2: 11
            case .caption: 12
            case .footnote: 13
            case .subheadline: 15
            case .callout: 16
            case .title3: 20
            case .title2: 22
            case .title: 28
            default: 17
            }
            return .custom(weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-Medium", size: size, relativeTo: style)
        }
        return .system(style, design: .monospaced, weight: weight)
    }
    /// 11 pt mono label. Use `.hmLabel()` for the full style: uppercase, 0.12 em tracking, text-3.
    static var label: Font { mono(.caption2, weight: .medium) }
    /// 12 pt mono for metadata and times.
    static var meta: Font { mono(.caption) }
    /// 13 pt mono for data and code.
    static var data: Font { mono(.footnote) }
}

extension View {
    /// Thermocline's label: mono 11, uppercase, 0.12 em tracking, text-3.
    func hmLabel(_ color: Color = Thermocline.text3) -> some View {
        font(HMType.label).tracking(1.3).textCase(.uppercase).foregroundStyle(color)
    }
}

/// One theme's color roles. Thermocline is the default; Classic is Build 31's look, palettes and accents intact.
struct HMThemeSpec {
    var canvas, panel, card, raised, bar, separator, ink, text2, text3, accent, link, success, warning, caution, pending, danger, plum: Color

    /// Thermocline cards on paper use surface-2: the approved glass renders at #F3F2EC there, well above surface-1.
    private static let thermoclineCard = Color(uiColor: UIColor { trait in
        UIColor(trait.userInterfaceStyle == .dark ? Thermocline.surface1 : Thermocline.surface2).resolvedColor(with: trait)
    })

    static var thermocline: HMThemeSpec {
        let accent = HMTheme.thermoclineAccent
        // `accent` is the tint role (text, icons, `.tint`, marks); fills go through `HMDesign.accentFill`.
        return HMThemeSpec(
            canvas: Thermocline.bg, panel: Thermocline.surface1, card: thermoclineCard, raised: Thermocline.surface2,
            bar: Thermocline.surface1, separator: Thermocline.line, ink: Thermocline.text, text2: Thermocline.text2,
            text3: Thermocline.text3, accent: accent.tint, link: Thermocline.link, success: Thermocline.success,
            warning: accent.spark, caution: Thermocline.warm, pending: Thermocline.warm, danger: Thermocline.danger,
            plum: Thermocline.plum)
    }

    /// Build 31's roles: the chosen palette (Paper, Ash, Black) for surfaces and accent, system colors elsewhere.
    static var classic: HMThemeSpec {
        if HMTheme.classicChoice == .native {
            return HMThemeSpec(canvas: Color(uiColor: .systemGroupedBackground), panel: Color(uiColor: .secondarySystemGroupedBackground),
                               card: Color(uiColor: .secondarySystemGroupedBackground), raised: Color(uiColor: .tertiarySystemGroupedBackground),
                               bar: Color(uiColor: .systemBackground), separator: Color(uiColor: .separator), ink: Color(uiColor: .label),
                               text2: Color(uiColor: .secondaryLabel), text3: Color(uiColor: .tertiaryLabel), accent: HMTheme.nativeAccent,
                               link: Color(uiColor: .systemBlue), success: .green, warning: .orange, caution: .orange, pending: .yellow,
                               danger: .red, plum: .purple)
        }
        return HMThemeSpec(
            canvas: HMTheme.classicColor(\.canvas), panel: HMTheme.classicColor(\.surface),
            card: Color(uiColor: .secondarySystemGroupedBackground), raised: HMTheme.classicColor(\.raised),
            bar: HMTheme.classicColor(\.bar), separator: Color(uiColor: .separator), ink: Color(uiColor: .label),
            text2: Color(uiColor: .secondaryLabel), text3: Color(uiColor: .tertiaryLabel), accent: HMTheme.classicColor(\.accent),
            link: Color(uiColor: .systemBlue), success: HMTheme.classicColor(\.success), warning: HMTheme.classicColor(\.warning),
            caution: Color(uiColor: .systemOrange), pending: Color(uiColor: .systemYellow), danger: Color(uiColor: .systemRed),
            plum: Color(uiColor: .systemPurple))
    }
}

enum HMThemeKind: String, CaseIterable, Identifiable {
    case thermocline, classic
    var id: String { rawValue }
    var title: String { self == .thermocline ? "Thermocline" : "Classic" }
    var detail: String { self == .thermocline ? "Teal on warm paper or true black" : "The earlier look: Paper, Ash or Black" }
}

enum HMMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Match iPhone" : rawValue.capitalized }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

// MARK: - Classic palettes (Build 31, unchanged)

/// One palette. Hex values are sRGB.
struct HMPalette {
    var canvas: UInt32, surface: UInt32, raised: UInt32, bar: UInt32, separator: UInt32
    var ink: UInt32, accent: UInt32, success: UInt32, warning: UInt32

    /// zayd.wtf's dark: ash gray, warm cream text, violet. No pure black, no neon.
    static let ash = HMPalette(canvas: 0x232322, surface: 0x2C2C2B, raised: 0x353533, bar: 0x282827, separator: 0x3E3D3A,
                               ink: 0xEDE6D3, accent: 0xA48CFF, success: 0x8FBF8A, warning: 0xE0B25E)
    /// zayd.wtf's light: paper, ink, its orange.
    static let paper = HMPalette(canvas: 0xF4EEDD, surface: 0xEAE2CC, raised: 0xFFFBF1, bar: 0xEFE8D4, separator: 0xD9CFB6,
                                 ink: 0x2E2C28, accent: 0xD9622B, success: 0x4F8A4C, warning: 0xB7791F)
    /// True black for OLED, with a calmer accent than the old neon orange.
    static let oled = HMPalette(canvas: 0x000000, surface: 0x141414, raised: 0x1C1C1E, bar: 0x0B0B0B, separator: 0x2A2A2A,
                                ink: 0xF2F2F2, accent: 0xF0A24B, success: 0x7FBF7A, warning: 0xE0B25E)
    /// Terminal phosphor: near-black green-gray, one green (after @craigweiss's dashboards).
    static let phosphor = HMPalette(canvas: 0x0A0B0A, surface: 0x141614, raised: 0x1B1E1B, bar: 0x0F110F, separator: 0x242824,
                                    ink: 0xE6E8E6, accent: 0x3EE59A, success: 0x3EE59A, warning: 0xE0C25E)
    /// Ballpoint on cream: the ink is the text and the accent (after @pankajstwt).
    static let ink = HMPalette(canvas: 0xEFE9DE, surface: 0xE6DFD2, raised: 0xF7F2E8, bar: 0xEAE3D6, separator: 0xD3CCC0,
                               ink: 0x2B3E9C, accent: 0x2B3E9C, success: 0x3F7A4A, warning: 0xA8701C)
}

/// Classic's looks. Each one carries its own mode, as it did before Thermocline.
enum HMThemeChoice: String, CaseIterable, Identifiable {
    case native, system, ash, paper, oled, phosphor, ink
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: "System (amber)"
        case .system: "Match iPhone"
        case .ash: "Ash"
        case .paper: "Paper"
        case .oled: "Black"
        case .phosphor: "Phosphor"
        case .ink: "Ink"
        }
    }
    var shortTitle: String { self == .system ? "Auto" : title }
    var detail: String {
        switch self {
        case .native: "System surfaces with the original amber"
        case .system: "Ash at night, Paper by day"
        case .ash: "Soft dark gray, easy on the eyes"
        case .paper: "Warm light"
        case .oled: "True black for OLED screens"
        case .phosphor: "Terminal green on near black"
        case .ink: "Blue ballpoint on cream"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .native, .system: nil
        case .ash, .oled, .phosphor: .dark
        case .paper, .ink: .light
        }
    }
}

enum HMAccent: String, CaseIterable, Identifiable {
    case theme, violet, amber, sage, sky, rose
    var id: String { rawValue }
    var title: String { self == .theme ? "Theme" : rawValue.capitalized }
    /// (light, dark) so the accent keeps contrast on both canvases.
    var hex: (UInt32, UInt32)? {
        switch self {
        case .theme: nil
        case .violet: (0x6B4FD8, 0xA48CFF)
        case .amber: (0xC4621F, 0xF0A24B)
        case .sage: (0x4F7F4B, 0x9CC796)
        case .sky: (0x2F6FB8, 0x7CB4F0)
        case .rose: (0xB8456B, 0xF08AAE)
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Theme state

/// The chosen theme and mode, stored in UserDefaults so they are set before the first frame.
enum HMTheme {
    static let themeKey = "appTheme", modeKey = "appMode"
    /// Classic's look and accent keep Build 31's keys, so a person's earlier choice comes back with Classic.
    static let classicKey = "hm.theme", accentKey = "hm.accent"
    /// Thermocline's accent lives in its own key; Crown is the default.
    static let thermoclineAccentKey = "appAccent"
    static var kind: HMThemeKind { HMThemeKind(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .thermocline }
    static var mode: HMMode { HMMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .system }
    static var classicChoice: HMThemeChoice { HMThemeChoice(rawValue: UserDefaults.standard.string(forKey: classicKey) ?? "") ?? .native }
    static var accentChoice: HMAccent { HMAccent(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .theme }
    static var thermoclineAccent: Thermocline.Accent { Thermocline.Accent(rawValue: UserDefaults.standard.string(forKey: thermoclineAccentKey) ?? "") ?? .crown }
    static var isThermocline: Bool { kind == .thermocline }
    static var spec: HMThemeSpec { isThermocline ? .thermocline : .classic }
    /// Thermocline follows Mode; each Classic look carries its own.
    static var scheme: ColorScheme? { isThermocline ? mode.scheme : classicChoice.scheme }

    static func palette(dark: Bool) -> HMPalette {
        switch classicChoice {
        case .native, .system: dark ? .ash : .paper
        case .ash: .ash
        case .paper: .paper
        case .oled: .oled
        case .phosphor: .phosphor
        case .ink: .ink
        }
    }

    static var nativeAccent: Color {
        guard let pair = accentChoice.hex else { return .accentColor }
        return Color(uiColor: UIColor { UIColor(hex: $0.userInterfaceStyle == .dark ? pair.1 : pair.0) })
    }

    static func classicUIColor(_ key: KeyPath<HMPalette, UInt32>) -> UIColor {
        UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            if key == \HMPalette.accent, let pair = accentChoice.hex { return UIColor(hex: dark ? pair.1 : pair.0) }
            return UIColor(hex: palette(dark: dark)[keyPath: key])
        }
    }

    static func classicColor(_ key: KeyPath<HMPalette, UInt32>) -> Color { Color(uiColor: classicUIColor(key)) }

    /// Navigation and tab bars are UIKit: give them the theme. Called at launch and on every change.
    static func applyChrome() {
        if isThermocline { thermoclineChrome() } else { classicChrome() }
    }

    /// Glass bars with a hairline, ink titles set semibold and tight, lead for the selected tab, text-3 for the rest.
    private static func thermoclineChrome() {
        let text = UIColor(Thermocline.text), quiet = UIColor(Thermocline.text3), lead = UIColor(HMTheme.thermoclineAccent.tint)
        let hairline = UIColor(Thermocline.line), tint = UIColor(Thermocline.bg).withAlphaComponent(0.55)
        let title = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        let large = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .systemFont(ofSize: 34, weight: .semibold))
        let titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: text, .font: title, .kern: -0.2]
        let largeAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: text, .font: large, .kern: -0.7]

        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.backgroundColor = tint
        nav.shadowColor = hairline
        nav.titleTextAttributes = titleAttributes
        nav.largeTitleTextAttributes = largeAttributes
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.titleTextAttributes = titleAttributes
        edge.largeTitleTextAttributes = largeAttributes
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = edge

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = tint
        tab.shadowColor = hairline
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = quiet
            item.normal.titleTextAttributes = [.foregroundColor: quiet]
            item.selected.iconColor = lead
            item.selected.titleTextAttributes = [.foregroundColor: lead]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().unselectedItemTintColor = quiet
        UISearchTextField.appearance().backgroundColor = UIColor(HMThemeSpec.thermocline.card)
    }

    /// Build 31's bars, exactly.
    private static func classicChrome() {
        let nav = UINavigationBarAppearance()
        if classicChoice == .native {
            nav.configureWithDefaultBackground()
        } else {
            nav.configureWithOpaqueBackground()
            nav.backgroundColor = classicUIColor(\.canvas)
            nav.shadowColor = .clear
            nav.titleTextAttributes = [.foregroundColor: classicUIColor(\.ink)]
            nav.largeTitleTextAttributes = [.foregroundColor: classicUIColor(\.ink)]
        }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = classicChoice == .native ? nil : nav
        let tab = UITabBarAppearance()
        if classicChoice == .native {
            tab.configureWithDefaultBackground()
        } else {
            tab.configureWithOpaqueBackground()
            tab.backgroundColor = classicUIColor(\.bar)
            tab.shadowColor = classicUIColor(\.separator)
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().unselectedItemTintColor = nil
        UISearchTextField.appearance().backgroundColor = nil
    }
}

/// Theme motion: Thermocline's curves (no bounce), Classic's springs. Nil under Reduce Motion, so nothing moves.
enum HMMotion {
    static var micro: Animation? { pick(Thermocline.Motion.micro, classic: .snappy) }
    static var standard: Animation? { pick(Thermocline.Motion.standard, classic: .snappy) }
    static var large: Animation? { pick(Thermocline.Motion.large, classic: .spring(duration: 0.3)) }

    static func pick(_ thermocline: Animation, classic: Animation) -> Animation? {
        if UIAccessibility.isReduceMotionEnabled { return nil }
        return HMTheme.isThermocline ? thermocline : classic
    }
}

// MARK: - Bot look

extension Bot {
    /// FNV-1a of the bot id: the one stable number behind both themes' bot colors.
    private static func hash(_ id: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }

    /// Classic: a hue per bot.
    static func color(for id: String) -> Color {
        Color(hue: Double(hash(id) % 360) / 360, saturation: 0.65, brightness: 0.46)
    }

    /// Thermocline's data series in its order: lead (Crown), link, success (Green), spark (Gold), secondary
    /// (Chestnut), plum, warm (Cheek), each its dynamic token. Deep in Light under paper ink #EBE7DE, bright in Dark
    /// under ink #13181D; every pair is at least 5.2:1 (contrast.md). Spark's own Light value, #AE6B00, measured
    /// 3.47:1 under #EBE7DE, and a lightness-only drop to 4.5:1 leaves the sRGB gamut, so the slot uses the Gold
    /// accent: #AE6B00 -> #875300, Thermocline's macaw gold already lowered for text (5.21:1). Link is the same
    /// pair as Crown now that Dark's blues follow Light's.
    static let thermoclineSeries: [Thermocline.Palette.Token] = [
        Thermocline.Accent.crown.tintToken, Thermocline.Palette.linkToken, Thermocline.Accent.green.tintToken,
        Thermocline.Accent.gold.tintToken, Thermocline.Accent.chestnut.tintToken, Thermocline.Accent.plum.tintToken,
        Thermocline.Accent.cheek.tintToken,
    ]

    /// Thermocline: Classic's hue for the bot (the same hash mod 360) cut into seven equal arcs, one per series
    /// color, so a bot keeps one color for good and the ids spread across the series.
    static func thermoclineColor(for id: String) -> Color {
        thermoclineSeries[Int(hash(id) % 360) * thermoclineSeries.count / 360].color
    }
}

struct BotAvatar: View {
    let id: String
    let name: String
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hmInsideGlow) private var insideGlow

    var body: some View {
        ZStack {
            if HMTheme.isThermocline {
                // A solid disc in the bot's series color with the initials in the measured ink. In Dark the disc,
                // never the initials, glows faintly in its own color.
                let fill = Bot.thermoclineColor(for: id)
                Circle().fill(fill).hmHalo(fill, active: scheme == .dark && !insideGlow)
                Circle().strokeBorder(Thermocline.lineStrong, lineWidth: 0.5)
                Text(initials).font(.system(size: size * 0.36, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(Thermocline.Palette.onAccentToken.color)
            } else {
                Circle().fill(Bot.color(for: id))
                Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let s = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "H" : s.uppercased()
    }
}

// MARK: - Canvas

/// Dark: the palette's black canvas, nothing painted on it; the glow lives on colored objects (`hmHalo`).
/// Light retains the two soft blooms and fine grain over paper. `animated` is kept for call sites; nothing moves.
struct HMDepthField: View {
    var animated = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                Thermocline.bg
            } else {
                GeometryReader { geo in
                    let r = max(geo.size.width, geo.size.height)
                    ZStack {
                        Thermocline.bg
                        RadialGradient(colors: [Thermocline.lead.opacity(0.05), .clear],
                                       center: .topTrailing, startRadius: 0, endRadius: r * 0.75)
                        RadialGradient(colors: [Thermocline.secondary.opacity(0.05), .clear],
                                       center: .bottomLeading, startRadius: 0, endRadius: r * 0.8)
                        Image(uiImage: HMGrain.tile).resizable(resizingMode: .tile)
                            .opacity(0.025)
                            .blendMode(.multiply)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Deep-sea glow

/// Thermocline Dark only: colored objects glow in their own color, like deep-sea creatures. That means bubbles,
/// primary and send buttons, selected chips and the Color orb (accent tint), plus bot avatars (their own fill).
/// Neutral cards and the canvas don't glow. Never on text or inside another glow.
enum HMGlow {
    /// Two layers, like a light source under water: a tight core that defines the edge, and a wide bloom.
    /// One 25% shadow (the old halo) disappeared on black, especially behind pale accents like Silver.
    static let coreOpacity = 0.55
    static let coreRadius: CGFloat = 5
    static let bloomOpacity = 0.38
    static let bloomRadius: CGFloat = 22
}

/// Silk silver as metal, not a grey. Metal is read from three things a flat gradient lacks:
/// 1. a reflection that moves when the phone tilts (CoreMotion; a slow drift where there's no motion sensor),
/// 2. a hard "horizon" in that reflection, bright sky over a darker ground band, the way chrome mirrors a room,
/// 3. brushed, anisotropic grain plus a sharp specular glint.
/// Colors measured from the silk black-silver Starry Night print (B02, 4032x3024): shadow #353438, midtone
/// #696D72, cool highlight #AFBCC3, warm peak #F3F1EA. Dark keeps text >= 4.5:1 on its darkest band with the
/// dark ink; Light is gunmetal under the light ink.
struct HMSilverSheen<S: Shape>: View {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var tilt = HMTilt.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || tilt.live)) { context in
            let drift = reduceMotion ? 0 : (tilt.live ? 0 : sin(context.date.timeIntervalSinceReferenceDate * 0.45) * 0.35)
            let x = CGFloat(tilt.live ? tilt.roll : drift)
            let y = CGFloat(tilt.live ? tilt.pitch : drift * 0.4)
            ZStack {
                // The reflected room: sky, a sharp horizon, then the floor. Moves with tilt.
                shape.fill(LinearGradient(stops: scheme == .dark ? HMChrome.dark : HMChrome.light,
                                          startPoint: UnitPoint(x: 0.5 + x * 0.5, y: -0.15 + y * 0.6),
                                          endPoint: UnitPoint(x: 0.5 - x * 0.5, y: 1.15 + y * 0.6)))
                // Brushed metal: horizontal streaks, light catching individual grooves.
                Image(uiImage: HMBrushed.tile).resizable(resizingMode: .tile)
                    .blendMode(scheme == .dark ? .overlay : .softLight)
                    .opacity(scheme == .dark ? 0.55 : 0.4)
                    .clipShape(shape)
                // Specular glint: a narrow hot streak that slides across opposite to the tilt.
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .white.opacity(scheme == .dark ? 0.85 : 0.35), location: 0.5),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(18, w * 0.16), height: geo.size.height * 4)
                        .rotationEffect(.degrees(18))
                        .frame(height: geo.size.height)
                        .offset(x: w * (0.5 - x * 0.9) - w * 0.08)
                        .blendMode(.plusLighter)
                }
                .clipShape(shape)
                // A cool rim on top and a warm one at the bottom: the edge of a stamped plate.
                shape.stroke(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.9 : 0.5),
                                                     Color(hex: 0xAFBCC3).opacity(0.2),
                                                     Color(hex: 0xF3F1EA).opacity(scheme == .dark ? 0.5 : 0.25)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .compositingGroup()
        }
        .onAppear { tilt.start() }
        .allowsHitTesting(false)
    }

}

enum HMChrome {
    static let dark: [Gradient.Stop] = [
        .init(color: Color(hex: 0xFFFFFF), location: 0.00),
        .init(color: Color(hex: 0xDCE6EB), location: 0.18),
        .init(color: Color(hex: 0xAFBCC3), location: 0.40),
        .init(color: Color(hex: 0xF3F1EA), location: 0.47),   // glare right above the horizon
        .init(color: Color(hex: 0x7E888F), location: 0.50),   // the horizon: a hard step down
        .init(color: Color(hex: 0x8F999F), location: 0.62),
        .init(color: Color(hex: 0xC4CDD2), location: 0.84),
        .init(color: Color(hex: 0xE9EEF0), location: 1.00),
    ]
    static let light: [Gradient.Stop] = [
        .init(color: Color(hex: 0x7A858C), location: 0.00),
        .init(color: Color(hex: 0x56606A), location: 0.30),
        .init(color: Color(hex: 0x8C979E), location: 0.46),
        .init(color: Color(hex: 0x2E3236), location: 0.50),
        .init(color: Color(hex: 0x3F454B), location: 0.66),
        .init(color: Color(hex: 0x666F76), location: 1.00),
    ]
}

/// Device tilt for the metal's reflection, shared by every metal surface. Device motion needs no permission.
final class HMTilt: ObservableObject {
    static let shared = HMTilt()
    @Published private(set) var roll = 0.0
    @Published private(set) var pitch = 0.0
    @Published private(set) var live = false
    private let motion = CMMotionManager()
    private var base: (Double, Double)?

    func start() {
        guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let a = m?.attitude else { return }
            // Relative to how the phone was first held, clamped to about +-35 degrees.
            if self.base == nil { self.base = (a.roll, a.pitch) }
            let b = self.base ?? (0, 0)
            let dr: Double = (a.roll - b.0) / 0.6
            let dp: Double = (a.pitch - b.1) / 0.6
            let r: Double = max(-1, min(1, dr))
            let p: Double = max(-1, min(1, dp))
            if abs(r - self.roll) > 0.004 || abs(p - self.pitch) > 0.004 { self.roll = r; self.pitch = p }
            if !self.live { self.live = true }
        }
    }
}

/// Brushed-metal grain: horizontal streaks of varying brightness, made once and deterministic.
enum HMBrushed {
    static let tile: UIImage = {
        let w = 256, h = 64
        var seed: UInt32 = 0x51_1C_E2
        func rnd() -> Double { seed = seed &* 1_664_525 &+ 1_013_904_223; return Double(seed >> 8) / Double(1 << 24) }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let row = rnd()                       // each groove has its own brightness
            var streak = rnd()
            for x in 0..<w {
                if x % 7 == 0 { streak = streak * 0.6 + rnd() * 0.4 }   // long, smooth along the stroke
                let lum: Double = 0.5 + (row - 0.5) * 0.55 + (streak - 0.5) * 0.35
                let v = UInt8(max(0.0, min(255.0, lum * 255.0)))
                let i = (y * w + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return UIImage(cgImage: ctx.makeImage()!, scale: 2, orientation: .up)
    }()
}

private extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

private extension Shape {
    func strokeBorderIfPossible<SS: ShapeStyle>(_ style: SS, lineWidth: CGFloat) -> some View {
        stroke(style, lineWidth: lineWidth).padding(lineWidth / 2)
    }
}

/// The halo color for an accent. Silver glows in its cool highlight, brighter than its fill, so it shows on black.
extension Thermocline.Accent {
    var haloColor: Color { self == .silver ? Color(hex: 0xCFE0E8) : tint }
}

private struct HMInsideGlowKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside an element that already glows, so nothing glows inside a glow.
    var hmInsideGlow: Bool {
        get { self[HMInsideGlowKey.self] }
        set { self[HMInsideGlowKey.self] = newValue }
    }
}

extension View {
    /// The halo: a shadow in `color` at 25%, radius 20, no offset. Apply it to a shape or fill, never to text.
    @ViewBuilder func hmHalo(_ color: Color, active: Bool) -> some View {
        if active {
            shadow(color: color.opacity(HMGlow.coreOpacity), radius: HMGlow.coreRadius)
                .shadow(color: color.opacity(HMGlow.bloomOpacity), radius: HMGlow.bloomRadius)
        } else { self }
    }



    /// The outgoing bubble's fill. Thermocline Dark adds the halo in the accent's tint behind it; Classic keeps
    /// its own fill exactly.
    @ViewBuilder func hmBubble<S: Shape>(_ shape: S) -> some View {
        if HMTheme.isThermocline {
            background { HMBubbleFill(shape: shape) }
        } else {
            background(HMDesign.bubbleFill, in: shape)
        }
    }
}

private struct HMBubbleFill<S: Shape>: View {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hmInsideGlow) private var insideGlow

    var body: some View {
        let accent = HMTheme.thermoclineAccent
        Group {
            if accent == .silver { HMSilverSheen(shape: shape) } else { shape.fill(HMDesign.bubbleFill) }
        }
        .hmHalo(accent.haloColor, active: scheme == .dark && !insideGlow)
    }
}

/// A 128 pt tile of fine monochrome noise, made once. Deterministic, so screenshots match run to run.
enum HMGrain {
    static let tile: UIImage = {
        let side = 128
        var seed: UInt32 = 0x7E2A_11C3
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = UInt8(truncatingIfNeeded: seed >> 24)
            pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        guard let provider,
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return UIImage() }
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()
}

/// A section header: Thermocline label (mono, uppercase, tertiary) or the plain system title in Classic.
/// `uppercase: false` keeps names that must not change case (URLs, paths) in the same mono label.
struct HMHeader: View {
    let title: String
    var uppercase = true
    init(_ title: String, uppercase: Bool = true) { self.title = title; self.uppercase = uppercase }
    var body: some View {
        if HMTheme.isThermocline {
            Text(title).font(HMType.label).tracking(uppercase ? 1.3 : 0.4).textCase(uppercase ? .uppercase : nil)
                .foregroundStyle(Thermocline.text3)
        } else if uppercase {
            Text(title)
        } else {
            Text(title).textCase(nil)
        }
    }
}

/// An error or validation line. Thermocline: the danger color on a mark, the words in text (dark-mode beak red is
/// 3.7:1 on a card, too low for copy). Classic: the words in red, as before.
struct HMProblemText: View {
    let text: String
    var systemImage = "exclamationmark.circle.fill"
    init(_ text: String, systemImage: String = "exclamationmark.circle.fill") { self.text = text; self.systemImage = systemImage }
    var body: some View {
        if HMTheme.isThermocline {
            Label { Text(text).foregroundStyle(Thermocline.text) } icon: {
                Image(systemName: systemImage).foregroundStyle(Thermocline.danger)
            }
            .labelStyle(HMTintedIconLabel(icon: Thermocline.danger))
        } else {
            Text(text).foregroundStyle(HMDesign.danger)
        }
    }
}

extension View {
    /// For a `Label` that reports a problem: Thermocline colors only its icon (danger) and keeps the words in
    /// `text`; Classic tints the whole label red, as before.
    @ViewBuilder func hmProblem(_ text: Color = Thermocline.text) -> some View {
        if HMTheme.isThermocline {
            labelStyle(HMTintedIconLabel(icon: Thermocline.danger)).foregroundStyle(text)
        } else {
            foregroundStyle(HMDesign.danger)
        }
    }
}

/// Lateral-line divider between major sections (Thermocline only).
struct HMLateral: View {
    var body: some View {
        if HMTheme.isThermocline {
            LateralLine().frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .accessibilityHidden(true)
        }
    }
}

/// Usage and progress bar: finch bars in Thermocline, the native bar in Classic.
struct HMBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        if HMTheme.isThermocline {
            HMFinchBars(progress: fraction, fill: tint)
        } else {
            ProgressView(value: fraction).tint(tint)
        }
    }
}

/// Thermocline's finch bars (2 pt on, 2 pt off, track text-3 at 35%) with a chosen fill. Same geometry as
/// the vendored `FinchBars`, drawn in one Canvas pass.
struct HMFinchBars: View {
    var progress: Double
    var fill: Color = Thermocline.lead
    var height: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            let n = max(Int(size.width / 4), 1)
            let filled = Int((Double(n) * min(max(progress, 0), 1)).rounded())
            for i in 0..<n {
                let bar = Path(CGRect(x: CGFloat(i) * 4, y: 0, width: 2, height: size.height))
                ctx.fill(bar, with: .color(i < filled ? fill : Thermocline.text3.opacity(0.35)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent"))
    }
}

enum HMBarEdge { case top, bottom, none }

private struct HMCanvas: ViewModifier {
    @AppStorage(HMTheme.themeKey) private var theme = HMThemeKind.thermocline.rawValue
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if theme != HMThemeKind.classic.rawValue && scheme == .dark {
            let canvas = content.scrollContentBackground(.hidden)
                .listRowSeparatorTint(Thermocline.line)
                .background(HMDepthField())
            if #available(iOS 26.0, *) {
                // Forcing an opaque navigation background on Liquid Glass hides the large title.
                // Its native scroll-edge treatment sits on the black canvas instead.
                canvas.toolbarBackground(Thermocline.bg, for: .tabBar, .bottomBar)
                    .toolbarBackground(.visible, for: .tabBar, .bottomBar)
            } else {
                canvas.toolbarBackground(Thermocline.bg, for: .navigationBar, .tabBar, .bottomBar)
                    .toolbarBackground(.visible, for: .navigationBar, .tabBar, .bottomBar)
            }
        } else if theme != HMThemeKind.classic.rawValue {
            content.scrollContentBackground(.hidden)
                .listRowSeparatorTint(Thermocline.line)
                .background(HMDepthField())
        } else if HMTheme.classicChoice == .native {
            content
        } else {
            content.scrollContentBackground(.hidden)
                .background(HMDesign.canvas.ignoresSafeArea())
        }
    }
}

extension View {
    /// Rows of a list section sit on the card color in Thermocline; Classic keeps the system row color.
    func hmRows(onCanvasInDark: Bool = false) -> some View {
        listRowBackground(HMTheme.isThermocline ? (onCanvasInDark ? Color.clear : HMDesign.card) : nil)
            .listRowSeparatorTint(HMTheme.isThermocline ? Thermocline.line : nil)
    }
    /// Full-width composer, pinned and selection bars use the canvas in Thermocline Dark, glass in Light.
    @ViewBuilder func hmBar(_ edge: HMBarEdge) -> some View {
        if HMTheme.isThermocline {
            background { HMGlassFill(shape: Rectangle(), flatDarkCanvas: true).ignoresSafeArea(edges: edge == .top ? .bottom : []) }
                .overlay(alignment: edge == .top ? .top : .bottom) { if edge != .none { Rectangle().fill(Thermocline.line).frame(height: 0.5) } }
        } else {
            background(HMDesign.bar)
                .overlay(alignment: edge == .top ? .top : .bottom) { if edge != .none { Divider() } }
        }
    }
    /// A status tile or compact card: glass straight on the depth field in Thermocline.
    @ViewBuilder func hmCard() -> some View {
        if HMTheme.isThermocline {
            padding(.vertical, 10).hmGlass(RoundedRectangle(cornerRadius: Thermocline.Radius.md, style: .continuous))
        } else { self }
    }
    /// A screen's background: the theme canvas behind lists and forms instead of the system's black or gray.
    func hmCanvas() -> some View {
        modifier(HMCanvas())
    }
    /// A card on the canvas or in the transcript: unlifted glass in Thermocline, the panel fill in Classic.
    @ViewBuilder func hmPanel(radius: CGFloat = 14, classicStyle: RoundedCornerStyle = .continuous) -> some View {
        if HMTheme.isThermocline {
            hmGlass(RoundedRectangle(cornerRadius: Thermocline.Radius.md, style: .continuous), lifted: false)
        } else {
            background(HMDesign.panel, in: RoundedRectangle(cornerRadius: radius, style: classicStyle))
        }
    }
    /// Message times and similar stamps: Thermocline's mono label in text-3; Classic keeps caption2 in `classic`.
    @ViewBuilder func hmTime(classic color: Color) -> some View {
        if HMTheme.isThermocline {
            font(HMType.label).tracking(0.6).foregroundStyle(Thermocline.text3)
        } else {
            font(.caption2).foregroundStyle(color)
        }
    }
    /// Thermocline glass in a shape: material tinted with surface-1, a hairline, a top highlight and a soft
    /// ink-tinted shadow. Reduce Transparency swaps it for solid surface-1. One glass layer at a time.
    func hmGlass<S: InsettableShape>(_ shape: S, lifted: Bool = true) -> some View {
        modifier(HMGlassModifier(shape: shape, lifted: lifted))
    }
}

/// The glass fill alone (no border), for full-width bars.
struct HMGlassFill<S: Shape>: View {
    let shape: S
    var flatDarkCanvas = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        if flatDarkCanvas && scheme == .dark {
            shape.fill(Thermocline.bg)
        } else if solid {
            shape.fill(Thermocline.surface1)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Thermocline.surface1.opacity(scheme == .dark ? 0.58 : 0.62))
            }
        }
    }
}

private struct HMGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let lifted: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        // Neutral glass doesn't glow; colored things inside it (avatars, buttons) still do.
        content
            .background { HMGlassFill(shape: shape) }
            .overlay {
                // Top highlight: a light inner edge that fades by mid-height, like the web glass's inset shadow.
                shape.inset(by: 0.5).stroke(LinearGradient(colors: [dark ? Thermocline.text.opacity(0.10) : Color.white.opacity(0.75), .clear],
                                                           startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .overlay { shape.strokeBorder(Thermocline.text.opacity(dark ? 0.12 : 0.09), lineWidth: 0.5) }
            .shadow(color: HMDesign.shadowInk.opacity(lifted ? (dark ? 0.45 : 0.07) : 0), radius: 2, y: 1)
            .shadow(color: HMDesign.shadowInk.opacity(lifted ? (dark ? 0.40 : 0.08) : 0), radius: 10, y: 6)
    }
}

extension View {
    /// Apply to a custom control's label so the full frame is interactive.
    func hmTouchTarget() -> some View {
        frame(minWidth: HMDesign.touch, minHeight: HMDesign.touch)
            .contentShape(Rectangle())
    }
}

/// A label whose icon takes its own color while the title keeps the text color.
struct HMTintedIconLabel: LabelStyle {
    let icon: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(icon)
            configuration.title
        }
    }
}

/// Title on the left, state or time on the right. Falls back to a stack when the two do not fit,
/// so identifying text keeps its width at large text sizes.
struct AdaptiveTitleRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: HMDesign.small) {
                leading
                Spacer(minLength: HMDesign.small)
                trailing
            }
            VStack(alignment: .leading, spacing: HMDesign.micro) {
                leading
                trailing
            }
        }
    }
}

// MARK: - Glass

enum HMGlass {
    static let key = "hm.glass"
}

/// Classic: iOS 26 Liquid Glass where the person wants it (Settings > Appearance), the theme's flat colors
/// otherwise. Thermocline: glass for floating chips, a surface-2 input with a strong hairline for the message box
/// (it already sits on the glass composer bar, and glass never stacks on glass).
private struct HMSurface<S: InsettableShape>: ViewModifier {
    @AppStorage(HMGlass.key) private var glass = true
    let shape: S
    let input: Bool
    let flat: Color
    func body(content: Content) -> some View {
        if HMTheme.isThermocline {
            if input {
                content.background(Thermocline.surface2.opacity(0.92), in: shape)
                    .overlay(shape.strokeBorder(Thermocline.lineStrong, lineWidth: 0.5))
            } else {
                content.hmGlass(shape)
            }
        } else if glass, #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(flat.opacity(0.25)).interactive(), in: shape)
        } else {
            content.background(flat, in: shape)
        }
    }
}

extension View {
    /// The message box.
    func hmField(radius: CGFloat = HMDesign.messageRadius) -> some View {
        modifier(HMSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), input: true, flat: HMDesign.panel))
    }
    /// Floating chips.
    func hmCapsule() -> some View { modifier(HMSurface(shape: Capsule(), input: false, flat: HMDesign.panel)) }

    /// Filter menus and similar chips. Thermocline: card fill with a strong hairline, tinted with the chosen accent
    /// while a filter is on. Classic: the system's tertiary fill.
    @ViewBuilder func hmChip(active: Bool = false) -> some View {
        if HMTheme.isThermocline {
            let tint = HMTheme.thermoclineAccent.tint
            foregroundStyle(active ? tint : Thermocline.text)
                .background(active ? tint.opacity(0.12) : HMDesign.card, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? tint.opacity(0.45) : Thermocline.lineStrong, lineWidth: 0.5))
        } else {
            background(Color(.tertiarySystemFill), in: Capsule())
        }
    }
}

/// A token-backed search field with native text input, focus and keyboard behavior.
struct HMSearchField: View {
    let prompt: String
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Thermocline.Radius.sm, style: .continuous)
        HStack(spacing: HMDesign.small) {
            Image(systemName: "magnifyingglass").foregroundStyle(Thermocline.text3).accessibilityHidden(true)
            TextField(prompt, text: $query, prompt: Text(prompt).foregroundStyle(Thermocline.text3))
                .foregroundStyle(Thermocline.text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { focused = false }
                .padding(.vertical, HMDesign.small)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Thermocline.text3).hmTouchTarget()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, HMDesign.medium)
        .padding(.trailing, query.isEmpty ? HMDesign.medium : 0)
        .frame(minHeight: HMDesign.touch)
        .background(Thermocline.surface2, in: shape)
        .overlay { shape.strokeBorder(focused ? HMTheme.thermoclineAccent.tint : Thermocline.line, lineWidth: focused ? 1 : 0.5).allowsHitTesting(false) }
    }
}

extension View {
    @ViewBuilder func hmSearchable(_ query: Binding<String>, prompt: String) -> some View {
        if HMTheme.isThermocline { self } else { searchable(text: query, prompt: prompt) }
    }
}

// MARK: - Badges, states and buttons

/// A status chip like the reference's LIVE chip: a colored mark, a mono uppercase label in text-2, a hairline
/// capsule. Color is never the only signal and never the text color (dark-mode beak red fails as copy).
struct HMStatusChip: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(HMType.label).tracking(0.9).textCase(.uppercase).foregroundStyle(Thermocline.text2).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Thermocline.lineStrong, lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small tag (Front door, NEW): Thermocline's chip, surface-3 with a mono label in text-2, radius 4.
struct HMTag: View {
    let text: String
    var body: some View {
        Text(text).font(HMType.label).tracking(0.9).textCase(.uppercase).foregroundStyle(Thermocline.text2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Thermocline.surface3, in: RoundedRectangle(cornerRadius: Thermocline.Radius.xs, style: .continuous))
            .fixedSize()
    }
}

/// Buttons for empty and error states. Primary: the accent's fill, its on-fill label, a soft glow behind the fill
/// (never on text): 25% in Light, the standard tint halo (25%, radius 20) in Dark. Quiet: a hairline capsule in text.
struct HMButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet }
    var kind: Kind = .quiet
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hmInsideGlow) private var insideGlow

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Thermocline.Radius.sm, style: .continuous)
        let accent = HMTheme.thermoclineAccent
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minHeight: HMDesign.touch)
            .foregroundStyle(kind == .primary ? accent.onFill : Thermocline.text)
            .background {
                if kind == .primary {
                    if scheme == .dark {
                        Group {
                            if accent == .silver { HMSilverSheen(shape: shape) } else { shape.fill(accent.fill) }
                        }
                        .hmHalo(accent.haloColor, active: enabled && !insideGlow)
                    } else {
                        Group {
                            if accent == .silver { HMSilverSheen(shape: shape) } else { shape.fill(accent.fill) }
                        }
                            .shadow(color: accent.tint.opacity(enabled ? 0.25 : 0), radius: 10)
                    }
                } else {
                    shape.fill(HMDesign.card.opacity(0.6))
                }
            }
            .overlay { if kind == .quiet { shape.strokeBorder(Thermocline.lineStrong, lineWidth: 0.5) } }
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .animation(HMMotion.micro, value: configuration.isPressed)
    }
}

/// Empty and error states. Thermocline: the Horizon-eye mark (first-run) or a quiet text-3 symbol, a title in
/// text, one line in text-2, then the action. Classic: the system's ContentUnavailableView.
struct HMUnavailable<Actions: View>: View {
    let title: String
    let symbol: String
    var message: String?
    /// The Horizon-eye mark instead of the symbol. Its spark dot counts as the screen's one gold element.
    var mark = false
    @ViewBuilder var actions: Actions

    var body: some View {
        if HMTheme.isThermocline {
            VStack(spacing: HMDesign.medium) {
                if mark {
                    HorizonEyeMark().frame(width: 58).padding(.bottom, HMDesign.micro).accessibilityHidden(true)
                } else {
                    Image(systemName: symbol).font(.system(.largeTitle, weight: .light)).foregroundStyle(Thermocline.text3)
                        .padding(.bottom, HMDesign.micro).accessibilityHidden(true)
                }
                Text(title).font(.title3.weight(.semibold)).tracking(-0.3).foregroundStyle(Thermocline.text)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(Thermocline.text2).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: HMDesign.small) { actions }.padding(.top, HMDesign.small)
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            .padding(.vertical, HMDesign.section)
            .accessibilityElement(children: .contain)
        } else {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                if let message { Text(message) }
            } actions: {
                actions
            }
        }
    }
}

extension HMUnavailable where Actions == EmptyView {
    init(title: String, symbol: String, message: String? = nil, mark: Bool = false) {
        self.init(title: title, symbol: symbol, message: message, mark: mark) { EmptyView() }
    }
}

/// What a Thermocline button style replaces in Classic.
enum HMClassicButton { case unchanged, bordered, prominent }

extension View {
    /// Thermocline buttons for empty and error states. Classic keeps its system style.
    @ViewBuilder func hmButton(_ kind: HMButtonStyle.Kind, classic: HMClassicButton = .unchanged) -> some View {
        if HMTheme.isThermocline {
            buttonStyle(HMButtonStyle(kind: kind))
        } else {
            switch classic {
            case .unchanged: self
            case .bordered: buttonStyle(.bordered)
            case .prominent: buttonStyle(.borderedProminent)
            }
        }
    }
    /// The one prominent action: Thermocline's primary button (the accent's fill with its on-fill label; white on a
    /// bright accent fails contrast), Classic's .borderedProminent.
    func hmProminent() -> some View { hmButton(.primary, classic: .prominent) }

    /// A system `.borderedProminent` button kept in both themes. Thermocline fills it with the accent's fill and
    /// sets the on-fill label; Classic keeps the system look on its accent.
    @ViewBuilder func hmSystemProminent() -> some View {
        if HMTheme.isThermocline {
            buttonStyle(.borderedProminent).tint(HMDesign.accentFill).foregroundStyle(HMDesign.bubbleText)
        } else {
            buttonStyle(.borderedProminent).tint(HMDesign.accent)
        }
    }
}

/// Thermocline's send button: the accent's fill with an on-fill arrow and a soft glow behind the disc (never on
/// text): 25% in Light, the standard tint halo (25%, radius 20) in Dark. Disabled: a surface-3 disc with a text-3 arrow.
struct HMSendGlyph: View {
    var enabled: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hmInsideGlow) private var insideGlow
    var body: some View {
        let accent = HMTheme.thermoclineAccent
        let dark = scheme == .dark
        Image(systemName: "arrow.up.circle.fill").font(.title)
            .symbolRenderingMode(.palette)
            .foregroundStyle(enabled ? accent.onFill : Thermocline.text3, enabled ? accent.fill : Thermocline.surface3)
            .shadow(color: accent.haloColor.opacity(enabled && !(dark && insideGlow) ? (dark ? HMGlow.coreOpacity : 0.25) : 0),
                    radius: dark ? HMGlow.coreRadius : 9)
            .shadow(color: accent.haloColor.opacity(enabled && dark && !insideGlow ? HMGlow.bloomOpacity : 0),
                    radius: HMGlow.bloomRadius)
    }
}

// MARK: - Thinking orb

/// The original colorful orb: a blurred spinning gradient with a moving highlight, slow breath and soft glow.
/// Thermocline uses the live accent; Classic keeps its original two colors and shadow.
struct ThinkingOrb: View {
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.thermoclineAccent) private var selection
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hmInsideGlow) private var insideGlow

    var body: some View {
        let thermocline = HMTheme.isThermocline
        let dark = thermocline && scheme == .dark
        let accent = thermocline ? selection.tint(for: scheme) : HMThemeSpec.classic.accent
        // The fill is the deep step for Crown/Wing. For tint-as-fill accents, lower the
        // stop's opacity instead, so it still reads as depth in the same hue.
        let depth = thermocline ? selection.fill(for: scheme) : HMThemeSpec.classic.success
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [accent, accent.opacity(0.35), depth.opacity(0.7), accent],
                                          center: .center, angle: .degrees(t * 90)))
                    .blur(radius: size * 0.12)
                    .hmHalo(accent, active: dark && !insideGlow)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.55), .clear],
                                         center: UnitPoint(x: 0.35 + 0.1 * sin(t * 1.3), y: 0.3 + 0.1 * cos(t * 1.1)),
                                         startRadius: 0, endRadius: size * 0.5))
            }
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1 : 1 + 0.06 * sin(t * 2.2))
            .shadow(color: dark ? .clear : accent.opacity(0.45), radius: size * 0.35)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Thinking indicators

/// How "Hermes is working" looks. Crisp pixels by default: they stay sharp at 16 pt, where a blurred orb smears.
enum ThinkingStyle: String, CaseIterable, Identifiable {
    case orbs, matrix, sprite, braille, orb, salmon, macaw
    static let key = "hm.thinking"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orbs: "Live orbs"
        case .matrix: "Dot matrix"
        case .sprite: "Pixel flame"
        case .braille: "Terminal"
        case .orb: "Color orb"
        case .salmon: "Salmon"
        case .macaw: "Macaw"
        }
    }
}

struct ThinkingIndicator: View {
    var size: CGFloat = 16
    @AppStorage(ThinkingStyle.key) private var raw = ThinkingStyle.orbs.rawValue
    @Environment(\.thermoclineAccent) private var selection
    @Environment(\.colorScheme) private var scheme
    var style: ThinkingStyle? = nil
    /// What Hermes is doing ("Using web_search…", "Thinking…", "Writing…"): live orbs change shape with it.
    var activity: String = ""

    var body: some View {
        let tint = HMTheme.isThermocline ? selection.tint(for: scheme) : nil
        switch style ?? ThinkingStyle(rawValue: raw) ?? .orbs {
        case .orbs: LiveOrb(size: size, activity: activity, tint: tint)
        case .matrix: DotMatrixLoader(size: size, tint: tint)
        case .sprite: PixelFlame(size: size + 4, tint: tint)
        case .braille: BrailleSpinner(size: size, tint: tint)
        case .orb: ThinkingOrb(size: size)
        case .salmon: PixelSprite(art: .salmon, size: size + 6, current: tint ?? HMDesign.accent, thermocline: tint != nil)
        case .macaw: PixelSprite(art: .macaw, size: size + 6, current: .clear, thermocline: tint != nil)
        }
    }
}

/// haplollc/ThinkingOrbs (MIT): a dotted 3D orb whose form says what Hermes is doing.
struct LiveOrb: View {
    var size: CGFloat
    var activity: String
    var tint: Color? = nil

    var body: some View {
        #if canImport(ThinkingOrbs)
        let design = Self.design(for: activity)
        let orb = ThinkingOrbs.ThinkingOrb(design, diameter: max(size + 4, 20))
        Group {
            if let tint {
                // The library has no ink parameter. Use its bright grayscale ramp and
                // multiply by the already resolved tint, preserving shading and alpha.
                orb.environment(\.colorScheme, .dark).colorMultiply(tint)
            } else {
                orb
            }
        }
        .id(design)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: design)
        #else
        DotMatrixLoader(size: size, tint: tint)
        #endif
    }

    #if canImport(ThinkingOrbs)
    static func design(for activity: String) -> OrbDesign {
        let a = activity.lowercased()
        if a.contains("search") || a.contains("extract") || a.contains("browse") || a.contains("web") || a.contains("read") { return .searching }
        if a.contains("delegat") || a.contains("subagent") || a.contains("plan") || a.contains("todo") { return .weaving }
        if a.contains("terminal") || a.contains("execute") || a.contains("mcp") || a.contains("call") || a.contains("using") { return .connecting }
        if a.contains("transcri") || a.contains("audio") || a.contains("voice") { return .listening }
        if a.contains("image") || a.contains("design") || a.contains("render") { return .shaping }
        if a.contains("writ") || a.contains("compos") || a.contains("reply") { return .composing }
        if a.contains("reason") || a.contains("solv") { return .solving }
        return .breathing
    }
    #endif
}

/// A 3×3 grid of square dots; a diagonal wave lights them in turn, like an LED panel thinking.
struct DotMatrixLoader: View {
    var size: CGFloat = 16
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, box in
                let cell = box.width / 3, dot = cell * 0.62
                for row in 0..<3 {
                    for col in 0..<3 {
                        let phase = (t * 2.4 - Double(row + col) * 0.45).truncatingRemainder(dividingBy: 2.4)
                        let lit = reduceMotion ? 0.7 : max(0.18, 1 - abs(phase - 0.6) * 1.1)
                        let r = CGRect(x: CGFloat(col) * cell + (cell - dot) / 2, y: CGFloat(row) * cell + (cell - dot) / 2,
                                       width: dot, height: dot)
                        ctx.fill(Path(roundedRect: r, cornerRadius: dot * 0.22), with: .color((tint ?? HMDesign.accent).opacity(lit)))
                    }
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// An 8×8 pixel-art flame (Prometheus's fire), four frames, nearest-neighbour crisp.
struct PixelFlame: View {
    var size: CGFloat = 20
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 0 empty, 1 outer (accent), 2 mid (warm), 3 core (light)
    private static let frames: [[String]] = [
        ["...1....", "...11...", "..1211..", "..12211.", ".122321.", ".1233321", ".1233321", "..11111."],
        ["....1...", "...11...", "..1121..", ".112211.", ".1232211", "1123321.", ".1233321", "..11111."],
        ["...1....", "..11....", "..1211..", ".11221..", ".122321.", "11233321", ".1233321", "..11111."],
        ["....1...", "...111..", "..1221..", "..12221.", ".1223321", ".1233321", "11233321", ".111111."],
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 8, paused: reduceMotion)) { context in
            let frame = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 8) % Self.frames.count
            Canvas { ctx, box in
                let px = box.width / 8
                for (y, line) in Self.frames[frame].enumerated() {
                    for (x, ch) in line.enumerated() where ch != "." {
                        let color = ink(ch)
                        ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px + 0.3, height: px + 0.3)), with: .color(color))
                    }
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    private func ink(_ level: Character) -> Color {
        if let tint { return tint.opacity(level == "1" ? 0.55 : level == "2" ? 0.8 : 1) }
        return level == "1" ? HMDesign.accent : level == "2" ? Color(red: 1, green: 0.62, blue: 0.3) : Color(red: 1, green: 0.93, blue: 0.75)
    }
}

/// The terminal spinner: braille frames in the monospaced font.
struct BrailleSpinner: View {
    var size: CGFloat = 16
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { context in
            let i = Int(context.date.timeIntervalSinceReferenceDate * 12) % Self.frames.count
            Text(String(Self.frames[reduceMotion ? 0 : i]))
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(tint ?? HMDesign.accent)
                .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// Status text with a soft light sweeping across it, so "Working…" reads as alive without a spinner shouting.
struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let x = reduceMotion ? 0.5 : (t * 0.6).truncatingRemainder(dividingBy: 1.6) - 0.3
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: x - 0.18), .init(color: HMDesign.ink.opacity(0.9), location: x),
                                           .init(color: .clear, location: x + 0.18)], startPoint: .leading, endPoint: .trailing)
                        .mask(Text(text).font(.footnote))
                }
        }
    }
}

// MARK: - Swipe to quote

/// Swipe a message right to quote it into the composer, like Telegram and iMessage. A haptic marks the
/// point where letting go counts. Vertical scrolling is untouched: only a clearly sideways drag moves it.
struct SwipeToQuote: ViewModifier {
    let onQuote: () -> Void
    @State private var offset: CGFloat = 0
    @State private var armed = false
    private let threshold: CGFloat = 56

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.callout).foregroundStyle(armed ? HMDesign.accent : HMDesign.text2)
                    .opacity(Double(min(offset / threshold, 1)))
                    .scaleEffect(armed ? 1.15 : 0.85)
                    .padding(.leading, 6)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { drag in
                        let dx = drag.translation.width, dy = drag.translation.height
                        guard dx > 0, dx > abs(dy) * 1.6 else { return }
                        offset = min(dx * 0.55, threshold + 14)
                        let now = offset >= threshold
                        if now != armed {
                            armed = now
                            if now { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                        }
                    }
                    .onEnded { _ in
                        if armed { onQuote() }
                        withAnimation(HMMotion.large) { offset = 0; armed = false }
                    }
            )
    }
}
