# PapaTransport — CLAUDE.md

## Project Overview

PapaTransport is a single-developer production iOS app for Australian multi-modal public transit. It surfaces real-time and scheduled departures for Melbourne trains, trams and buses, plus Queensland (SEQ) buses and trains, and a lightweight trip planner ("Plan Lite") built on MapKit.

Supported regions:
- **Victoria**: Melbourne trains, trams and buses, plus V/Line regional trains — all served by the PTV Timetable API, no bundled data
- **Queensland**: SEQ/TransLink buses and trains (GTFS-RT + static GTFS SQLite)

Tabs are **Bus · Trains · Trams · Plan**, where Trams is Victoria-only (tag 3, so Plan keeps tag 2 in both regions).

---

## Architecture

### Layers

| Layer | Location | Notes |
|-------|----------|-------|
| Views | `PapaTransport/Views/` | SwiftUI, organised by feature (Train, Bus, Commuting, RoutePlanner, Common) |
| Services | `PapaTransport/Services/` | Business logic and networking; protocol-based for region adapters |
| Models | `PapaTransport/Models/` | Codable structs; direct mapping from JSON/protobuf |
| Stores | `PapaTransport/Stores/` | UserDefaults-backed persistence via Codable JSON |
| Databases | Bundled SQLite (Queensland only) | Actor-isolated access via `GTFSDatabase`. Victoria is served entirely by the PTV API — no bundled data. |

### Key Patterns

- **Protocol-based region adapters**: `BusDataProviding` implemented by `BusService` / `QLDTrainMapService` (QLD, GTFS-backed) and `PTVBoardService` (VIC, API-backed).
- **Actor-isolated SQLite**: The Queensland GTFS database is an `actor` — always `await` its methods.
- **Singletons**: Services and stores expose `.shared`; databases expose `.shared`.
- **Async/await throughout**: No Combine, no callbacks. Task groups used for concurrent queries (e.g. per-stop PTV departure boards, Plan Lite mode estimates).
- **Custom protobuf decoder**: `ProtobufReader` / `ProtobufValue` — no SwiftProtobuf dependency. Located in `Services/`.
- **No external dependencies**: Zero SPM packages; everything is Apple frameworks + bespoke implementations.

### Concurrency: default main-actor isolation

The target builds with **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** and
`SWIFT_APPROACHABLE_CONCURRENCY = YES`. Every type without explicit isolation is
therefore **implicitly `@MainActor`** — including plain structs, value types and
service singletons.

This is the single easiest way to introduce a UI freeze here, because nothing
about the code looks wrong: a `struct` doing heavy synchronous work silently
runs on the main thread. It has already caused one hang (the GTFS import) and
one silent regression (1.5 MB of protobuf decoded on the main thread every 60 s).

**Mark anything that does real work, or crosses isolation domains, `nonisolated`:**

```swift
nonisolated struct GTFSFeedImporter { … }     // heavy synchronous work
nonisolated final class BusService { … }      // networking + protobuf decode
nonisolated struct GTFSFeedValidity { … }     // value type crossing actors
```

`nonisolated` on a type only removes the *requirement* to be on the main actor —
it does not move work off it. Long synchronous work must also be given a thread:
blocking one of the few Swift cooperative-pool threads for tens of seconds
starves unrelated async work, so `GTFSFeedRefreshService` dispatches the import
to a GCD queue (`runOffCooperativePool`).

Note `actor` and `@MainActor` declarations are unaffected — only *unannotated*
types inherit the default.

### State Management

- `@AppStorage` — simple settings (train line name, home/city station, visibility toggles)
- `@Published ObservableObject` — legacy approach still used for bus favourites
- `@State` — view-local ephemeral state

---

## Data Sources

| Source | Format | Notes |
|--------|--------|-------|
| Melbourne trains real-time | JSON (S3-hosted) | `website_data.json`, `departures.json`, `op_timetable_*.json` |
| Victorian trains + buses | PTV Timetable API v3 (JSON) | Schedule, real-time and disruptions in one source. HMAC-SHA1 signed; credentials embedded. |

