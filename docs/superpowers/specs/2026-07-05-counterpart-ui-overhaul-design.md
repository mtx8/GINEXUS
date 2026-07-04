# GINEXUS UI/UX Overhaul — Counterpart Look & Feel

**Date:** 2026-07-05
**Branch:** `feat/counterpart-ui-overhaul` (off `feat/hermes-incorporation`)
**Goal:** Rebuild GINEXUS's UI to match Counterpart's look and feel — the flat-matte
ink/bone/ember system, hidden-titlebar window, 224px sidebar rail, input-first Home,
document-style thread, BigInput composer — while keeping and surfacing every GINEXUS
feature (agent loop, HITL approvals, models, memory, MCP connections, projects,
schedules, voice, gauges, command palette).

## Why Counterpart's system

Counterpart's UI reads calm and editorial: one canvas ramp (ink900→ink500), warm bone
text, a single ember accent, hairline borders at 7% white, **no shadows, no materials,
no gradients**, one easing curve (`timingCurve(0.22, 1, 0.36, 1, duration: 0.45)`).
GINEXUS today is the "tactical HUD" look: gradients (chromePlate, emberConic,
canvasGlow, cardFill, topSheen), corner accents, an icon rail + 3-pane console.
Both share the identical MackTrax hex palette, so the overhaul is a *component and
layout* migration, not a palette change.

## What changes (the Counterpart grammar)

### 1. Window & shell
- `WindowGroup` → single `Window("GINEXUS", id: "main")` with `.windowStyle(.hiddenTitleBar)`.
- Min size stays generous: `minWidth: 1100, minHeight: 640`.
- Boot gate: until the Rust core reports healthy, show Counterpart-style boot screen —
  centered `GlyphMark` (spinning) + two-tone wordmark + status line in bone300.
- Root becomes `HStack(spacing: 0) { Sidebar | Divider(line) | detail }`.
- **Removed:** the 56pt icon rail and the 300pt right context rail. Their contents move
  into the sidebar and the screen header (below).

### 2. Sidebar (224pt, Counterpart pattern)
Top → bottom:
- Two-tone wordmark: `GI` in bone50 + `NEXUS` in ember500 (heavy, kerning 2.4, size 12)
  — restores the brand-spec split.
- **New Chat** bordered button (ink700 fill, ink400 stroke, radius 10).
- Nav rail items (radius 8; selected = ink600 fill + ember icon + bone50 semibold;
  hover = ink700): **Home**, **Projects**, **Memory**, **Models**, **Connections**,
  **Schedules**. (Sheets keep working — rail items open the same sheets/screens.)
- `RECENT` StampText header + conversations list (rail-item style rows).
- Footer: **Settings** rail item + **Local** status pill — dot is `success` green when
  `connected`, `error` when not; label "Local", tooltip "Running fully on this Mac".

### 3. Screen header (GINEXUS extras live here)
Counterpart screens each build a slim header row. GINEXUS's header keeps its
console controls, restyled:
- Left: current screen stamp (`EXECUTION STREAM` StampText) or conversation title.
- Right: **AUTO/HITL** segmented capsule toggle (Counterpart segmented pattern:
  capsule track ink700 + line stroke; active segment ink500 + bone50 semibold),
  **token/context gauges** as slim capsule chips, **⌘K** pill button.
- Model selection moves *into the composer* as a chip (Counterpart BigInput pattern).

### 4. Home (input-first)
Empty state becomes Counterpart's Home: centered column (max 640) with wordmark,
one warm line of copy, the big composer, and the three starter prompts as ink700
radius-12 cards with hairline stroke (hover ink600).

### 5. Composer (BigInput pattern)
One ink700 surface, radius 16, padding 14, hairline stroke that animates to
`ember700 @ 0.7` on focus. Inside:
- Row 1: multiline TextField (bone50, size 14.5).
- Row 2 left: **＋ menu chip**, **model chip** (current model name), **project chip**
  (when active), **research chip** (ember tint when deep-research on) — all capsule
  chips, ink600 fill, line stroke, bone300 text.
- Row 2 right: mic disc (32×32 ink600 circle; ember while voice active) and the
  **ember send disc** (arrow.up, ink900 on ember500 when sendable, scale 0.92→1,
  `.symbolEffect(.bounce)`).

