# PTV Timetable API — Integration Plan (Victorian Bus + Train)

Status: **Complete — Victoria is served entirely by PTV; the Victorian databases are gone** · Last updated: 2026-07-26

This document covers introducing the official [PTV Timetable API v3](https://www.vic.gov.au/public-transport-timetable-api)
as a data source for Victorian bus and Victorian train, alongside (and potentially
replacing) the bundled GTFS SQLite + GTFS-RT stack.

---

## 1. Why

Three separate motivations, in priority order:

1. **App size.** The bundled Victorian GTFS databases are large:
   `gtfs_victorian_bus.sqlite3` **2.0 GB**, `gtfs_victorian_train.sqlite3` **129 MB**.
   ~90% of each is the `stop_times` table plus its indexes.
2. **Reliability.** Melbourne train data currently comes from an *unofficial*
   third-party S3 bucket (see `TrainService.swift`). PTV is first-party.
3. **New data.** PTV exposes structured disruptions — the `alerts` array on
   `BusInfo` is currently always empty for Victorian modes.

## 2. What PTV can and cannot replace

Verified against a live signing spike (HTTP 200, real data) on 2026-07-24.

| Feature | Current source | PTV endpoint | Verdict |
|---|---|---|---|
| Nearby / region stops | `nearbyBusStops`, `stopsInRegion` | `/v3/stops/location/{lat},{lon}` | ✅ Replaceable |
| Departure board | `departures()` + GTFS-RT | `/v3/departures/route_type/{rt}/stop/{id}` | ✅ Replaceable |
| Trip detail | `tripPattern()` | `/v3/pattern/run/{run_ref}/route_type/{rt}` | ✅ Replaceable |
| Alerts | *(empty)* | `/v3/disruptions/stop/{id}` | ✅ Net-new |
| **Locate Me** | `Victorian*LocatorService` | — | ❌ Needs local shapes/patterns |
| **Route Planner** (bus only) | `VictorianBusRoutePlannerService` | — | ❌ **No journey planner in this API** |

### The size coupling

`stop_times` is simultaneously (a) ~90% of the DB size, (b) exactly what PTV
replaces, and (c) exactly what Locate Me and Route Planner require locally.

**Consequence:** migrating the board to PTV while keeping Locate Me / Route
Planner saves **zero bytes**. The DB is only deleted when its *last* reader is
gone. Size reduction and feature retirement are the same decision.

Readers of `VictorianBusGTFSDatabase`: `VictorianBusService`,
`VictorianBusLocatorService`, `VictorianBusRoutePlannerService`,
`BusStopSettingsViews`, `CommutingSettingsView`.

Readers of `VictorianTrainGTFSDatabase`: `VictorianTrainMapService`,
`VictorianTrainLocatorService`, `BusStopSettingsViews`, `CommutingSettingsView`.

Note the asymmetry: **train has no route planner**, so its only hard blocker is
Locate Me. That makes train the lower-risk pilot.

---

## 3. Credentials

The `devid` (user ID) and API key are **baked into the app binary**.

- Stored **XOR-obfuscated as byte arrays**, reassembled at runtime — never a
  plain string literal, which `strings` would recover instantly.
- This is **friction, not security**. Anything in a shipped binary is
  extractable. The realistic risk is a scraped key being rate-limited or
  revoked. The only true fix is a request-signing proxy server, which is
  disproportionate infrastructure for a free public-data key.
- A `@AppStorage` override remains available so a replacement key can be
  supplied without an App Store release.
- `PTVCredentials.swift` is **committed** (obfuscated bytes only) so builds are
  reproducible — unlike `APIKeys.swift`, which is gitignored and therefore
  breaks fresh clones. If this repository is ever made public, rotate the key.

Generate the obfuscated arrays locally with
`scripts/generate_ptv_credentials.swift` — the plaintext key never leaves the
machine.

### Signing

HMAC-SHA1 over the request path **including** `devid`, uppercase hex, appended
as `&signature=`. Confirmed working. Uses CryptoKit `HMAC<Insecure.SHA1>`
(deployment target is iOS 26.4, so no CommonCrypto bridging header and no
external dependency).

```
signed = path + (path contains "?" ? "&" : "?") + "devid=" + devid
signature = HMAC-SHA1(signed, apiKey) as uppercase hex
url = https://timetableapi.ptv.vic.gov.au + signed + "&signature=" + signature
```

Base URL must be **https** — the PTV docs show `http`, which App Transport
Security blocks.

---

## 4. Architecture

```
PapaTransport/Services/PTV/
  PTVCredentials.swift   — obfuscated devid + key, Settings override
  PTVSignature.swift     — HMAC-SHA1 request signer
  PTVAPIClient.swift     — URL build, sign, GET, decode, cache, throttle, backoff
  PTVModels.swift        — Codable DTOs
  PTVBoardService.swift  — BusDataProviding conformance, parameterised by route_type
```

`PTVBoardService` serves both modes — `.victorianTrain` (`route_type = 0`) and
`.victorianBus` (`route_type = 2`) — because they differ only by route type.
It conforms to the existing `BusDataProviding` protocol, so `BusCard`,
`BusMapExplorerView` and the rest of the UI require **no changes**.

New files are picked up automatically by Xcode
(`PBXFileSystemSynchronizedRootGroup`); no `.pbxproj` edits required.

### PTV route types

Confirmed live via `/v3/route_types` on 2026-07-25:

| Value | Mode |
|---|---|
| 0 | Train |
| 1 | Tram |
| 2 | Bus |
| 3 | Vline |
| 4 | Night Bus |

`PTVRouteType` matches this exactly. Regional coaches may still surface under
`3` rather than `2` — confirm when wiring Phase 3.

---

## 5. Phases

| Phase | Scope | Exit criteria |
|---|---|---|
| **1. Foundation** | Credentials, signer, client, models. No UI change. | Signed calls return 200 from within the app |
| ~~**2. VIC train board**~~ ✅ | `PTVBoardService(routeType: .train)` behind a feature flag, side-by-side with `VictorianTrainMapService` | **Built and verified live.** Still needs a ~1 week soak against GTFS before becoming default |
| ~~**3. VIC bus board**~~ ✅ | Same service with `routeType: .bus`, flag-switch `VictorianBusService` | **Built and verified live.** Needs a soak before becoming default |
| ~~**4. Disruptions**~~ ✅ | Populate the empty `alerts` array | **Built and verified live** — at no extra request cost |
| ~~**5. Size payoff**~~ ✅ | Locate Me and the GTFS Route Planner retired → Victorian databases removed from the bundle | **Done — app bundle 2.6 GB → 444 MB** |

Phases 1–4 are additive and reversible; the GTFS path stays as fallback.
**Phase 5 is the only irreversible step.**

### Phase 1 — delivered

| File | Purpose |
|---|---|
| `PapaTransport/Services/PTV/PTVSignature.swift` | HMAC-SHA1 signer |
| `PapaTransport/Services/PTV/PTVCredentials.swift` | Obfuscated credentials + Settings override |
| `PapaTransport/Services/PTV/PTVModels.swift` | Codable DTOs |
| `PapaTransport/Services/PTV/PTVAPIClient.swift` | Signed transport, cache, concurrency gate, backoff |
| `scripts/generate_ptv_credentials.swift` | Generates the obfuscated arrays locally |
| `scripts/dump_ptv_shapes.sh` | Captures real payloads to tighten the DTOs |

Verified:

- All four sources type-check under **Swift 6 strict concurrency**.
- The Swift signer produces **byte-identical signatures** to the `openssl`
  implementation that returned HTTP 200 from the live API — checked for both a
  bare path and a path that already carries a query string.
- Generator → `PTVCredentials` round-trip returns the exact input values.
- With placeholder (empty) arrays the code **fails closed**: `isConfigured`
  is `false` and the client throws `.notConfigured` with remediation text
  rather than sending an unsigned request.

**Credentials are installed and confirmed working.** `PTVCredentials.swift`
holds the real obfuscated arrays; a live `verifyConnection()` returned HTTP 200
with all five route types. Phase 1's exit criteria are met.

To rotate the key later, re-run the generator and replace the three arrays:

```
swift scripts/generate_ptv_credentials.swift <DEVID> <API_KEY>
```

### Phase 2 — delivered

| File | Purpose |
|---|---|
| `PapaTransport/Services/PTV/PTVBoardService.swift` | Board + trip detail, one instance per mode |
| `PapaTransport/Services/PTV/PTVFeatureFlags.swift` | Toggle, `TrainBoardProviding`, `VictorianTrainProvider` factory |
| `PapaTransport/Services/PTV/PTVStopIDResolver.swift` | GTFS → PTV stop id mapping for favourites |

Six provider-selection call sites in `BusMapExplorerView`, `BusCard` and
`TrainMapExplorerView` now route through `VictorianTrainProvider.current`.
`CommutingSettingsView` gained a **PTV Timetable API** section with the toggle,
a Test Connection button, and the required CC BY attribution.

The flag is **off by default** and additionally gated on
`PTVCredentials.isConfigured`, so the GTFS path stays authoritative until
explicitly switched.

Verified against live data:

- Nearby board at Flinders Street returned 8 stations with correct real-time
  status (on-time / late / scheduled), platform data and destinations.
- Trip detail resolved stop position, earlier/remaining counts and terminal.
- Favourites stored under GTFS ids resolved and rendered departures, and trip
  detail still worked from those ids.
- Full project builds clean with no concurrency-isolation warnings.

### Favourites ID migration — implemented

`FavouriteBusStopStore` persists GTFS `stop_id`s, which do **not** match PTV
stop ids — and are not even numeric (`vic:rail:FSS`). `PTVStopIDResolver`
maps them by proximity plus normalised name match, stripping the decoration
that differs between the datasets ("Flinders Street Railway Station" →
"Flinders Street").

The mapping is stored **alongside** the favourites rather than rewriting them,
so turning the flag back off leaves the GTFS path intact. Unresolved ids are
cached as a sentinel so a failed lookup is not retried on every refresh.

Because a favourite's `NearbyBusStop.id` deliberately stays the GTFS id (so it
remains removable from the store), `fetchTripDetail` falls back to the cached
mapping when the id is not found in the PTV pattern.

