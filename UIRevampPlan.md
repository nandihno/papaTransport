# PapaTransport — UI Revamp Plan

Status: **Phases 1–4 implemented.** Phases 1–3 confirmed on device (Phase 1
2026-07-28, Phases 2–3 2026-07-29). Phase 4 implemented 2026-10-16 with
simulator and regression validation; physical-device acceptance remains pending.
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

**2.1 Delete the second departure list.**

> **Open question resolved (2026-07-29).** The plan assumed this needed a
> matcher joining two sources. It does not. Queried live against PTV
> `/v3/departures/route_type/0/stop/1097` (Hoppers Crossing), every field the
> `Live ETA / ETD` grid displays is already in the *same response the board
> alrready fetches*:
>
> | Grid column | PTV field | Sample |
> |---|---|---|
> | Time | `scheduled_departure_utc` | `2026-07-29T05:10:00Z` |
> | Plat | `platform_number` | `2` |
> | ETD | `estimated_departure_utc` | `2026-07-29T05:12:00Z` |
> | Inbound/Outbound | `direction_id` + `directions` | `1 → City`, `16 → Werribee` |
>
> The only column PTV has no equivalent for is **ETA** — it exposes departure
> times only, no arrival. In the screenshot that column is always ~1 minute
> before ETD (3:14/3:15, 3:34/3:35, 3:10/3:11); at a station you are standing
> at, ETD is the number that matters. Dropping ETA is the right call.

So `LiveMetroDeparturesBlock` and the `TrainService.fetchLiveDepartures(station:)`
call behind it are **deleted outright**, not merged. This removes:

- the duplicate rendering of every departure,
- a second network round-trip per station expansion (the S3 MetroTrains feed),
- `isLoadingLive` / `hasLoadedLive` / `liveDeparturesError` state from
  `TrainStationSection`.

`PTVBoardService` gains `platformNumber` and `directionId` on its rows —
`PTVDeparture` already decodes both, they are simply discarded today.

Two things PTV returns that the app currently throws away and should show:
`runs[].destination_name`, and `express_stop_count` (a Flinders Street run in the
same sample was express past 4 stops — worth a badge).

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

### Phase 2 — implementation plan

Four findings from investigating the code changed the shape of this phase. All
four make it smaller than drafted.

1. **PTV already returns everything the duplicate grid shows** (§2.1) — so that
   item is a deletion, not a two-source merge.
2. **`directionName == "City"` is an exact test.** Checked all 17 metro routes:
   every one names its cityward direction literally `City`, and no other
   direction name contains the word. The single exception is **Stony Point**
   (`Frankston | Stony Point`), which legitimately has no cityward direction —
   it is the isolated shuttle. This replaces the S3 feed's `toCity` flag with a
   stronger signal.
3. **Phase 1 orphaned four arrays.** Deleting `TrainCard` left
   `TrainInfo.homeStationDepartures`, `homeStationAllDepartures`,
   `cityStationDepartures` and `cityStationAllDepartures` with **zero readers**.
   They are still fetched and decoded on every refresh.
4. **Two of three S3 calls per refresh are now waste.** `fetchTrainInfo` fetches
   `website_data.json` (still needed — line status, alerts, planned works),
   `departures.json` and `op_timetable_{lineId}.json`. The latter two feed only
   the orphaned arrays.

#### Steps 1–3 ✅ DONE (2026-07-29)

Implemented as specified below, with two adjustments made during build:

- **Platform for Queensland stayed deferred** as planned — `platform: nil` at
  both QLD call sites; the schema change is a separate piece of work.
- **`BusStopSection` (bus/tram board) got the shared row but not grouping.**
  The plan's step 2 text implied direction-grouping everywhere ("the same
  component, different labels"), but applying it there is a second visible
  layout change to a screen with no Phase-1-style visual verification yet.
  Scoped down to: swap `BusDepartureRow` → `DepartureRow`, keep the flat list.
  Direction-grouping for bus/tram is a small, separately-reviewable follow-up.
- Net **−322 lines**: `TrainLineGroup`, `TrainLineGroupSection`,
  `TrainDepartureRow`, and the old `BusDepartureRow` are gone, replaced by three
  files in `Views/Common/` (`DepartureGrouping.swift`, `DepartureRow.swift`,
  `DepartureGroupSection.swift`) shared across train and bus/tram.
