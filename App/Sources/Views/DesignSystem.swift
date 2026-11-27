import SwiftUI
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
    static let messageRadius: CGFloat = 20

    static let rowTitle: Font = .body.weight(.semibold)
    static let metadata: Font = .footnote

    private static var spec: HMThemeSpec { HMTheme.spec }
    static var canvas: Color { spec.canvas }
    static var panel: Color { spec.panel }
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
    /// Readable caution text and symbols.
    static var caution: Color { spec.caution }
    /// Errors and destructive actions (finch beak red in Thermocline).
    static var danger: Color { spec.danger }
    static var plum: Color { spec.plum }
    static var bar: Color { spec.bar }
    static var selectedFill: Color { accent.opacity(0.16) }
    /// The outgoing message bubble: lead fill with on-lead text in Thermocline.
    static var bubbleFill: Color { HMTheme.isThermocline ? Thermocline.lead : selectedFill }
    static var bubbleText: Color { HMTheme.isThermocline ? Thermocline.onLead : ink }
    /// Counts and figures: mono with tabular digits in Thermocline, system tabular digits in Classic.
    static func number(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        HMTheme.isThermocline ? Thermocline.Font.mono(size, weight: weight, relativeTo: .footnote).monospacedDigit()
            : .system(size: size, weight: weight).monospacedDigit()
    }
}

/// One theme's color roles. Thermocline is the default; Classic is the system look with the amber AccentColor.
struct HMThemeSpec {
    var canvas, panel, raised, bar, separator, ink, text2, text3, accent, link, success, warning, caution, danger, plum: Color

    static let thermocline = HMThemeSpec(
        canvas: Thermocline.bg, panel: Thermocline.surface1, raised: Thermocline.surface2, bar: Thermocline.surface1,
        separator: Thermocline.line, ink: Thermocline.text, text2: Thermocline.text2, text3: Thermocline.text3,
        accent: Thermocline.lead, link: Thermocline.link, success: Thermocline.success, warning: Thermocline.spark,
        caution: Thermocline.warm, danger: Thermocline.danger, plum: Thermocline.plum)

    static let classic = HMThemeSpec(
        canvas: Color(uiColor: .systemGroupedBackground), panel: Color(uiColor: .secondarySystemGroupedBackground),
        raised: Color(uiColor: .tertiarySystemGroupedBackground), bar: Color(uiColor: .systemBackground),
        separator: Color(uiColor: .separator), ink: Color(uiColor: .label), text2: Color(uiColor: .secondaryLabel),
        text3: Color(uiColor: .tertiaryLabel), accent: Color.accentColor, link: Color(uiColor: .systemBlue),
        success: Color(uiColor: .systemGreen), warning: Color(uiColor: .systemOrange), caution: Color(uiColor: .systemOrange),
        danger: Color(uiColor: .systemRed), plum: Color(uiColor: .systemPurple))
}

enum HMThemeKind: String, CaseIterable, Identifiable {
    case thermocline, classic
    var id: String { rawValue }
    var title: String { self == .thermocline ? "Thermocline" : "Classic" }
    var detail: String { self == .thermocline ? "Teal on warm paper or deep ink, with glass" : "System backgrounds, amber accent" }
}

enum HMMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

/// The chosen theme and mode, stored in UserDefaults so they are set before the first frame.
enum HMTheme {
    static let themeKey = "appTheme", modeKey = "appMode"
    static var kind: HMThemeKind { HMThemeKind(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .thermocline }
    static var mode: HMMode { HMMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .system }
    static var isThermocline: Bool { kind == .thermocline }
    static var spec: HMThemeSpec { isThermocline ? .thermocline : .classic }

    /// Navigation and tab bars are UIKit: tint them for the theme. Called at launch and on every change.
    static func applyChrome() {
        let nav = UINavigationBarAppearance(), tab = UITabBarAppearance()
        if isThermocline {
            let tint = UIColor(Thermocline.bg).withAlphaComponent(0.7)
            nav.configureWithDefaultBackground(); nav.backgroundColor = tint
            nav.shadowColor = UIColor(Thermocline.line)
            nav.titleTextAttributes = [.foregroundColor: UIColor(Thermocline.text)]
            nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Thermocline.text)]
            tab.configureWithDefaultBackground(); tab.backgroundColor = tint
            tab.shadowColor = UIColor(Thermocline.line)
        } else {
            nav.configureWithDefaultBackground(); tab.configureWithDefaultBackground()
        }
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        if isThermocline { scrollEdge.titleTextAttributes = nav.titleTextAttributes; scrollEdge.largeTitleTextAttributes = nav.largeTitleTextAttributes }
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = isThermocline ? scrollEdge : nil
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

/// Thermocline's depth field: the canvas with two large soft blooms of lead and link.
struct HMDepthField: View {
    var body: some View {
        GeometryReader { geo in
            let r = max(geo.size.width, geo.size.height)
            ZStack {
                Thermocline.bg
                RadialGradient(colors: [Thermocline.lead.opacity(0.13), .clear], center: .topTrailing, startRadius: 0, endRadius: r * 0.75)
                RadialGradient(colors: [Thermocline.link.opacity(0.09), .clear], center: .bottomLeading, startRadius: 0, endRadius: r * 0.8)
            }
        }
        .ignoresSafeArea()
    }
}

/// A section header: Thermocline label (mono, uppercase, tertiary) or the plain system title in Classic.
struct HMHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        if HMTheme.isThermocline {
            Text(title).font(Thermocline.Font.label).tracking(1.3).textCase(.uppercase).foregroundStyle(Thermocline.text3)
        } else {
            Text(title)
        }
    }
}

