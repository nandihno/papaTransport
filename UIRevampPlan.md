# PapaTransport — UI Revamp Plan

Status: **Phase 1 complete** (2026-07-28). Phases 2–4 outstanding.
Context: the Victorian data layer now runs entirely on the PTV API. The views were
built incrementally around the old GTFS-backed shape and have accumulated
duplicate renderings, duplicate chrome, and a colour system that only ever worked
in dark mode. Deployment target is **iOS 26.4**, so the whole modern SwiftUI
toolkit is available and currently unused.

---

## 1. Diagnosis

### 1.1 The palette is a dark-mode palette being rendered on light backgrounds

`AppTheme.success / warning / danger / info` are declared as four **static
colours** in `App/AppTheme.swift:70-73`. Every other colour in the app is
per-scheme via `ThemePalette`; these four are not. They were tuned against the
near-black brown dark surfaces and are reused verbatim on the cream light
surfaces.

Measured WCAG contrast ratios (4.5:1 required for body text, 3:1 for ≥17pt bold):

| Colour | on light `surface` | on light `surfaceRaised` | on dark `surface` |
|---|---|---|---|
| `success` (the green "On Time") | **1.74:1** | **1.43:1** | 9.41:1 |
| `warning` | **1.55:1** | **1.27:1** | 10.57:1 |
| `danger` | **2.50:1** | **2.05:1** | 6.55:1 |
| `info` | **1.82:1** | **1.50:1** | 8.99:1 |

Everything in the light column fails, most of it by a factor of three. This is
exactly the green text in the screenshot. It is not a matter of taste — 1.43:1 is
below the threshold at which text is legible for anyone, and the app is used
outdoors on a platform.

Two more offenders in the same file:

| Colour | Used for | on light `surface` |
|---|---|---|
| `accentStrong` | sheet heading "Train Stations in View" | **1.91:1** |
| `accent` | card headings, section labels | **2.99:1** (fails body, scrapes large) |

**Root cause:** semantic colours live outside `ThemePalette`, so they have no
light variant. That is the structural bug to fix, not the individual hex values.

### 1.2 The same information is rendered two or three times

On the screen in the screenshot:

- **"2 stations in view"** appears **three times** — the map header pill
  (`TrainMapExplorerView.swift:216`), the sheet grip chip (`:400`), and the
  nearest-stations card chip (`:436`).
- **"Train Stations in View"** appears **twice** — grip handle (`:394`) and the
  card `Label` immediately beneath it (`:420`).
- **The six Werribee-line departures appear twice.** The `Live ETA / ETD` grid
  (`LiveMetroDeparturesBlock`, `:1165`) lists 3:15/3:35/3:55 inbound and
  3:10/3:30/3:50 outbound. The line-group list below then lists the *same six
  services* again as full rows.
- **Each row states "on time" three times.** `Sched 3:10 pm`, `Pred 3:10 pm`, and
  `On Time` are three renderings of one fact. When a service is on time — the
  common case — two of the three are pure noise.

That is the density problem. It is not that the screen has too many features; it
is that it prints the same facts repeatedly.

### 1.3 Four levels of nested containers

Each level has its own fill, its own border, and its own corner radius:

| Level | Where | Padding | Radius |
|---|---|---|---|
| Bottom sheet | `TrainMapExplorerView.swift:352` | — | 30 |
| `CardContainer` / `transitCardStyle` | `AppTheme.swift:202` | 18 | 22 |
| `TrainStationSection` | `TrainMapExplorerView.swift:1114` | 14 | 18 |
| `LiveMetroDeparturesBlock` | `TrainMapExplorerView.swift:1216` | 10 | 12 |

Text ends up ~60pt narrower than the sheet it sits in, framed by four competing
edge treatments. Visible in the screenshot as boxes inside boxes.

### 1.4 The two map explorers are near-identical copies