- Build clean, no new warnings in any touched file.

#### Steps 4–6 ✅ DONE (2026-07-29)

Net for all of Phase 2: **−831 lines** across 12 files.

**Step 4 — deletions.** Removed `LiveMetroDeparturesBlock` and its four pieces
of loading state, `TrainService.fetchLiveDepartures`, `fetchTimetable`,
`filterAndMapTimetable`, `filterAndMapDepartures`, the four orphaned `TrainInfo`
departure arrays, `homeStationName`/`cityStationName`, the `TrainDeparture`
model, and the `DeparturesAPIResponse`/`DepartureAPIEntry` types.

`TrainService` went from **298 → 136 lines** and from **three S3 requests per
refresh to one**. `departures.json` and `op_timetable_<line_id>.json` are no
longer fetched for the board.

Two things the plan had wrong, caught during the work:

- **`TimetableAPIEntry` could NOT be deleted.** The plan listed it as
  removable-if-unreferenced. It is still live — `TrainSettingsViews` decodes
  `op_timetable_<line_id>.json` to populate the Home/City Station picker lists.
  Kept, along with that one call.
- **Two `TrainService` statics became orphaned** as a knock-on:
  `secondsSinceMidnight()` and `secondsToTimeString()`. Nothing outside the
  file called them once the departure mapping went. Removed;
  `currentTimeString()` survives.

`TrainStatusNotificationService` was the flagged risk. It reads `lineName`,
`serviceIsGood`, `serviceStatusMessage`, `melbourneTimeAtFetch` and `alerts` —
all five survive. Its `fetchConfiguredTrainInfo()` was simplified to drop the
two station arguments it no longer needs. Compiles clean.

**Step 5 — headers.** Count now appears once (sheet grip handle) instead of
three times; title once instead of twice. The map pill lost the count and is now
purely about map state ("Pan the map…" / "Zoom in…") plus the loading spinner,
which moved to the grip handle beside the count.

**Step 6 — chrome.** `nearestStationsCard` became `nearestStationsList` — no
`CardContainer`. `TrainStationSection` and `BusStopSection` lost their per-row
borders in favour of a tint when selected and a hairline when not. Nesting
inside the sheet went from **four levels to two**. `BusCard` lost its card
chrome too, since it only ever renders inside the bus/tram sheet.

Knock-on removals: `nearbyStationsLabel` (duplicated `mapSummary`),
`minimizeButton` + its `trainNearestStationsMinimized` setting (the card it
collapsed no longer exists), `userCoordinateDescription` (only ever shown in the
deleted card header), and the now-unused `homeStation`/`cityStation`
`@AppStorage` in `CommutingView`.

The three status cards (`TrainStatusSummaryCard`, `TrainPlannedWorksBoard`,
`QLDTrainNetworkStatusCard`) **keep** their `CardContainer`. They were always
sheet → card, i.e. two levels; they were never part of the four-level problem,
and they are genuinely distinct panels rather than list rows.

---

### ⚠️ Phase 2 leaves one loose end

The **Home Station** and **City Station** pickers in Settings now have no effect
on anything. They were already inert — Phase 1 deleted `TrainCard`, the only
reader of the departure arrays they fed — and Phase 2 removed the plumbing that
carried them. The pickers still work and still persist a value; nothing consumes
it.

Deliberately left in place: removing user-facing settings is a product decision,
not a refactor. Either delete both pickers, or give them a purpose (they would
be a natural fit for pinning a home station as a favourite on the Trains board,
the way the Queensland home station already works).

### ✅ Phases 1–2 visually confirmed on device (2026-07-29)

Confirmed by the developer running the app after Phase 2 landed. This closes the
standing risk that had run through both phases: every change up to this point was
compile-verified, and data-layer changes were verified against the live PTV and
TransLink APIs, but nothing had been rendered and looked at until now.

Note the simulator was unavailable for the whole of Phases 1–2, so all
verification was CLI builds plus live-API checks plus the developer's own device.
If that is still the case for Phase 3, the same applies — the fix is
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