Measured: 6/6 real Victorian stations resolved correctly, including two
different GTFS ids for Flinders Street both mapping to PTV `1071`.

---

## 6. Cross-cutting concerns

Build these into Phase 1 rather than retrofitting.

- **Rate limiting.** PTV does not document limits. The current design makes
  **one batched SQLite query + one GTFS-RT fetch** for the whole board; PTV
  requires **one signed call per stop**. Mitigations: cap concurrency
  (`withTaskGroup`, 4–6 in flight), cache departures per stop ~20–30 s, reuse
  the existing map-pan debounce, exponential backoff on 403/429.
- **Offline.** The SQLite schedule works with no network. PTV requires network
  plus a valid signature for everything. This is a genuine regression to accept
  consciously at Phase 5.
- **Graceful degradation.** Per project convention: no `try!`, no force
  unwraps; return empty/placeholder models on failure.
- **Attribution.** CC BY 4.0 requires a visible credit:
  *"Source: Licensed from Public Transport Victoria under a Creative Commons
  Attribution 4.0 International Licence."* Add to Settings/About.
- **Scope.** PTV is Victoria-only. The Queensland TransLink provider and
  `gtfs_seq.sqlite3` (420 MB) are unaffected.

---

## 7. Open questions

- [x] ~~Confirm the `route_type` enum values~~ — verified live; see §4.
- [x] ~~Does `departure_sequence` carry a real value?~~ — **No on
      `/v3/departures` (always 0), yes on `/v3/pattern` (1-based).** Stop
      position therefore requires the pattern call, as assumed.
