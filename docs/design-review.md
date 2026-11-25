Method: design review only (detector not applicable, native platform)

# Prometheus UI review

Base: `e4826f1`. Scope: chat and composer, inbox, Status and detail, Projects/workspaces, Settings/sign-in and bots. Evidence: SwiftUI source and the existing renderer on iPhone 16 Pro, iOS 18.6. The renderer lacks the app accent asset and omits UIKit-backed or scrollable internals from some isolated previews; it is not evidence of broken live rendering.

## Critique

The app reads as native iOS, not a web port. Its specificity comes from bot identity, visible runtime selection, pinned-message recall, and Mac/gateway diagnostics. Preserve those. The largest opportunity is to make the next decision stand out without losing operating context. A one-handed user sees several adjacent symbols before the draft; a low-vision user encounters fixed targets and squeezed metadata; a maintainer returning to diagnose a failed job needs severity and freshness to beat raw counts. The worst moments are the first sign-in and a chat retry, when jargon or an unclear state is costly.

| Nielsen heuristic | Score | Observation |
| --- | ---: | --- |
| Visibility of system status | 3 | Streaming, drafts and cached dates are present; several empty lists are ambiguous. |
| Match with real world | 3 | Native actions make sense; server/bridge/gateway terminology competes at sign-in. |
| Control and freedom | 3 | Stop, archive safeguards, swipe-back and dismiss are present. |
| Consistency and standards | 2 | Standalone targets and title treatments diverge. |
| Error prevention | 3 | Destructive guards and disabled send are already in place. |
| Recognition over recall | 3 | Visible bot, model and pin context help; key compose actions lack space. |
| Flexibility and efficiency | 3 | Search, slash commands, pins and model menus preserve fast paths. |
| Aesthetic and minimalist design | 2 | Crowded metadata, bright fills and equal-weight metrics compete with current work. |
| Error recovery | 2 | Connection messages often report strings without a nearby retry action. |
| Help and documentation | 2 | Source guide is available; connection terminology still needs context. |
| **Total** | **26/40** | **Good, with clear opportunities** |

Cognitive load: moderate (3 of 8 checks fail: single focus during composition, title/metadata hierarchy, and chunking in the six-metric Status summary). Keep the existing progressive disclosure in menus and native detail pages. Strengths worth preserving: comfortable full-width replies, the concise pinned-message jump, and protective archive/cached-draft behavior.

## Native audit

Platform verdict: **pass**. Uses system tabs, navigation, lists, forms, sheets, SF Symbols and keyboard-safe insets. Violations are local (undersized standalone controls, scaling and contrast), not structural. No performance traces were taken; the performance score is source-based, not a frame-rate claim.

| Dimension | Score | Key finding |
| --- | ---: | --- |
| Accessibility | 2 | 22–40 pt composer controls, unlabeled glyphs and dark outgoing contrast. |
| Performance | 3 | Uses lazy lists; rich chat rendering not profiled. |
| Appearance and theming | 2 | White on amber and emphasis colors in several adjacent roles. |
| Platform conformance | 3 | System navigation is intact; top-level title and control sizing drift. |
| Adaptivity | 2 | Fixed dashboard columns and side-by-side metadata squeeze at larger text sizes. |
| **Total** | **12/20** | **Acceptable; significant work needed** |

### Prioritized findings (0 P0, 4 P1, 3 P2, 1 P3)

| Priority | Base location | Impact and guideline | Resolution |
| --- | --- | --- | --- |
| P1 | `ChatView.swift:405–489,1206,1537,1942`; `MarkdownText.swift:143–155` | 22–40 pt targets make commands, send/stop, sharing, pins and code actions hard to hit with a thumb. iOS minimum is 44 pt. | Give standalone actions a 44 pt floor, use scalable SF Symbols, and keep follow-up actions readable at large sizes. `/impeccable adapt` |
| P1 | `ChatView.swift:1164–1168`; `RuntimeSheet.swift:212–213` | White text on the bright dark-mode accent lacks body-text contrast. | Place semantic primary text on restrained tint fills; retain explicit selection and highlight. `/impeccable colorize` |
| P1 | `ChatListView.swift:663–691`; `StatusView.swift:87–96,285–296` | Side-by-side title/metadata and fixed columns compress or clip the identifying text. | Give title and metadata separate space at accessibility sizes; prioritize status and show the overview in adaptive rows. `/impeccable adapt` |
| P1 | `SignInView.swift:50–96` | A placeholder URL doubles as the field’s spoken label; the sign-in method selector takes a fixed horizontal shape. | Provide stable field labels, a large-text picker fallback, and clear progress and connection copy. `/impeccable clarify` |
| P2 | `ChatListView.swift:243–269`; `StatusView.swift:20–46` | Empty searches and first-load/connection feedback can leave the user guessing whether refresh is possible. | Use distinct empty/loading states and existing refresh paths. `/impeccable harden` |
| P2 | `ProjectsView.swift:102–109`; `WorkspaceViews.swift:105–130`; `BotsView.swift:28–44`; `SettingsView.swift:138–160` | Low-emphasis labels, long detail text and inconsistent row rhythm make secondary screens slower to scan. | Align titles, metadata and spacing; let identification and error text wrap. `/impeccable typeset` |
| P2 | `MarkdownText.swift:228–239`; `ChatView.swift:1188` | Side stripes and competing highlights draw attention away from the content. | Use text, symbols and quiet semantic surfaces. `/impeccable quieter` |
| P3 | Rich reply/activity content at scale | Live FPS and exhaustive VoiceOver traversal are unmeasured, not confirmed bugs. | Defer physical-device stress/profiling to release QA. `/impeccable optimize` |

Recommended order: fix thumb targets and dark contrast, adapt inbox/Status/sign-in for larger type, then align states and typography across secondary screens. Finish with `/impeccable polish` on the simulator. No P0 blocker was reproduced.

Questions skipped: delegated implementation with product assumptions provided in the brief.