### PTV route types on the train board

The Victorian train board spans **two** route types — metropolitan trains (0)
and V/Line (3) — and three things about route type 3 are measured, not
documented, and silent if broken (all handled in `PTVBoardService`):

- **`max_results` is applied per route *and* direction**, not per stop. Asking
  for 10 at Flinders Street returns 240 departures.
- **A shared station has one stop id across both types.** Footscray is 1072 for
  metro and for V/Line, so no id translation is needed.
- **Route type 3 covers road coaches as well as trains**, and it lists one
  physical train once per marketed through-journey — the 07:53 Ballarat service
  appears at Southern Cross under eleven route ids. Coach *stops* are filtered
  out by name ("… Railway Station"); duplicate *listings* are collapsed on
  departure time plus final stop.

### Live vehicle positions differ by region

Both regions show moving vehicles on the map, but they get there differently and
the on-screen result is not the same:

| | Victoria (PTV) | Queensland (TransLink) |
|---|---|---|
| Source | `expand=VehiclePosition` on the departures call the board already makes | separate network-wide GTFS-RT `VehiclePositions` feed |
| Extra requests | **none** | one per refresh |
| Scope | runs serving the stops in view | everything, filtered to the viewport |
| `bearing` | **populated** | never populated |

So Victorian vehicles carry a heading arrow and Queensland ones do not, and
panning to an area with no listed stops shows no Victorian vehicles where
Queensland would show plenty. Both are correct; they are just different feeds.

Coverage measured 2026-07-31 against the live API: **~49% of train runs, ~57% of
bus runs, and 0% of tram runs** carry a position. Trams were checked at four
separate corridors (0 of 55 runs), so `PTVBoardService` does not request the
expansion for the tram board at all.
| Queensland buses/trains | GTFS-RT protobuf | TransLink endpoints; no authentication required |
| GTFS schedule database | SQLite3 | `gtfs_seq.sqlite3` (Queensland only, ~320 MB). **Bundling it is optional** — see below. |

### Queensland: no timetable API exists

TransLink publishes **only** GTFS static + GTFS-realtime + RSS. There is no
query API equivalent to PTV's Timetable API, so unlike Victoria the schedule
**cannot** be offloaded to a server — Queensland must keep a local database.

Realtime endpoints in use (all unauthenticated):

| Endpoint | Consumer |
|---|---|
| `SEQ/TripUpdates/Bus` | `BusService` |
| `SEQ/TripUpdates/Rail` | `QueenslandTrainRealtimeService` |
| `SEQ/VehiclePositions/{Bus,Rail}` | `QLDVehiclePositionService` |
| `SEQ/alerts` | `BusService`, `QLDTrainMapService` |

Note the feed populates neither `bearing` nor `speed` on VehiclePositions.

### Keeping the Queensland timetable current

The GTFS `calendar` table covers a **fixed ~2-month window** (TransLink
republishes the zip roughly weekly). Past `end_date` every query still succeeds
and every table is still populated — there is simply no active service, so
boards render empty. This is the single most likely cause of "Queensland stopped
working".

Four mechanisms now cover it:

0. **Provisioning** — `GTFSFeedRefreshService.provision()` prefers an installed
   database, then a bundled one, then downloads. `GTFSProvisioningStore` exposes
   the state and `GTFSProvisioningGate` blocks *only* the Queensland Bus and
   Trains tabs while it resolves.

1. **`scripts/build_seq_db.sh`** rebuilds the bundled database from the
   published zip in ~15 s, verifies it, and regenerates `manifest.json`.
2. **Expiry is surfaced** — `GTFSDatabase.feedValidity()` reads the window,
   `GTFSFeedStatusStore` exposes it, `GTFSFeedWarningBanner` shows it. Note
   `validateInstalledDatabase()` deliberately still passes an expired feed:
   stale data plus a warning beats no data.
