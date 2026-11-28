---
name: Prometheus
description: Native iPhone remote for Hermes Agent. Thermocline v1.0, with a Classic option.
colors:
  bg-light: "#E4E0D7"
  bg-dark: "#000000"
  surface1-light: "#EEEAE1"
  surface1-dark: "#151515"
  surface2-light: "#F5F1E7"
  surface2-dark: "#222222"
  surface3-light: "#DCD8CF"
  surface3-dark: "#2D2D2D"
  text-light: "#13181D"
  text-dark: "#EBE7DE"
  text2-light: "#474047"
  text2-dark: "#B5AEA5"
  text3-light: "#645C64"
  text3-dark: "#9D959D"
  lead-light: "#186377"
  lead-dark: "#5FA4B9"
  link-light: "#186377"
  link-dark: "#5FA4B9"
  silver-light: "#526162"
  silver-dark: "#ABBBBC"
  spark-light: "#AE6B00"
  spark-dark: "#F4B21F"
  danger-light: "#CE0A04"
  danger-dark: "#E62F10"
  success-light: "#4B6801"
  success-dark: "#A3C54F"
  classic-accent-light: "#8e5200"
  classic-accent-dark: "#f5b942"
rounded:
  panel: "12px"
  message: "18px"
spacing:
  micro: "4px"
  small: "8px"
  medium: "12px"
  gutter: "16px"
  section: "24px"
  touch: "44px"
---

## Visual system

Prometheus uses Thermocline over native SwiftUI navigation, lists, forms, and keyboard behavior. The reference is Thermocline's `examples/preview-b2.html`. Finch paper is warm stone with deep wing-blue controls; Dark uses a true OLED-black canvas, neutral elevated surfaces and a lifted deep-wing-blue tint. Ash remains an optional Dark canvas. Both are first-class modes. `App/Sources/Views/Thermocline.swift` is vendored from afahmi1/thermocline. Do not edit those values. `DesignSystem.swift` maps the tokens to app roles.

Settings > Appearance shows theme previews and applies the selection live. Thermocline is the default (`appTheme`). Its Mode is Match iPhone, Light or Dark (`appMode`). Choose an accent (`appAccent`) from labeled swatches, including Silver. Thinking indicators follow that tint in Thermocline. Classic defaults to adaptive system surfaces and the original amber `AccentColor`; the previous Paper, Ash, Black, Match iPhone and accent choices remain available under Classic with their prior preferences, including the Liquid Glass toggle.

## Materials and type

- Light uses a five-percent lead bloom and a five-percent chestnut bloom over paper, with fine grain. Dark leaves the OLED canvas untinted by bloom, wash or grain. Dark object halos are 25% at radius 20 pt with no offset: bubbles, filled buttons, selected chips and the Color orb use the accent tint; bot discs use their own fill. Never glow a neutral card, text or a descendant of a haloed shape.
- Use surface-2 rows on paper and surface-1 grouped rows on black, with hairline separators. Plain inbox rows leave the dark canvas exposed. Glass belongs on bounded controls and cards; use one layer of material with a surface tint, an ink hairline and a restrained edge highlight. Reduce Transparency replaces the material with solid surface-1. Do not put glass on glass, glow on text, or use black drop shadows in light mode.
- Navigation retains native large titles with semibold weight and tight tracking. Section headers are uppercase 11 pt mono labels with 1.3 pt tracking in text-3. Metadata, code, and tabular figures use SF Mono (JetBrains Mono if registered); body type stays SF Pro. Let controls and summaries stack at accessibility sizes instead of compressing their contents.
- Pair the selected accent’s `fill` with its `onFill` ink for solid controls and bubbles, and use `tint` for foreground and focus. Use `link` for links, `success` and `danger` for state marks, and text or `warm` for warning copy. Beak red is a mark, not body copy. Gold is never body copy: reserve one `spark` fill or symbol per screen, such as the Horizon-eye dot or a single usage warning. Do not use color as the only state signal.

## Screens

- Chats: a surface search field with a hairline and a lead focus ring; filter chips use the same palette with a lead tint when filtering. Titles lead the grouped rows, followed by the preview, quiet initials, mono details and pin state. First-run uses the Horizon-eye; errors offer a quiet bordered retry.
- Transcript: assistant copy stays unboxed. Outgoing messages use 18 pt continuous corners and opaque lead fill. Code sits in a surface-3 well with a surface-1 header. Pinned and composer bars use the canvas in Dark and restrained glass in Light, with a hairline. The composer field is solid so it doesn't stack glass; the send arrow is on-lead with a soft glow on its disc. A beak-colored dot accompanies the live label.
- Status: the overview tiles float independently over the canvas. Use mono numbers, labeled success or failure marks, and lateral lines alongside major headers. Provider usage uses the 2 pt on / 2 pt off finch track with an explicit percentage beside it. At most one warning window uses gold; other warnings use warm, and critical windows use beak red.
- Bots, Projects, Settings and management sheets: grouped rows, quiet solids rather than repeated glass, and the same mono section labels. Sign-in uses the Horizon-eye and a link-colored server hint. No workflow or navigation changes for decoration.

Keep native navigation, swipe actions, and keyboard safe areas; use 44 pt targets for standalone controls. Custom motion uses the Thermocline curves at 120, 200 or 320 ms, without bounce; honor Reduce Motion. Review light, dark, Classic and accessibility text sizes.

## Offline screenshot QA

Launch the Debug simulator app with `-HMDemo 1 -HMTab N` (0 Chats, 1 Bots, 2 Projects, 3 Status, 4 Settings). The fixture transport keeps requests in-process and does not use a bridge or a real credential. Use `-HMOpenChat default/demo-thermocline` for the transcript, `-HMDemoDraft 1` for the active send control, `-HMDemoLive 1` for a running tool and `-HMDemoApproval 1` with Live for the approval sheet. `-HMTab 4 -HMSettingsScroll accent` opens Settings on the accent swatches; use `thinking` instead for the thinking styles. `-HMOpenProvider openai-codex -HMUsageScrollAccount 1` shows the warning bar from Status. `-HMOpenProjectEditor 1` opens management from Projects; `-HMShowSignIn 1` shows sign-in without changing accounts. None of these fixture switches are available in Release.