- [ ] Confirm whether regional/V-Line coaches report as `2` or `3`.
- [ ] Do PTV station stop IDs make `siblingStopIds` (platform grouping)
      unnecessary? Likely a simplification.
- [ ] Observed rate-limit behaviour under a map-pan burst.
- [ ] Element shape of `skipped_stops` — every captured sample was a
      stopping-all-stations run, so it decodes leniently for now.

### Phase 3 — delivered

`PTVBoardService.victorianBus` (`route_type = 2`) is wired behind
`PTVFeatureFlags.isVictorianBusBoardEnabled` via `VictorianBusProvider.current`,
covering `BusMapExplorerView`, `BusCard` and `CommutingService`. Settings gained
a second toggle.

`TrainBoardProviding` was split: `FavouritesBoardProviding` (board + favourites)
is the shared base, and `TrainBoardProviding` adds the region query, because the
bus services have no region variant.

Three mode-specific differences surfaced during live testing:

1. **Radius.** A 300 m search — copied from `VictorianBusService`'s SQL query —
   returned *zero* PTV stops in the CBD, where the nearest bus stop is 463 m
   away. PTV stop coordinates are sparser than the GTFS table, so
   `nearbyStops` now widens once to `fallbackRadiusMeters` (800 m for bus) when
   the first search comes back empty.
2. **Time window.** `VictorianTrainMapService` boards only the next 2 hours,
   but `VictorianBusService` applies **no** window. Applying the train's window
   to bus hid tomorrow's first service on a late-night board. The window is now
   per-mode: 2 h for train, unbounded for bus.
3. **`run_ref` encoding.** Bus references contain hyphens
   (`35-234--1-Sat11-217836`). Percent-encoding them with `.alphanumerics`
   changed the signed string and PTV returned **403**. Encoding now preserves
   RFC 3986 unreserved characters. (Bus `run_id` is always `-1`, so `run_ref`
   is the only usable handle.)