3. **`GTFSFeedRefreshService`** conditional-GETs `SEQ_GTFS.zip` as the window
   nears its end and imports it on device via `GTFSFeedImporter`, which streams
   through the dependency-free `ZipArchive` and `CSVRowReader`.

**`GTFSFeedImporter` and `scripts/build_seq_db.sh` must stay in step** — they
produce the same schema by two different routes, and a database from either
has to be indistinguishable to `GTFSDatabase`.

Phase 4 adds optional `shapes` and `trips.shape_id` for route overlays. Existing
databases without these fields remain usable; background refresh bypasses ETag
once to upgrade them while retaining the old database if import fails. Both
import paths reject entire malformed shapes rather than connecting across bad
points. Shape import adds work/storage to first provisioning and refreshes.

### Whether to bundle the database

Both modes are supported and the code picks automatically:

| | Bundled | Not bundled (current) |
|---|---|---|
| App download | +320 MB | +0 MB |
| First run | Instant, works offline | ~28 MB download, ~15–30 s import |

To bundle it, put a `gtfs_seq.sqlite3` in `PapaTransport/db/transport/queensland/`
(the build script installs it there). To ship without, remove it — nothing else
changes.

**`PapaTransport/db/` is an Xcode synchronized file group: every file in it is
copied into the app bundle.** Never leave scratch or backup files there. The
build script writes backups to `_archive/queensland-backups/` for this reason.

The installed database lives in **Application Support**, not Caches. Caches is
right for data the system may discard and the app can cheaply rebuild; with no
bundled copy, a purge would leave a user with no timetable and a 28 MB download
they may not be able to make. It is excluded from iCloud backup instead, and a
database from an older build is migrated out of Caches automatically.

Two traps in the TransLink CSV, both already handled, both silent if broken:
fields carry **leading spaces** after commas (`", -27.467834"`, which
`Double("…")` rejects), and `stop_times.txt` is **153 MB uncompressed**, so it
must be streamed rather than buffered.

### QLD GTFS Schema Quirk

Train stops in the SEQ GTFS database have `route_type = -1` in the stops table. To filter by rail (`route_type = 2`) you must join through the `routes` table — do not filter on the stops table's `route_type` column directly.

---

## Technology Stack

- **UI**: SwiftUI (primary); no UIKit views
- **Concurrency**: Swift async/await, `actor`, `Task`, `withTaskGroup`
- **Location**: CoreLocation — `CLLocationManager` wrapped with `CheckedContinuation` for one-shot requests; 5-minute cache freshness
- **Maps**: MapKit (`MKDirections` powers Plan Lite trip estimates; transit returns an ETA only, never a route)
- **Database**: SQLite3 C API directly (no ORM)
- **Networking**: `URLSession` only
- **Notifications / Background**: `UserNotifications`, `BackgroundTasks` (identifier: `trainStatusRefresh`)

---

## Project Configuration

- **Bundle ID**: `org.nando.papatransport.PapaTransport`
- **Marketing version**: 3.23 (build 23)
- **Development team**: `D58U53H2X6`
- **Minimum deployment**: check `PapaTransport.xcodeproj` for exact value
- **Single scheme**: `PapaTransport`
- **No test targets** — manual/simulator testing plus scratch-data regression
  harnesses: `scripts/validate_route_geometry.sh` and `scripts/validate_map_selection.sh`.

---

## Naming Conventions

- Types: `PascalCase`
- Properties/methods: `camelCase`
- Services: `XyzService` (singleton via `.shared`)
- Database actors: `XyzGTFSDatabase`
- Boolean properties: `isLoading`, `shouldShow`, `hasArrivalTarget`

---

## Code Style

- No comments unless the *why* is non-obvious (hidden constraint, subtle invariant, workaround).
- `MARK:` comments used to section large files — maintain them when adding code nearby.
- Enums preferred for configuration and status values over stringly-typed alternatives.
- Placeholder models (`TrainInfo.placeholder`, `BusInfo.placeholder`) used as loading/fallback state — do not replace with optionals.
- Safe `Decodable` inits with sensible defaults for API fields that may be missing.

---

## Feature Documentation

