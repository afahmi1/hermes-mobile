---
name: Prometheus
description: Native iPhone remote for Hermes Agent
colors:
  ember-light: "#8e5200"
  ember-dark: "#f5b942"
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

`AccentColor.colorset` remains the only interaction tint: dark ochre in Light Mode, amber in Dark Mode. Both come from the flame family of the Firebringer icon. Use `Color.accentColor` for key controls and tint a surface lightly when it serves a purpose; keep text on tinted surfaces semantic (`.primary`). Use UIKit’s adaptive system backgrounds and fills, `.primary` and `.secondary` for text, and separators/materials for boundaries. Red, green and amber may convey status only when a label or symbol also conveys it. Do not put white text on bright amber.

## Typography

Use SF Pro, standard SwiftUI text styles, and Dynamic Type. Navigation owns top-level `largeTitle` and inline detail titles. Use semibold body/headline for row titles, body for messages, subheadline for previews, and secondary footnote/caption for metadata. Use monospaced digits for counts and monospaced type only for code/paths. When text pressure grows, stack before shrinking; wrap text that carries an action or state.

## Layout

`App/Sources/Views/DesignSystem.swift` is the source for shared SwiftUI spacing, shape, affordance and foreground roles. Numeric values in the frontmatter denote logical points in native code. Keep 4 pt within a label pair, 8–12 pt within a component, 16 pt at content edges and 24 pt between larger groups. Use grouped rows rather than nested cards. Standalone actions have a 44 pt minimum target; keep model selection and send in the bottom composer, and native navigation where it is expected.

## Elevation & Depth

Conversation content sits on the system background. Grouped lists and forms use system layers. Composer and pinned-message bar use system bar material as a boundary while scrolling. No custom shadows or gradient decoration.

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