### 6. Thread (document style, GINEXUS activity kept)
- User turn: query-as-heading — size 18 semibold bone50, no right-aligned bubble.
- Assistant turn: glyph-led prose (MarkdownReply, 14.5/lineSpacing 5) preceded by the
  activity timeline: each tool step is a flat ink700 radius-8 card with hairline,
  SF Symbol in ember while running / bone300 when done — the existing
  `BlockCard`/timeline logic restyled, no gradients or corner accents.
- **Approval block (HITL):** ink700 radius-12 card, `APPROVAL REQUIRED` StampText in
  ember500, preview text bone200, then two capsules — solid ember **APPROVE**
  (ink900 text, Touch ID flow unchanged) and bordered **DENY** (ink600 fill, line
  stroke, bone200).
- Readable column max width 720, horizontal margin 28.

### 7. Sheets, Settings, palette
All seven sheets (models, memory, connections, projects, schedules, editors) and
`SettingsView` are restyled, not restructured: ink800 background, StampText section
headers, rows as ink700 radius-10 cards with hairlines, capsule chips for selectable
items (selected = ink500 fill + ember700 stroke + ember dot), solid-ember capsule for
the primary action (e.g. `APPLY & RESTART CORE`). CommandPalette becomes an ink700
radius-16 panel with hairline + ember focus ring. All wiring to `AppModel` unchanged.

### 8. Token & component layer (Brand.swift)
- `line1`/`line2` → `Color.white.opacity(0.07)` / `0.12` (Counterpart hairlines).
- `ease` duration 0.2 → **0.45** (the Counterpart brand curve).
- Gradients (`chromePlate`, `emberConic`, `canvasGlow`, `cardFill`, `panelFill`,
  `topSheen`) and `CornerAccents` are **retired from use**; flat ink fills replace
  them everywhere. Tokens may remain defined for the icon renderer but no view uses them.
- New components: `StampText` (heavy, uppercase, kerning 2.2, bone300), `RailItem`,
  `BrandChip` (capsule chip), `EmberCTA` (solid ember capsule), segmented capsule
  toggle. `Wordmark` becomes two-tone (GI bone / NEXUS ember).
- `GlyphMark` (8-point ember starburst) stays — it is GINEXUS's brand mark, filling
  the role Counterpart's rosette fills (idle/thinking states already exist).
- Depth = surface ramp + hairline only. **No `.shadow`, no `.ultraThinMaterial`.**

### 9. Motion
- Single curve `Brand.ease` (0.45s) for focus rings, pane switches, hover, approval
  appearance, send-button state.
- Hover = one ink step lighter, tracked per-row.
- Existing GlyphMark spin/pulse retained but eased with the brand curve; all
  timeline/canvas animation stays fps-capped and paused when idle.

## What does NOT change
- `AppModel` (all `@Published` state, SSE handling, approval HMAC flow, SpineController,
  sidecars, UDS clients) — zero behavioral changes.
- XcodeGen `project.yml` targets/scheme/cargo pre-action/embed — untouched except the
  window scene lives in GinexusApp.swift.
- MarkdownReply parser (only tint/spacing tokens flow through Brand).
- Voice pipeline, AppToolHost, Intents.

## File plan
- `Brand.swift` — rewritten token/component layer (largest single lever; restyles every
  consumer centrally).
- `GinexusApp.swift` — Window scene + hiddenTitleBar.
- `ContentView.swift` — restructured shell: boot gate, sidebar, header, Home, thread,
  composer. Sheet structs restyled in place. Where extraction is clean, sidebar/home/
  composer become their own files (`SidebarView.swift`, `HomeView.swift`,
  `ComposerView.swift`) to start breaking up the 2364-line monolith.
- `SettingsView.swift` — restyle only.

## Risks & mitigations
- **Monolith churn:** ContentView edits are large → build after each phase, keep each
  commit compiling.
- **Removed rails' features:** every icon-rail/context-rail affordance must have a new
  home (sidebar item, header control, or composer chip) — checklist in the plan.
- **Snapshot mirror:** `SnapshotView` references Wordmark/header; update alongside.
- **Hardcoded sheet frames:** keep existing frames this pass; only styling changes.

## Success criteria
1. App builds clean via XcodeGen project + scheme; runs; boot screen → healthy shell.
2. Side-by-side with Counterpart, the shell reads as the same family: same canvas,
   hairlines, sidebar grammar, composer, motion.
3. Every pre-overhaul feature reachable: new chat, conversations, projects, memory,
   models, connections, schedules, settings, AUTO/HITL, approvals, voice, research,
   attachments, ⌘K, gauges.
4. Zero gradients/shadows/materials in the running UI.