- **Map interactions / UI Phase 4**: `UIRevampPlan.md`. Both explorers use
  `MapRouteSelection` for linked service selection and actual route geometry,
  plus `MapSheetScaffold`'s next-departure peek. Tapping a departure row highlights
  the map and immediately opens its trip sheet, independently of geometry loading.
  **Trip details** also reopens the selected trip. Train trip details show the
  departure's platform beneath the selected station when the provider supplies it.
  PTV returns run geopaths;
  Queensland uses GTFS shapes. Missing/invalid geometry is surfaced explicitly.
  Station/stop pins immediately expand and focus their departure list; the peek
  also has a visible **Show departures** action. Train direction groups start
  collapsed, with a loaded departure count and two-hour window. Planned works
  and the selected trip's stop list also start minimized; the Train Line Status
  summary stays expanded above the station list. Route geometry does not gate
  board display. Reload generations reject obsolete responses; useful in-flight
  work survives insignificant camera changes. Train regional rows
  publish before favourites and refresh alongside general line status.

- **Plan Lite**: `PlanLiteService` + `RoutePlannerView`. MapKit-based trip estimates with no bundled data. Note that `MKDirections.calculate()` never returns a transit route — only `calculateETA()` works for transit, so the itinerary is handed off to Apple Maps.
- **PTV Timetable API**: `PTVIntegrationPlan.md` at repo root. Read this before touching anything under `Services/PTV/`. Covers the signing scheme, the feature flags, and what PTV can and cannot replace.

---

## Important Files

| File | Purpose |
|------|---------|
| `PapaTransport/PapaTransportApp.swift` | App entry point, environment setup |
| `PapaTransport/App/` | Theming (`ThemeSet`, `ThemePalette`, environment keys) |
| `PapaTransport/Services/CommutingService.swift` | Orchestrates train + bus concurrent fetching |
| `PapaTransport/Services/GTFSDatabase.swift` | Queensland SQLite actor |
| `PapaTransport/Services/ProtobufReader.swift` | Custom GTFS-RT protobuf decoder |
| `PapaTransport/Services/PTV/PTVBoardService.swift` | PTV-backed departure boards (Victorian train + bus) |
| `PTVIntegrationPlan.md` | PTV Timetable API integration plan and findings |

---

## SwiftUI traps this codebase has already hit

Three separate causes of "the map feels unresponsive", all found on 2026-07-31
after live vehicles landed. None of them are visible in a build.

- **Never reference a computed collection from inside a `ForEach` body.** A
  `private var index: [String: T]` read as `index[item.id]` inside the loop
  rebuilds the whole dictionary *per element*. With 250 map annotations against
  a 150-departure board that measured 3.36 ms per body evaluation against a
  16.7 ms frame budget. Build it once and pair it up — see
  `[LiveVehicle].annotations(matching:)`.
- **Give enlarged touch targets only to things that are actually tappable.**
  A 44pt `contentShape` on every map annotation put hundreds of dead hit-test
  rectangles over the map and swallowed pan gestures. Non-interactive
  annotations want `.allowsHitTesting(false)`.
- **Use `.buttonStyle(.glass)`, not a plain button wrapped in
  `.glassEffect(.interactive())`.** The latter layers interactive glass outside
  the button, where it runs its own press handling and fights the button's — the
  control responds once and then stops.
- **Keep one `.sheet` per subtree.** SwiftUI presents one sheet per context; a
  second modifier further down the same chain can leave an ancestor's sheet
  unable to open at all. Raise the selection through a binding instead — see
  `BusCard`'s `selectedTrip:`.

## Things to Avoid

- Do not add external Swift Package dependencies — the project is intentionally dependency-free.
- Do not use Combine — async/await is the established concurrency pattern here.
- Do not access GTFS database actors from the main actor without `await` — they are actor-isolated.
- Do not filter QLD train stops by `route_type` on the stops table — join through `routes` (see schema quirk above).
- Do not use `try!` or `!` force-unwraps in service/database code — the existing code uses graceful fallbacks.