Ten private helpers are duplicated verbatim between `TrainMapExplorerView` and
`BusMapExplorerView`: `headerOverlay`, `mapInfoBanner`, `overlayControlButton`,
`gripHandle`, `currentSheetHeight`, `sheetHeights`, `sheetDragGesture`,
`recenterOnUser`, `runAutoRefreshLoop`, plus a private `SheetDetent` enum each.
`VictorianTripStopRow` is defined twice (`BusCard.swift:826`,
`TrainMapExplorerView.swift:1658`). Roughly 400 lines of duplicated view code.

Dead code from the PTV refactor: `TrainCard` (`TrainCard.swift:10`) has **zero
references**, and `TrainAlertRow` / `DepartureSectionView` are only referenced by
`TrainCard` itself. ~400 of that file's 457 lines are unreachable; only
`TrainPlannedWorkRow` is still used.

### 1.5 Typography has no scale, and does not support Dynamic Type

`Font.transit` (`AppTheme.swift:164`) wraps `.system(size:weight:design:)` — a
**fixed point size that never responds to the user's text-size setting**. The app
is locked at one size regardless of accessibility settings.

There are 13 distinct hardcoded sizes in use (10, 11, 12, 13, 14, 15, 16, 17, 18,
22, 24, 26, 28) alongside 109 uses of the built-in text styles (`.caption` ×48,
`.caption2` ×31, `.subheadline` ×24, …). Two parallel type systems, neither with
a defined scale.

### 1.6 The platform is being left on the table

Deployment target is iOS 26.4. There are **zero** uses of `glassEffect` or
`GlassEffectContainer`; the app hand-rolls its material chrome with 15
`ultraThinMaterial` calls and manual gradient overlays. Bottom sheets, tab-bar
minimisation, and scroll-edge effects are all reimplemented by hand.

### 1.7 The list is grouped the wrong way for a commuter

The `Live ETA / ETD` grid groups by **direction** (Inbound → City / Outbound) —
which is how a commuter actually thinks. The main list below groups by **line
name**, so Werribee and Flinders Street services interleave in one flat list. The
app already has the right grouping in the small widget and the wrong grouping in
the primary one.

---

## 2. Plan

Four phases, ordered so each is shippable on its own and the highest-impact,
lowest-risk work lands first.

---

### Phase 1 — Fix the foundations ✅ DONE

No layout changes — purely design tokens. Build verified clean; net −592 lines.

**1.1 Semantic colours moved into `ThemePalette`.** ✅

`success`, `warning`, `danger`, `info` are now `ThemePalette` members with light
and dark variants. The original values became the dark ones.

> **Correction from the original draft.** The first derivation sized the light
> values against `surface` and `surfaceRaised` only. That was the wrong worst
> case: `cardBackground` is a gradient running `surfaceOverlay → surface`, so
> text on a card sits over `surfaceOverlay` (0.937, 0.808, 0.675), which is
> darker than both. Re-derived against all three surfaces:

| Role | Light value | vs `surface` | vs `surfaceRaised` | vs `surfaceOverlay` |
|---|---|---|---|---|
| `success` | `#0E682C` — `rgb(0.057, 0.410, 0.175)` | 6.40:1 | 5.26:1 | **4.61:1** |
| `warning` | `#894900` — `rgb(0.540, 0.288, 0.000)` | 6.44:1 | 5.30:1 | **4.64:1** |
| `danger`  | `#B21A03` — `rgb(0.700, 0.105, 0.014)` | 6.40:1 | 5.26:1 | **4.61:1** |
| `info`    | `#0058B1` — `rgb(0.000, 0.347, 0.695)` | 6.42:1 | 5.28:1 | **4.62:1** |

`outline` and `shadow` were the same defect — static colours tuned for dark —
so they moved into the palette too. Light mode now gets a black hairline instead
of an invisible white one, and a 0.10 shadow instead of a muddy 0.34.

**1.2 Accent split into fill and text roles.** ✅

`accent` / `accentStrong` remain fill-only. New `accentText` carries all type and
icons: light `#954000` — `rgb(0.585, 0.254, 0.000)` at 4.65:1 worst case, dark
`rgb(1.000, 0.663, 0.180)` at 7.34:1. 15 call sites swept over.