/// Lateral-line divider between major sections (Thermocline only).
struct HMLateral: View {
    var body: some View {
        if HMTheme.isThermocline {
            LateralLine().frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
            FinchBars(progress: fraction, height: 8).frame(height: 8)
        } else {
            ProgressView(value: fraction).tint(tint)
        }
    }
}

enum HMBarEdge { case top, bottom, none }

private struct HMCanvas: ViewModifier {
    @AppStorage(HMTheme.themeKey) private var theme = HMThemeKind.thermocline.rawValue
    func body(content: Content) -> some View {
        if theme != HMThemeKind.classic.rawValue {
            content.scrollContentBackground(.hidden)
                .listRowSeparatorTint(Thermocline.line)
                .background(HMDepthField())
        } else {
            content
        }
    }
}

extension View {
    /// Rows of a list section sit on surface 1 in Thermocline; Classic keeps the system row color.
    func hmRows() -> some View {
        listRowBackground(HMTheme.isThermocline ? HMDesign.panel : Optional<Color>.none)
    }
    /// Composer, pinned bar and inbox header: system material with a hairline in Thermocline, the flat bar in Classic.
    @ViewBuilder func hmBar(_ edge: HMBarEdge) -> some View {
        if HMTheme.isThermocline {
            background(.regularMaterial)
                .overlay(alignment: edge == .top ? .top : .bottom) { if edge != .none { Rectangle().fill(Thermocline.line).frame(height: 0.5) } }
        } else {
            background(HMDesign.bar)
                .overlay(alignment: edge == .top ? .top : .bottom) { if edge != .none { Divider() } }
        }
    }
    /// A status tile or compact card: thin glass in Thermocline.
    @ViewBuilder func hmCard() -> some View {
        if HMTheme.isThermocline { padding(.vertical, 6).thermoclineGlass(radius: Thermocline.Radius.md, thin: true) } else { self }
    }
    /// A screen's background: the theme canvas behind lists and forms instead of the system's black or gray.
    func hmCanvas() -> some View {
        modifier(HMCanvas())
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
    var radius: CGFloat = Thermocline.Radius.full
    let flat: Color
    func body(content: Content) -> some View {
        if HMTheme.isThermocline {
            content.thermoclineGlass(radius: radius)
        } else if glass, #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(flat.opacity(0.25)).interactive(), in: shape)
        } else {
            content.background(flat, in: shape)
        }
    }
}

extension View {
    /// The message box and floating chips.
    func hmField(radius: CGFloat = HMDesign.messageRadius) -> some View {
        modifier(HMSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), radius: radius, flat: HMDesign.panel))
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
            if HMTheme.isThermocline {
                // Live dot: finch-beak red, slow pulse.
                Circle().fill(HMDesign.danger).frame(width: size * 0.5, height: size * 0.5)
                    .opacity(reduceMotion ? 1 : 0.65 + 0.35 * sin(t * 2.2))
                    .frame(width: size, height: size)
            } else {
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: [HMDesign.accent, HMDesign.accent.opacity(0.35), HMDesign.link.opacity(0.7),
                                                   HMDesign.accent], center: .center, angle: .degrees(t * 90)))
                    .blur(radius: size * 0.12)
                Circle()
                    .fill(RadialGradient(colors: [Thermocline.text.opacity(0.45), .clear], center: UnitPoint(x: 0.35 + 0.1 * sin(t * 1.3),
                                                                                                   y: 0.3 + 0.1 * cos(t * 1.1)),
                                         startRadius: 0, endRadius: size * 0.5))
            }
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1 : 1 + 0.06 * sin(t * 2.2))
            }
            
        }
        .accessibilityHidden(true)
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
                        withAnimation(Thermocline.Motion.large) { offset = 0; armed = false }
                    }
            )
    }
}
