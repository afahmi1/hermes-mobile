# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Abduel, a field service engineer, is the primary user. He checks his bots and carries on conversations one-handed on an iPhone, often in short bursts between jobs. Zayd maintains the app and ships TestFlight builds.

## Product Purpose

Hermes Mobile, called Prometheus on the Home Screen, is the iPhone client for Hermes Agent running on Abduel’s Mac. Its main jobs are to resume the right conversation quickly, send a prompt or attachment, and see whether the Mac, a bot, or a scheduled job needs attention. Projects and workspaces organize related work; Settings manages the phone’s connection and preferences.

## Positioning

This is a remote for the user’s own agents, not a generic hosted chat service. Bot identity, model selection, pins, session history, and Mac diagnostics all refer to the connected Hermes installation.

## Operating Context

- A brief check should answer “what changed?” and “what can I do next?” without opening every conversation or status detail.
- Connection and background activity can outlast a visit to the app. Draft, retry, and cached-state behavior must not change as part of visual refinement.
- A server address and account are needed to sign in. Avoid inventing account, service, or availability claims.

## Capabilities and Constraints

Native SwiftUI for iPhone, iOS 17 or newer. Existing tabs, navigation, streaming, attachments, pins, model selection, scheduling, and workspace behavior are product constraints, not redesign material. No bridge, networking, data-model, persistence, or build-number changes for visual refinement.

## Brand Commitments

Keep the Prometheus Home Screen name and Firebringer icon (`App/Resources/Assets.xcassets/AppIcon.appiconset`). Use short, plain copy. Do not use em dashes in user-facing strings. Keep the interface recognizably iOS.

## Accessibility & Inclusion

Respect system text sizes and Light and Dark Mode. Use descriptive accessibility labels, signal state with more than color, and aim for at least 44 × 44 pt for standalone interactive controls.

## Assumptions for this pass

These defaults came from the delegated brief and repository, not a new user interview. Refine rather than redesign. Prioritize conversation and inbox, then cover Status and detail, Projects and workspaces, Settings and sign-in, and bot management. Preserve the existing identity, navigation, and meaning, including the existing Firebringer amber as the one interaction tint. Use an Operate approach: quick scanning, familiar iOS controls, legible states, and one-handed reach outrank expression. This app-screen pass is code-first; no new global design workflow preference was recorded.