**Result — every token now clears 4.5:1 on every surface in both schemes:**

| token | light before | light after | dark |
|---|---|---|---|
| `success` | 1.25:1 | **4.61:1** | 7.54:1 |
| `warning` | 1.11:1 | **4.64:1** | 8.46:1 |
| `danger` | 1.80:1 | **4.61:1** | 5.25:1 |
| `info` | 1.31:1 | **4.62:1** | 7.21:1 |
| `accentText` | 1.38:1 | **4.65:1** | 7.34:1 |

**1.3 Type scale replaced.** ✅

79 fixed-size calls collapsed onto seven roles (seven rather than the six first
sketched — 22pt headlines and 28pt countdowns needed separating, and squashing
them lost the hero emphasis). Every role is built on a `TextStyle`, so the app
now responds to Dynamic Type for the first time. The rounded design is baked into
each role rather than inherited, so a role is correct regardless of ancestor
modifiers.

```swift
static let transitDisplay  = Font.system(.title,       design: .rounded, weight: .heavy)
static let transitTitle    = Font.system(.title2,      design: .rounded, weight: .heavy)
static let transitHeadline = Font.system(.title3,      design: .rounded, weight: .bold)
static let transitBody     = Font.system(.subheadline, design: .rounded, weight: .semibold)
static let transitLabel    = Font.system(.footnote,    design: .rounded, weight: .semibold)
static let transitCaption  = Font.system(.caption,     design: .rounded, weight: .regular)
static let transitBadge    = Font.system(.caption2,    design: .rounded, weight: .bold)
```

`Font.transit(_:weight:)` is gone. `.monospacedDigit()` retained on countdowns.

The ~109 remaining built-in text styles (`.caption`, `.subheadline`, …) were
deliberately left alone: they already scale correctly, so they are not part of
the defect. A single `.fontDesign(.rounded)` at the `CommutingView` root brings
them into visual line. Fold them into the roles opportunistically in Phase 2,
when those views are being restructured anyway.

**1.4 Dead code deleted.** ✅

`TrainCard`, `TrainAlertRow`, `DepartureSectionView` removed with
`TrainCard.swift` (457 lines). `TrainPlannedWorkRow` extracted to its own file.
`VictorianTripStopRow` de-duplicated into `Views/Common/TripStopRow.swift`
(renamed — it was never Victoria-specific). `AppTheme.weather` and
`AppTheme.health` (56 lines, zero references) deleted. The status→colour switch,
which existed in four copies, is now `ThemePalette.color(for:)`.

---

### Phase 2 — Cut the density

**2.1 Merge the two departure renderings into one list.**

This is the biggest single win and the only item with real engineering cost,
because the two renderings come from two different sources:

- `LiveMetroDeparturesBlock` ← `TrainService.fetchLiveDepartures(station:)`, the
  S3 MetroTrains feed. Uniquely supplies **platform**, the **ETA/ETD split**, and
  the **inbound/outbound** classification.
- The line groups ← PTV board. Supplies headsign, status, minutes away, and the
  trip-detail linkage.

Proposal: PTV remains the row source; the S3 feed becomes **enrichment**, matched
onto PTV rows by scheduled time, contributing platform and ETA/ETD. The separate
grid then disappears with **no information lost**. Put the matcher in a small
view model or in `PTVBoardService`, not in the view.

Decision needed: whether platform + ETA/ETD can come from PTV directly, in which
case the S3 dependency drops out of this screen entirely. Worth checking against
`PTVIntegrationPlan.md` before building the matcher.

**2.2 Regroup by direction, not by line.**

Primary grouping becomes **To City / Outbound** (the grid already gets this
right), with the line shown as a badge on each row. A commuter picks a direction
first and a line second; the current flat interleaving forces them to scan.

**2.3 Print each fact once.**

Current row — five text elements, three of which say "on time":

```
Werribee                                    8   min
Sched 3:10 pm    Pred 3:10 pm            On Time
```

Proposed — status becomes a coloured dot, and the time is stated once. Delay is
shown only when there is one:

```
●  Werribee                                   8
   Plat 2 · 3:10 pm                         min

●  Werribee                                  29
   Plat 2 · 3:30 → 3:31 pm · 1 min late     min
```

Roughly 40% fewer glyphs per row at no information cost. Keep the delay text (not
just colour) so status is not conveyed by colour alone.

**2.4 Remove the duplicate headers.** Keep the count in the grip handle only;
drop it from the map header pill and the card. Keep the title in the grip handle;
drop the card's `Label`. Three instances → one.

**2.5 Flatten the container nesting.**

Inside the sheet, drop the card chrome entirely — the sheet *is* the container.
Sections become flat, separated by whitespace and hairline dividers. Reserve
`CardContainer` for content floating **on** the map, where elevation is doing
real work. Four nested levels → two.

---

### Phase 3 — Modernise the shell

**3.1 Extract one shared `MapSheetScaffold`.**

Fold the ten duplicated helpers into a single reusable component in
`Views/Common/`, parameterised by title, summary, and content. Both explorers
become thin callers. ~400 lines deleted.

On the sheet mechanism itself: the native `.presentationDetents` +
`.presentationBackgroundInteraction` route is tempting and would delete the drag
maths outright — **but a `.sheet` covers the tab bar**, and this app needs its
four tabs reachable at all times. Recommendation is therefore to keep a custom
container and simply stop having two of them. If the tab bar can be relocated,
revisit this; it would be a further large simplification.

**3.2 Adopt Liquid Glass.**

Replace the hand-rolled `ultraThinMaterial` + gradient stacks with
`.glassEffect(.regular, in: .rect(cornerRadius: 28))` on the sheet, and wrap the
floating map controls in a `GlassEffectContainer` so they blend as a group. The
two full-screen scrim gradients (`TrainMapExplorerView.swift:127-149`) become
unnecessary — glass handles legibility over the map itself.

**3.3 Let the tab bar minimise.**

`.tabBarMinimizeBehavior(.onScrollDown)` reclaims vertical space while the user
reads departures. Consider `.tabViewBottomAccessory` for the "last updated"
status line, which currently costs a full banner row inside the sheet.

**3.4 Add `.scrollEdgeEffectStyle` to the sheet's scroll view** so content fades
at the grip handle instead of colliding with it.

---

### Phase 4 — Make the map earn its space

The map is the thing worth keeping, so give it more to do:

- **Draw the route.** Shape data already landed in commit `74118bb`. Drawing the
  selected line's polyline turns the map from backdrop into context.
- **Tie selection both ways.** Selecting a departure highlights its line on the
  map and dims the others.
- **De-emphasise unselected pins** so a dense area stays readable.
- **Let the sheet collapse further** — a peek detent showing just the next
  departure, so the map can be nearly full-screen when the user is orienting.

---

## 3. Sequencing

| Phase | Effort | Risk | User-visible result |
|---|---|---|---|
| ~~1 — foundations~~ ✅ | done | — | Text readable; type scales with accessibility settings |
| 2 — density | Largest; §2.1 needs a data decision | Medium — changes what's on screen | Screen roughly halves in visual weight |
| 3 — shell | Moderate | Low–medium — glass is a swap, sheet extraction needs care | Looks like a 2026 iOS app |
| 4 — map | Open-ended | Low, additive | Map becomes genuinely useful, not decorative |

Phase 1 is worth doing on its own regardless of what happens to the rest — it is
the fix for the actual complaint and it cannot break layout.

## 4. Open questions

1. **Can PTV supply platform and ETA/ETD directly?** If yes, §2.1 gets much
   simpler and the S3 MetroTrains dependency leaves this screen.
2. **Should the tab bar be preserved as-is?** It is the only thing blocking the
   native-sheet simplification in §3.1.
3. ~~Are the `weather` and `health` theme sets still used?~~ **Resolved:**
   `AppTheme.weather` and `AppTheme.health` (`AppTheme.swift:104-160`, 56 lines)
   have zero references. Delete them in Phase 1 rather than migrating them.
