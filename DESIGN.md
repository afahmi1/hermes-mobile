---
name: Prometheus
description: Native iPhone remote for Hermes Agent. Visual system: Thermocline v1.0, see afahmi1/thermocline.
colors:
  bg-light: "#E4E0D7"
  bg-dark: "#13181D"
  surface1-light: "#EEEAE1"
  surface1-dark: "#1A2026"
  surface2-light: "#F5F1E7"
  surface2-dark: "#22272B"
  text-light: "#13181D"
  text-dark: "#EBE7DE"
  text2-light: "#474047"
  text2-dark: "#B5AEA5"
  text3-light: "#645C64"
  text3-dark: "#9D959D"
  lead-light: "#186377"
  lead-dark: "#6BCDC2"
  link-light: "#186377"
  link-dark: "#6FB3D0"
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
  message: "20px"
spacing:
  micro: "4px"
  small: "8px"
  medium: "12px"
  gutter: "16px"
  section: "24px"
  touch: "44px"
---

## Overview

Prometheus is an iOS utility for talking to your bots and checking the Mac they run on. The incumbent visual system is native SwiftUI: four system tabs, navigation stacks, grouped lists and forms, SF Symbols, and a mostly unboxed transcript. This is a refinement of that system, not a new theme. Native controls and the content they act on come first.

## Colors

Visual system: Thermocline v1.0 (`App/Sources/Views/Thermocline.swift`, vendored from afahmi1/thermocline; token values are never edited here). `HMDesign` in `DesignSystem.swift` maps app roles to the active theme: canvas `bg`, rows and bars `surface1`, raised `surface2`, text `text`/`text2`/`text3`, separators `line`, tint and controls `lead`, links `link`, errors and destructive `danger` (finch beak red), success `success`, caution text `warm`. Macaw gold (`spark`) appears at most once per screen, as a fill or symbol, never as text on light. Outgoing bubbles are `lead` with `onLead` text. Status is always paired with a label or symbol.

### Theme option

Settings > Appearance has a Theme picker (Thermocline, the default, or Classic) stored in `@AppStorage("appTheme")`, and a Mode picker (System, Light, Dark) stored in `appMode` and applied with `preferredColorScheme`. `HMThemeSpec` holds each theme's roles and `HMDesign` reads the active one. Classic is the pre-Thermocline look: system grouped backgrounds, `.primary`/`.secondary` text, system status colors and the amber `AccentColor.colorset` (#8e5200 light, #f5b942 dark). Thermocline applies its tint through `.tint(Thermocline.lead)`; the asset catalog stays amber for Classic.

## Typography

Use SF Pro, standard SwiftUI text styles, and Dynamic Type. Navigation owns top-level `largeTitle` and inline detail titles. Use semibold body/headline for row titles, body for messages, subheadline for previews, and secondary footnote/caption for metadata. Use monospaced digits for counts and monospaced type only for code/paths. When text pressure grows, stack before shrinking; wrap text that carries an action or state.

## Layout

`App/Sources/Views/DesignSystem.swift` is the source for shared SwiftUI spacing, shape, affordance and foreground roles. Numeric values in the frontmatter denote logical points in native code. Keep 4 pt within a label pair, 8–12 pt within a component, 16 pt at content edges and 24 pt between larger groups. Use grouped rows rather than nested cards. Standalone actions have a 44 pt minimum target; keep model selection and send in the bottom composer, and native navigation where it is expected.

## Elevation & Depth

Thermocline depth is glass and light, one layer at a time. Every screen sits on the `bg` canvas with a depth field: one or two large soft radial blooms of `lead` and `link` at 8–14% alpha. Rows and cards sit on `surface1` or `thermoclineGlass` (system material plus a `line` hairline). The composer, pinned-message bar and status tiles are glass; tab and navigation bars are tinted material. Never glass on glass, never glow on text, no black shadows in light mode. Section headers use the mono uppercase label style; counts use mono with tabular digits. Motifs, used lightly: lateral-line dividers between major Status sections, finch bars for usage progress, the Horizon-eye mark on the sign-in screen and empty states, and a `danger` live dot for streaming. Classic keeps system backgrounds and system bar material.

## Shapes

Use 12 pt panels for embedded blocks and notices, 20 pt continuous curves for outgoing messages, and capsules only for compact selectors. Rounded surfaces are not the default for ordinary list content.

## Components

- Inbox rows: chat title first, preview or draft next, then bot/source/model context and pin state; date moves below at accessibility sizes.
- Transcript: flat, full-width assistant responses; right-aligned outgoing bubble with semantic text; lightweight code/callout blocks with accessible copy affordances.
- Composer: compact utility controls and one primary send/stop action. Visually separate warnings from the editable draft. Keep native menus and system sheets.
- Status: attention and freshness first, followed by a readable overview and native grouped detail rows. Use labels with status symbols, not color alone.
- Projects, bots and connection preferences: native grouped rows with short title-and-detail hierarchy. Use native progress and empty states with an actionable next step where available.

## Do's and Don'ts

Do preserve system navigation, swipe actions and keyboard safe areas. Do test light, dark and large text. Do let data and intent set hierarchy. Don’t add dashboard decoration, tiny tap targets, or secondary text in a low-contrast tertiary style. Don’t introduce new branding or product workflow under a polish change.