**Known upstream limitation:** PTV returns 404 "Invalid run_ref" for stopping
patterns on a *future service day* — typically bus runs that roll past midnight.
`fetchTripDetail` maps that to `tripPatternUnavailable` so the UI degrades
gracefully instead of showing an HTTP error. Measured late at night: 2 of 6
trip details resolved, 4 gracefully unavailable, 0 hard failures. During normal
hours almost all departures are same-service-day and resolve.

### Phase 4 — delivered

`BusInfo.alerts` — previously always empty for Victorian modes — is now
populated for both train and bus.

**No extra requests.** The board already asks for `expand=Disruption` on each
departures call, so disruptions arrive with the data being fetched anyway.
`departureBoards` now collects them alongside the departures and they are
deduplicated by `disruption_id` across all stops on the board. A separate
`/v3/disruptions/stop/{id}` call per stop would have doubled the request count
for no benefit.

Mapping decisions, based on captured live data:

- **Filter on `display_on_board`.** PTV sets this flag to mean exactly "should
  this appear on a departure board", so it is used rather than a hand-rolled
  rule. Disruptions whose `to_date` has passed are also dropped.
- **Severity** derives from `disruption_type`, softened one level when
  `disruption_status` is `Planned`, since a scheduled future closure is less
  pressing than one in progress:
  - suspended / closure / cancelled → `.severe` (`.warning` if planned)
  - delay / works / detour / diversion / replacement → `.warning` (`.info` if planned)
  - anything else → `.info`
- Alerts are sorted most-severe first.
- **Duplicate text is suppressed.** PTV often repeats the title verbatim as the
  description, which would render the same sentence twice in `BusAlertRow`.
- A literal `"string"` placeholder appears in the `url` field of some records
  and is treated as absent.

Verified live at Flinders Street: 4 unique alerts across 8 stations — one
`severe` ("Part Suspended — buses replacing trains") and three `warning`
(planned works, station detour) — with correct SF Symbols and affected-route
lists.

### Favourites stop picker — rewired (2026-07-26)

`BusStopSettingsViews` previously queried the GTFS databases directly for map
pins. The two Victorian providers now resolve stops through
`PTVBoardService.stopsInRegion` whenever their board flag is on, so the picker
hands the board the same IDs it will later ask for. Queensland has no PTV
equivalent and always uses the bundled database.

**`/v3/stops/location` caps at 30 results** regardless of radius — measured, not
documented (radius 2 km, 5 km and 10 km all returned exactly 30, furthest
1087 m; the GTFS table holds 42 in the same 1 km box). A naive rewire would have
silently thinned the map when zoomed out.

`stopsInRegion` therefore subdivides: a region whose radius exceeds ~1.2 km is
split into four quadrants queried concurrently, then deduplicated by `stop_id`
and trimmed to the visible rectangle. Measured at Flinders Street:

| Map span | Single query | With subdivision |
|---|---|---|
| ~0.02° (few blocks) | 29 | 31 |
| ~0.08° (inner city) | 30 | **120** |
| ~0.30° (metro, train) | 30 | **101** |

Verified: no duplicates, nothing outside the requested bounds. Tight zooms still
cost one request; only wide ones cost four.

**Remaining limitation:** at metro-wide zoom bus stops cap at 120 (4 × 30)
versus the GTFS limit of 150. Deeper subdivision would close the gap at the cost
of more requests, and individual pins are not tappable at that zoom anyway.

### Route Planner replaced with Plan Lite (2026-07-26)

The GTFS-backed journey planner was the single feature with **no** migration
path — PTV has no journey-planner endpoint, and every planner query traversed
`stop_times`, the table that is ~90% of the 2.0 GB bus database.

It has been replaced by **Plan Lite** (`PlanLiteService` + a rewritten
`RoutePlannerView`), which uses MapKit and needs no bundled data:

- Transit / walking / driving estimates fetched concurrently for a tapped
  origin and destination.
- Walking and driving routes are drawn on the map; **transit shows an ETA
  only**, because `MKDirections.calculate()` with `.transit` always fails with
  `MKError.directionsNotFound` (verified). `calculateETA()` does work.
- "Open in Apple Maps" hands off the step-by-step itinerary, including which
  services to catch.

Measured live:

| Trip | Transit | Walk | Drive |
|---|---|---|---|
| Flinders St → Richmond | 10 min | 30 min | 7 min |
| Flinders St → Werribee | 55 min | 9h 55m | 33 min |
| Brisbane CBD → South Bank | 14 min | 27 min | 10 min |