#### Step 1 — Carry the fields PTV already returns

`BusDeparture` (`Models/BusModels.swift`) gains:

```swift
let platform: String?        // PTVDeparture.platformNumber
let directionId: Int?        // PTVDeparture.directionId
let directionName: String?   // PTVDirection.directionName — "City" / "Werribee"
let expressStopCount: Int    // PTVRun.expressStopCount
let isAtPlatform: Bool       // PTVDeparture.atPlatform
```

All five are already decoded and then discarded. `BusDeparture` uses `let`
without defaults, so its synthesised memberwise init means **all four
construction sites must be updated**: `BusModels.swift:292` (placeholder),
`BusService.swift:375` (QLD bus), `QLDTrainMapService.swift:351` (QLD train),
`PTVBoardService.swift:516` (all Victoria).

Queensland passes `platform: nil`. SEQ `stops.txt` *does* carry `platform_code`,
but importing it means a schema change in both `GTFSFeedImporter` and
`scripts/build_seq_db.sh` plus a database rebuild — **deferred, not Phase 2.**

#### Step 2 — Group by direction

New `DepartureDirectionGroup` deriving groups from `directionName`, cityward
first. Cityward test is `directionName == "City"`, with a documented note that
Stony Point yields no cityward group by design.

For bus and tram, `directionName` is a place name rather than City/Outbound, so
the grouping is still by direction but without the cityward ordering — the same
component, different labels.

#### Step 3 — One shared departure row

A single `DepartureRow` in `Views/Common/` replaces three near-identical rows:
`TrainDepartureRow`, the inline row inside `TrainLineGroupSection`, and
`BusDepartureRow`. Layout per §2.3 — coloured status dot, one time, platform,
delay text only when non-zero, express badge when `expressStopCount > 0`.

#### Step 4 — Delete the duplicate and the orphaned work

- `LiveMetroDeparturesBlock` (`TrainMapExplorerView.swift:1205`) and its state
  (`liveDepartures`, `isLoadingLive`, `hasLoadedLive`, `liveDeparturesError`).
- `TrainService.fetchLiveDepartures(station:)` — one caller, which is the block
  above.
- The four orphaned `TrainInfo` arrays, the `departures.json` and
  `op_timetable_*.json` fetches that feed only them, and `fetchTimetable`.
- `TrainDeparture` and `TimetableAPIEntry` if nothing else references them once
  the above are gone.

`TrainService` is left doing exactly one thing: line status from
`website_data.json`. **`TrainStatusNotificationService` also consumes
`TrainInfo`** (`alerts`, `lineName`, `serviceIsGood`, `serviceStatusMessage`,
`melbourneTimeAtFetch`) — all survive this cut, but it must be re-checked before
deleting anything from the model.

#### Step 5 — Deduplicate the headers

