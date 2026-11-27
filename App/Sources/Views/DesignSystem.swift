import SwiftUI
import UIKit

/// Shared values for the native SwiftUI surfaces. The accent comes from the app asset catalog.
enum HMDesign {
    static let micro: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let gutter: CGFloat = 16
    static let section: CGFloat = 24
    static let touch: CGFloat = 44

    static let panelRadius: CGFloat = 12
    static let messageRadius: CGFloat = 20

    static let rowTitle: Font = .body.weight(.semibold)
    static let metadata: Font = .footnote

    // Theme colors. Each resolves per light/dark trait from the chosen theme (see HMTheme).
    static var canvas: Color { HMTheme.color(\.canvas) }
    static var panel: Color { HMTheme.color(\.surface) }
    static var raised: Color { HMTheme.color(\.raised) }
    static var separator: Color { HMTheme.color(\.separator) }
    static var ink: Color { HMTheme.color(\.ink) }
    static var accent: Color { HMTheme.color(\.accent) }
    static var success: Color { HMTheme.color(\.success) }
    static var warning: Color { HMTheme.color(\.warning) }
    static var selectedFill: Color { accent.opacity(0.16) }
    /// The composer and inbox header: the canvas, slightly lifted, so it reads as a shelf, not a hole.
    static var bar: Color { HMTheme.color(\.bar) }
}

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
}

enum HMThemeChoice: String, CaseIterable, Identifiable {
    case system, ash, paper, oled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match iPhone"
        case .ash: "Ash"
        case .paper: "Paper"
        case .oled: "Black"
        }
    }
    var shortTitle: String { self == .system ? "Auto" : title }
    var detail: String {
        switch self {
        case .system: "Ash at night, Paper by day"
        case .ash: "Soft dark gray, easy on the eyes"
        case .paper: "Warm light"
        case .oled: "True black for OLED screens"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .ash, .oled: .dark
        case .paper: .light
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

/// The chosen theme, read by dynamic colors. Stored in UserDefaults so it is set before the first frame.
enum HMTheme {
    static let themeKey = "hm.theme", accentKey = "hm.accent"
    static var choice: HMThemeChoice { HMThemeChoice(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .system }
    static var accentChoice: HMAccent { HMAccent(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .theme }

    static func palette(dark: Bool) -> HMPalette {
        switch choice {
        case .system: dark ? .ash : .paper
        case .ash: .ash
        case .paper: .paper
        case .oled: .oled
        }
    }

    static func uiColor(_ key: KeyPath<HMPalette, UInt32>) -> UIColor {
        UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            if key == \HMPalette.accent, let pair = accentChoice.hex { return UIColor(hex: dark ? pair.1 : pair.0) }
            return UIColor(hex: palette(dark: dark)[keyPath: key])
        }
    }

    static func color(_ key: KeyPath<HMPalette, UInt32>) -> Color { Color(uiColor: uiColor(key)) }

    /// Navigation and tab bars are UIKit: give them the theme too. Called at launch and on every change.
    static func applyChrome() {
        if #available(iOS 26.0, *) {
            // iOS 26 draws glass bars, large titles and the soft scroll-edge blur itself. Any custom appearance
            // turns that blur off (text slid under the title) and an opaque one hid the large title. Leave it alone.
            return
        }
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiColor(\.canvas)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: uiColor(\.ink)]
        nav.largeTitleTextAttributes = [.foregroundColor: uiColor(\.ink)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = uiColor(\.bar)
        tab.shadowColor = uiColor(\.separator)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// A screen's background: the theme canvas behind lists and forms instead of the system's black or gray.
    func hmCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(HMDesign.canvas.ignoresSafeArea())
    }
}

extension View {
    /// Apply to a custom control's label so the full frame is interactive.
    func hmTouchTarget() -> some View {
        frame(minWidth: HMDesign.touch, minHeight: HMDesign.touch)
            .contentShape(Rectangle())
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

/// iOS 26 Liquid Glass where the person wants it (Settings > Appearance), the theme's flat colors otherwise.
private struct HMSurface<S: Shape>: ViewModifier {
    @AppStorage(HMGlass.key) private var glass = true
    let shape: S
    let flat: Color
    func body(content: Content) -> some View {
        if glass, #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(flat.opacity(0.25)).interactive(), in: shape)
        } else {
            content.background(flat, in: shape)
        }
    }
}

extension View {
    /// The message box and floating chips.
    func hmField(radius: CGFloat = HMDesign.messageRadius) -> some View {
        modifier(HMSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), flat: HMDesign.panel))
    }
    func hmCapsule() -> some View { modifier(HMSurface(shape: Capsule(), flat: HMDesign.panel)) }
}

// MARK: - Thinking orb

/// A small living orb for "Hermes is thinking": slow, soft, in the theme's accent. Respects Reduce Motion.
struct ThinkingOrb: View {
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [HMDesign.accent, HMDesign.accent.opacity(0.35), HMDesign.success.opacity(0.7),
                                                   HMDesign.accent], center: .center, angle: .degrees(t * 90)))
                    .blur(radius: size * 0.12)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: UnitPoint(x: 0.35 + 0.1 * sin(t * 1.3),
                                                                                                   y: 0.3 + 0.1 * cos(t * 1.1)),
                                         startRadius: 0, endRadius: size * 0.5))
            }
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1 : 1 + 0.06 * sin(t * 2.2))
            .shadow(color: HMDesign.accent.opacity(0.45), radius: size * 0.35)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Thinking indicators

/// How "Hermes is working" looks. Crisp pixels by default: they stay sharp at 16 pt, where a blurred orb smears.
enum ThinkingStyle: String, CaseIterable, Identifiable {
    case matrix, sprite, braille, orb
    static let key = "hm.thinking"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matrix: "Dot matrix"
        case .sprite: "Pixel flame"
        case .braille: "Terminal"
        case .orb: "Orb"
        }
    }
}

struct ThinkingIndicator: View {
    var size: CGFloat = 16
    @AppStorage(ThinkingStyle.key) private var raw = ThinkingStyle.matrix.rawValue
    var style: ThinkingStyle? = nil

    var body: some View {
        switch style ?? ThinkingStyle(rawValue: raw) ?? .matrix {
        case .matrix: DotMatrixLoader(size: size)
        case .sprite: PixelFlame(size: size + 4)
        case .braille: BrailleSpinner(size: size)
        case .orb: ThinkingOrb(size: size)
        }
    }
}

/// A 3×3 grid of square dots; a diagonal wave lights them in turn, like an LED panel thinking.
struct DotMatrixLoader: View {
    var size: CGFloat = 16
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
                        ctx.fill(Path(roundedRect: r, cornerRadius: dot * 0.22), with: .color(HMDesign.accent.opacity(lit)))
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
                        let color: Color = ch == "1" ? HMDesign.accent : ch == "2" ? Color(red: 1, green: 0.62, blue: 0.3) : Color(red: 1, green: 0.93, blue: 0.75)
                        ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px + 0.3, height: px + 0.3)), with: .color(color))
                    }
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The terminal spinner: braille frames in the monospaced font.
struct BrailleSpinner: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { context in
            let i = Int(context.date.timeIntervalSinceReferenceDate * 12) % Self.frames.count
            Text(String(Self.frames[reduceMotion ? 0 : i]))
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(HMDesign.accent)
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
                    .font(.callout).foregroundStyle(armed ? HMDesign.accent : .secondary)
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
                        withAnimation(.spring(duration: 0.3)) { offset = 0; armed = false }
                    }
            )
    }
}