Two things improved rather than regressed: the old planner was **Victorian bus
only** ("Bus trip planning is currently available for Victorian Transport
only"), whereas Plan Lite works in **every region** — Queensland included — and
it removed ~1,300 lines of code plus 585 lines of dead queries from
`VictorianBusGTFSDatabase`.

What was lost: the in-app itinerary — named routes, boarding stops, transfer
points and the drawn transit line. That detail now lives in Apple Maps.

**Database impact:** one of the three `stop_times` readers is gone. The bus
database still cannot be deleted — `VictorianBusService` (the board, until PTV
becomes the default) and `VictorianBusLocatorService` (Locate Me) still need it.

### Phase 5 — delivered (2026-07-26)

PTV is now the **only** source for Victorian train and bus. The feature flags,
the factories and both GTFS board services were removed rather than defaulted —
with nothing to fall back to, a flag would have been dead weight.

Deleted: `VictorianBusService`, `VictorianTrainMapService`,
`VictorianBusGTFSDatabase`, `VictorianTrainGTFSDatabase`, `PTVFeatureFlags`,
and `VictorianTrainRealtimeService`.

`FavouritesBoardProviding` / `TrainBoardProviding` moved into `BusModels.swift`
alongside `BusDataProviding`.

**The Transport Victoria Open Data GTFS-RT subscription is no longer used at
all** — PTV departures carry their own real-time, so that key and its settings
UI are gone. One fewer credential to manage.

**Result:**

| | Before | After |
|---|---|---|
| App bundle | ~2.6 GB | **444 MB** |
| Bundled databases | 3 | 1 (`gtfs_seq.sqlite3`, Queensland) |

The Victorian `.sqlite3` files were **moved to `_archive/`, not deleted** —
`PapaTransport/db/` is gitignored, so they are untracked and there is no
regeneration script in the repo. Moving them outside the
`PBXFileSystemSynchronizedRootGroup` stops Xcode bundling them while keeping the
data recoverable. Delete `_archive/` once you are confident.

**Consequence to accept:** Victoria now has no offline fallback. If PTV is
unreachable or the key is revoked, Victorian departures stop working. Queensland
is unaffected — it still runs entirely on bundled GTFS.

### Trams added (2026-07-26)

Melbourne trams (`route_type = 1`) are now a **Victoria-only tab**, reusing
`BusMapExplorerView` for full parity with the Bus tab — map, nearby stops,
favourites, departures, trip detail, route search and auto-refresh.

Implementation was small because `PTVBoardService` is parameterised by route
type: a `victorianTramPTV` case on `BusProvider`, a `PTVBoardService.victorianTram`
instance, four switch branches, a tab and a settings section.

**Tab tagging:** Trams takes tag **3** while Plan keeps tag **2**, so the tags
stay stable when the tab disappears outside Victoria. An `onChange(of:
transportRegion)` resets selection to Bus if the user leaves Victoria while on
Trams, which would otherwise show an empty `TabView`.

Tram stops sit closer together than bus stops, so the search radius is tighter
(250 m, widening to 600 m) — same request budget, denser results.

Measured live at Flinders Street, 2:44 PM:

| Check | Result |
|---|---|
| Nearby stops | 5 within 250 m |
| Real-time | **Working** — On Time / Early / Late with live predictions |
| Trip detail | **5/5 resolved**, 0 failures |
| Stop picker region query | 106 tram stops |
| Favourites path | OK |

This also **settles the earlier open question** about tram real-time. The 6% seen
at 00:30 was the hour, not the mode: in the afternoon trams report live
predictions as richly as trains. Note trams needed **no bundled data of any
kind** — the only mode added at zero app-size cost.

## 8. Findings from the live shape capture (2026-07-25)

Real payloads were captured for routes, nearby stops, departures, stopping
patterns and disruptions (both modes), and `PTVModels.swift` is now validated
against them rather than guessed.

- **`/v3/stops/location` returns the routes serving each stop inline.** A
  nearby-stops call yields stop *and* route data in one request, removing the
  need for a `routesAtStopToday()` equivalent. This materially reduces the
  per-stop call count that §6 flags as the main scaling risk.
- **`disruptions` is polymorphic**: an object keyed by id on `/v3/departures`,
  a plain array on `/v3/pattern`. The envelope normalises both.
- **`vehicle_position` and `vehicle_descriptor` are `null`** for metro train
  runs. PTV therefore offers no live vehicle coordinates, reinforcing that
  Locate Me cannot migrate off local GTFS data.
- **`max_results` is per route+direction, not global** — `max_results=2`
  returned 40 departures at Flinders Street.
- Extra fields available if wanted: `stop_landmark`, `route_service_status`,
  `geopath` (route geometry), and `interchange` (feeder/distributor run links
  for trains).