Count stays in the sheet grip only (drop from map pill and card). Title stays in
the grip only (drop the card's `Label`). Touches `headerOverlay`, `gripHandle`
and `nearestStationsCard`.

#### Step 6 — Flatten the chrome

`nearestStationsCard` stops using `CardContainer`; `TrainStationSection` loses
its own fill and border. Target two nesting levels inside the sheet instead of
four. Same for `BusCard` inside its sheet.

#### Order and verification

| Step | Risk | Verify by |
|---|---|---|
| 1–2 model + grouping | Low, mechanical | Builds; four call sites updated |
| 3 shared row | Low | Builds; visual check |
| 4 deletions | **Medium** — touches the notification service's data | Build, then confirm `TrainStatusNotificationService` still compiles and fires |
| 5–6 chrome | Low | Visual only |

Steps 1–4 are worth landing as one unit, since the row cannot show platform
until step 1 and the deletion is only safe once the row replaces it. Steps 5–6
are independent and can follow.

**Visual verification is still blocked** — Phase 1's colour and type changes have
never been seen on screen, and Phase 2 changes layout and information
architecture, not just tokens. This is the phase where looking at it matters most.

---

### Phase 3 — Modernise the shell ✅ DONE (2026-07-29)

Delivered as planned, plus one item the plan had listed as a separate decision.

**Shared scaffold.** `Views/Common/MapSheetScaffold.swift` (253 lines) now owns
the detent maths, drag gesture, sheet chrome, grip handle and floating control
buttons. Callers pass a title, a summary, and three content slots (map, header
pill, sheet body). `TrainMapExplorerView` **1322 → 1078**, `BusMapExplorerView`
**813 → 574** — nine duplicated helpers and two duplicate `SheetDetent` enums
gone.

Confirmed before extracting: five of the six candidate helpers were
**byte-identical** between the two files; `mapInfoBanner` differed by a single
`.fixedSize` line, which the shared `MapInfoBanner` keeps.

The custom sheet container was **kept** rather than switching to
`.presentationDetents`, for the reason given in §3.1 — a presented sheet covers
the tab bar and all four tabs must stay reachable. That decision is now recorded
in the scaffold itself.

**Liquid Glass.** `.glassEffect` on the sheet (r30), header pill (r18) and the
two control buttons (`.circle`, `.interactive()`), with a single
`GlassEffectContainer` around the header so its three surfaces share rendering.
The three map-pin labels moved from `.ultraThinMaterial` to
`.glassEffect(.regular, in: .capsule)`.

**The two full-screen scrim gradients are gone.** Both explorers drew a
black-to-clear gradient at the top and a `backgroundBase` gradient at the bottom
purely to keep overlay text legible over the map. Glass does that itself.

**No `#available` gates anywhere.** Minimum deployment is iOS 26.4, so Liquid
Glass is unconditionally present. Worth stating because the standard guidance is
to gate it.

**Tab bar minimise.** `.tabBarMinimizeBehavior(.onScrollDown)` on the `TabView`,
plus `.scrollEdgeEffectStyle(.soft, for: .top)` on the sheet's scroll view.

#### Also done: the Phase 2 loose end

The **Home/City Station pickers are removed.** They had been inert since Phase 1
deleted their only reader. Gone: both `NavigationLink`s, the two `@AppStorage`
keys, `StationPickerView`, the line-change reset that cleared them, and
`TimetableAPIEntry`.

That last one is worth noting — Phase 2 explicitly could *not* delete
`TimetableAPIEntry` because `StationPickerView` still decoded it. With the picker
gone it became dead, and with it the last
`op_timetable_<line_id>.json` request. **The app now makes exactly one S3
request** (`website_data.json`, for line status), down from four at the start of
this work.

Existing installs keep orphaned `homeStation`/`cityStation` keys in
`UserDefaults`. Harmless; not worth migration code to clear.

---

### Phase 3 — original plan

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

### Victorian live vehicles ✅ DONE (2026-07-31)

Added ahead of Phase 4, since it is map work and shares its plumbing.

PTV exposes `vehicle_position` (lat/lon/**bearing**/expiry) on Run objects, and
critically it expands on **`/v3/departures`** — the call the board already makes.
One request returned 48 runs with 36 positions, so this cost **no extra network
calls**, just a longer `expand` list.

- `PTVVehiclePosition` decodes lat/lon/bearing/`expiry_time`, accepting numbers
  or strings for the numerics and dropping stale or zero fixes.
- `BusInfo.liveVehicles` carries them (a `var` with a default, so the ~30
  existing construction sites were untouched). Keyed by run ref while
  collecting, so a vehicle serving several stops in view is drawn once.
- The heading arrow in `LiveVehicleMapPin` is **restored** — it was deleted in
  the Queensland work because TransLink never populates `bearing`. It now
  renders only when a bearing exists, so Victorian vehicles point and Queensland
  ones stay plain dots.
- **Trams excluded.** Measured 0 of 55 tram runs across four corridors, so the
  tram board does not ask for the expansion.

Verified by decoding the live response with the shipped model: 45 of 45 train
positions parsed, all fresh, all with a bearing, none outside Victoria.

Not yet seen on screen.

### Three follow-ups off the back of it (2026-07-31)

Measured what each feed actually populates, then built the three things worth
having. All verified against live data; none seen on screen yet.

**Tap a vehicle → its trip detail.** The pin resolves its `tripId` against the
current board and opens the existing trip sheet. Vehicles that do not resolve
stay **non-interactive** rather than giving a dead tap — that is the normal case
in Queensland, whose feed is network-wide and includes trips calling nowhere in
view. Victoria's positions come from the board itself, so essentially all
resolve. The 18pt dot gets a 44pt hit area.

**"N stops away" on Queensland departures.** TransLink populates
`current_stop_sequence` on **100% of vehicles** (58/58 rail, 945/945 bus,
sequences 1–81), so `stopSequence − currentStopSequence` gives a real distance.
Already-passed stops return nil rather than a negative. `QLDVehiclePositionService`
gained a 20-second actor-backed cache with in-flight coalescing, so the board
and the map pins **share one 230 KB fetch** instead of each making their own.

**Train type on the Victorian trip sheet.** "6 Car Xtrapolis · 142m". Needed
`expand=VehicleDescriptor` on the pattern endpoint — without it the field comes
back nil even on runs that have one.

What the feeds *don't* carry, checked rather than assumed: TransLink populates
none of `occupancy_status`, `occupancy_percentage`, `congestion_level`, `bearing`,
`speed` or `license_plate`. So there is no "how full is this bus" available.

#### Two performance bugs this introduced, and the fix

Reported as "the cog and location buttons are sometimes unresponsive". Not
threading — two main-thread problems in the annotation layer:

1. **`departuresByTrip` was a computed property referenced inside the
   `ForEach`.** Swift rebuilt the entire `[tripId: departure]` dictionary once
   *per vehicle*: 250 vehicles against a 150-departure board ≈ 37,000 insertions
   per body evaluation. Measured **3.36 ms → 0.019 ms** (177×) after building
   the index once via `[LiveVehicle].annotations(matching:)`. At 60 fps the
   frame budget is 16.7 ms, so 3.4 ms of pure dictionary churn on top of MapKit
   was enough to drop frames and miss taps.

2. **The 44pt touch target was applied to every pin, not just tappable ones.**
   Most Queensland vehicles resolve to no board departure, so the map was
   covered in hundreds of dead 44×44 hit-test rectangles competing with pan
   gestures. Non-tappable pins are now `.allowsHitTesting(false)`.

The general lesson, worth remembering: **never reference a computed collection
from inside a `ForEach` body.** It looks like a lookup and behaves like a rebuild.

Those two fixed the stutter but **not** the reported symptom, which turned out to
be a separate report — "the cog works once, then never again". Two more causes,
both mine, both from Phase 3 and the vehicle-tap work:

3. **A plain button wrapped in interactive glass.** The control buttons were
   `.buttonStyle(.plain)` + `.glassEffect(.regular.interactive(), in: .circle)`.
   That puts an interactive glass layer *outside* the button, running its own
   press handling against the button's. `.buttonStyle(.glass)` is the supported
   way to build a glass button, and the guidance says so — this was a
   straightforward deviation. The `GlassEffectContainer` went too: once the
   buttons carried their own glass, it wrapped a single surface and only added a
   layer between the controls and their touches.

4. **Three `.sheet` modifiers in the bus subtree.** `BusCard` had one, the
   vehicle-tap work added another to `BusMapExplorerView`, and the settings sheet
   sits on the `TabView` above both. SwiftUI presents one sheet per context, so a
   confused presentation state blocks the settings sheet from opening — a dead
   cog. `BusCard` now raises its selection through an optional binding (the
   pattern the file already used for `selectedStopID`), leaving one sheet in the
   subtree and matching the train tab, which had always worked.

---

### Phase 4 — Make the map earn its space ✅ IMPLEMENTED (2026-10-16)

The map is the thing worth keeping, so give it more to do:

- **Draw the route.** Shape data already landed in commit `74118bb`. Drawing the
  selected line's polyline turns the map from backdrop into context.
- **Tie selection both ways.** Selecting a departure highlights its line on the
  map and dims the others.
- **De-emphasise unselected pins** so a dense area stays readable.
- **Let the sheet collapse further** — a peek detent showing just the next
  departure, so the map can be nearly full-screen when the user is orienting.

#### Delivered behavior and architecture

- Tapping a departure row selects its service on the map and immediately opens
  the existing trip-detail sheet. Live vehicle pins select a service; station
  pins reveal the station board (see follow-up below). The map draws the selected service's actual
  geometry; other stop and vehicle pins fade while remaining selectable.
  **Trip details** opens the existing trip sheet; **Clear** restores all pins.
  These controls also appear inside the expanded sheet so they remain reachable
  when it covers the map header.
- `MapRouteSelection` owns shared selection and geometry loading for both map
  explorers. Feed identity, rather than the departure's regenerated UUID, keeps
  selection through refreshes. Removed departures clear it; canceled or obsolete
  requests cannot replace a newer selection. Nearby/favourite entries for the
  same stop merge their departures so route search cannot erase a favourite.
- `BusDataProviding.fetchRouteGeometry` supplies separate coordinate paths.
  Victoria requests the selected run's PTV geopath, validates its direction and
  date window, and parses coordinates off the main actor. Queensland joins the
  trip's `shape_id` to ordered GTFS shape points. Missing geometry is reported
  visibly; stop coordinates are never joined into an invented route.
- The old shape-data commit mentioned above no longer supplies the current
  Queensland schema. Both `GTFSFeedImporter` and `scripts/build_seq_db.sh` now
  import optional shapes and `trips.shape_id`. Existing installed databases
  continue serving boards while normal background refresh upgrades the schema,
  bypassing ETag for that upgrade. Failed downloads/imports keep the old database.
  Invalid points invalidate a whole shape, avoiding lines across missing data.
- The smallest shared sheet detent now shows only the next departure at the
  selected stop (or earliest visible departure without a selected stop), with
  loading/empty fallbacks. The full list stays mounted to preserve its state.
  A tappable/VoiceOver-adjustable grip expands it. Large text uses a vertical
  row with scrolling when needed; Reduce Motion removes the spring animation.

#### Validation and remaining acceptance

- iPhone 17 Pro simulator, iOS 26.5: real Flinders Street departures, selected
  row, fading pins, compact next-departure view, reachable tab bar and successful
  trip-detail presentation/dismissal. Largest accessibility text size was checked
  with the compact row's scrolling fallback; the prior text size was restored.
  Landscape peek and vehicle-to-route selection were also checked, then the
  simulator was returned to upright portrait.
- `bash scripts/validate_route_geometry.sh`: production PTV decoding, direction/
  validity filtering, ordered bus/rail queries, legacy schemas, optional shapes,
  malformed shape rejection and parity of both import paths, using scratch data.
- `bash scripts/validate_map_selection.sh`: refresh identity, replacement/clear/
  cancellation races, failures, favourite merging, next-departure ordering and
  matching pins. Requires macOS/Xcode; Observation's macro helper may require an
  unsandboxed local run.
- Simulator build passed. The full initial build reports eight pre-existing
  Plan Lite MapKit deprecation warnings. There is no SwiftLint configuration or
  installed SwiftLint; shell syntax/container checks and `git diff --check` apply.
- **Still pending:** physical-device acceptance, a
  live Queensland schema upgrade and route-overlay visual acceptance with valid
  geometry. The live PTV samples returned geometry dated 2026-10-30 onward;
  on 2026-10-16 those paths correctly show as unavailable. Fixture checks validate
  valid geometry independently. No release/deployment was performed.

#### Station-pane feedback follow-up (2026-10-16)

Device feedback exposed a confusing interaction: a selected station could remain
in the one-departure peek, with no visible instruction for revealing its board.
Station pins are now explicit buttons. A tap immediately expands the sheet and
scrolls to that station, even when tapping the same selected station again.
All of its direction groups start open; each can still be collapsed manually.
The station heading reports the loaded departure count and two-hour window.
The peek visibly offers **Show departures**, and tapping its departure also
reveals the list. Bus/tram stops use the same shared presentation state.

Departure display is independent of route-geometry loading. Existing rows remain
visible while a refresh shows **Updating departures…**. Nearby/favourite copies
of a train station share a merged departure list and a single scroll anchor.
Train regional results publish before slower favourites complete, and the train
board refresh runs alongside the parent's status refresh. The provider's full
regional batch still waits for its station requests; this does not establish a
new bound on network latency or remove the documented two-hour/per-route limits.

Both map views now ignore insignificant camera changes before cancelling work,
show loading during a meaningful pan's debounce, and reject cancelled/obsolete
responses using a request generation. Disappearance and excessive train zoom
invalidate work and clear the loading indicator. A failed refresh retains the
previously displayed station board.

Validation: simulator build and the production-model regression harness pass,
including repeated station/list reveal requests. Controlled async checks of the
actual view reload functions pass stale/cancelled response, loading ownership,
and delayed-favourite scenarios. On the iPhone 17 Pro simulator, tapping Flinders
Street from the collapsed pane immediately expanded/focused its board with
multiple routes and approximately 90 loaded departures. Physical-device
acceptance of this follow-up remains pending.

#### Departure-detail tap follow-up (2026-10-16)

A departure row's chevron implied opening details, but its callback only selected
the map route. In a scrolled/expanded board the separate **Trip details** action
could be above the viewport or behind the sheet. Row callbacks now synchronously
set the existing host-owned trip request as well as the map selection, for train,
bus and tram boards, including favourites. This preserves the single presenter
per explorer and does not wait for geometry or another board refresh. Peek rows
continue revealing the departure list; vehicle pins continue selecting the map.
VoiceOver hints describe the restored row action.

Validation: simulator build and whitespace checks passed. Runtime tap verification
could not be completed in this follow-up: Device Hub input returned
`noWindowsAvailable`, while simulator tap commands did not change the screen.
Physical-device confirmation of direct row-to-detail presentation remains pending.

#### Train platform in trip details (2026-10-16)

The train trip summary now shows the selected departure's PTV platform directly
beneath the selected station name, alongside the stop sequence. It uses the same
departure field already shown on the board row, so opening trip details does not
need another request. The platform line is omitted when the provider has no
value; Queensland's current GTFS-backed train departures still leave it unset.

Validation: simulator build passed. Physical-device visual confirmation remains
pending.

#### Collapsed train details by default (2026-10-16)

To keep service status easy to reach, train station direction groups now start
collapsed when a station is opened. Planned-works details start minimized, while
the **Train Line Status** summary remains expanded above the station list. In
the selected-trip sheet, **Stops From Here** also starts closed and can be
expanded on demand. New directions added by a board refresh start collapsed as
well.

Validation: simulator build and whitespace checks passed. Physical-device visual
confirmation remains pending.

---

### Adaptive map and departure layouts (2026-11-07)

The shared map scaffold limits its panel width on wider windows so the map remains
visible when the device opens. Narrow layouts keep the full-width sheet. Shared
departure rows give destinations and service details room to wrap, and station
distance badges use kilometres for longer distances. These changes apply to the
bus, train and tram explorers without changing their selection or refresh logic.
Direction groups order departures by their effective countdown so the next
service remains correct across midnight and when live predictions change order.
Physical-device testing in both open and closed positions is still required.

## 3. Sequencing

| Phase | Effort | Risk | User-visible result |
|---|---|---|---|
| ~~1 — foundations~~ ✅ | done | — | Text readable; type scales with accessibility settings |
| ~~2 — density~~ ✅ | done, −831 lines | — | Duplicate list gone; grouped by direction; nesting 4 levels → 2 |
| ~~3 — shell~~ ✅ | done | — | Glass chrome; ~490 lines of duplicated sheet code gone |
| ~~4 — map~~ ✅ | implemented; device acceptance pending | Additive | Selected route, linked pins/rows and next-departure peek |

Phase 1 is worth doing on its own regardless of what happens to the rest — it is
the fix for the actual complaint and it cannot break layout.

## 4. Open questions

1. ~~Can PTV supply platform and ETA/ETD directly?~~ **Resolved 2026-07-29:**
   yes for platform, ETD and direction; no for ETA (PTV has no arrival field).
   See §2.1 — the S3 dependency leaves this screen entirely.
2. **Should the tab bar be preserved as-is?** It is the only thing blocking the
   native-sheet simplification in §3.1.
3. ~~Are the `weather` and `health` theme sets still used?~~ **Resolved:**
   `AppTheme.weather` and `AppTheme.health` (`AppTheme.swift:104-160`, 56 lines)
   have zero references. Delete them in Phase 1 rather than migrating them.
