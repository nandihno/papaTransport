# How Locate Me Works

This document explains how the PapaTransport **Locate Me** train tab works so future agents can safely modify it.

The current Locate Me feature is foreground-only. It runs while the user has the Locate tab open, listens to live device location updates, compares the phone location against train timetable data, and estimates:

- whether the user is at or near a station;
- the station the train has just left;
- the next station;
- the train destination;
- minutes to the next station;
- confidence and fallback warnings.

Locate Me currently supports Victorian trains and Queensland trains. Buses are intentionally out of scope.

## Main Files

- `PapaTransport/Views/Train/TrainLocateMeView.swift`
  - Owns the Locate Me UI.
  - Starts and stops live foreground location tracking.
  - Chooses the Victorian or Queensland locator service based on `transportMode`.
  - Displays previous station, next station, destination, confidence, timing, and explanations.

- `PapaTransport/Services/TrainLocationTracker.swift`
  - Foreground Core Location tracker for Locate Me.
  - Uses `CLLocationManager`.
  - Requests when-in-use permission.
  - Stops tracking when the Locate tab disappears.

- `PapaTransport/Models/TrainLocateModels.swift`
  - Shared Locate Me result and confidence models.
  - Used by both Victorian and Queensland locator services.

- `PapaTransport/Services/VictorianTrainLocatorService.swift`
  - Victorian train matching and scoring.
  - Uses `VictorianTrainGTFSDatabase`.
  - Uses `VictorianTrainRealtimeService`.

- `PapaTransport/Services/QueenslandTrainLocationService.swift`
  - Queensland train matching and scoring.
  - Uses `GTFSDatabase`, which contains the Queensland GTFS database.
  - Uses `QueenslandTrainRealtimeService`.

- `PapaTransport/Services/VictorianTrainGTFSDatabase.swift`
  - Victorian train GTFS SQLite access.
  - Provides train routes, active trip candidates, trip patterns, stations, departures, and related train queries.

- `PapaTransport/Services/GTFSDatabase.swift`
  - Queensland GTFS SQLite access.
  - Also still powers Queensland buses, so changes here can affect more than trains.
  - Provides Queensland rail station, route, active trip candidate, trip pattern, and departure queries.

## User Flow

1. The user opens the Locate tab.
2. `TrainLocateMeView` starts `TrainLocationTracker`.
3. The view loads train routes for the active region:
   - Victoria: `VictorianTrainLocatorService.availableRoutes()`
   - Queensland: `QueenslandTrainLocationService.availableRoutes()`
4. Each new device location triggers a locate attempt.
5. The view calls the matching service for the selected region:
   - Victoria: `VictorianTrainLocatorService.locate(...)`
   - Queensland: `QueenslandTrainLocationService.locate(...)`
6. The service returns a `TrainLocateResult`.
7. The UI shows the best estimate and, when useful, other possible train matches.

## Data Inputs

The locator uses:

- current device latitude and longitude;
- current local time for the selected transport region;
- selected line, if the user chooses one;
- selected direction override, if the user chooses one;
- active GTFS services for today;
- active trip candidates around the current time;
- stop order for each candidate trip;
- station coordinates;
- GTFS-RT trip delay when available;
- device GPS accuracy;
- device course and speed when available.

There are no GTFS `shapes` in the current database. Because of that, Locate Me approximates train position using straight station-to-station segments, not exact track geometry.

## Matching Rules

The locator does not simply pick the nearest station. It scores possible trips and station segments.

### Candidate Trip Selection

The service first asks the database for active train trips:

- service must be active today;
- trip must be running near the current local time;
- route must match the selected line if the user picked one;
- direction must match the selected direction override if the user picked one.

If no line is selected, the service compares multiple routes. This is allowed, but confidence can be lower, especially on shared corridors.

### Station Detection

For each candidate trip, the locator finds the closest station in that trip pattern.

If the phone is close enough to a station, the result is treated as **at or near station** instead of “just left”.

The station threshold is:

- minimum 160 metres;
- maximum 300 metres;
- scaled by reported GPS accuracy.

This avoids saying “you just left X” when the user is actually still at X.

### Between-Station Detection

If the user is not close enough to a station, the service checks each adjacent station pair in the trip pattern:

- project the phone location onto the straight line between the two stations;
- measure distance from the phone to that segment;
- compare current time with the scheduled time window for that segment;
- optionally compare device movement bearing with the segment bearing;
- penalize being far before the first station or far past the next station.

The best-scoring segment becomes:

- previous station: segment start;
- next station: segment end.

### Realtime Delay

If GTFS-RT trip update data is available, trip delay is added to scheduled station times before scoring.

If realtime data is unavailable, Locate Me still works using scheduled GTFS times. The result is less live but still useful.

### Confidence

Confidence is derived from the final score:

- High: score >= 75
- Medium: score >= 55
- Low: below 55

Warnings are shown when:

- no line is selected and several trains could match;
- the best and second-best candidates are close in score;
- confidence is low;
- the phone appears far from the selected corridor.

### Corridor Rejection

The service rejects a match if the best candidate is too far from the route:

- distance from estimated corridor must be within about 1.8 km, or
- score must still be high enough to justify the estimate.

This prevents the app from confidently showing a train position when the user is not near a plausible rail corridor.

## Direction Rules

The shared UI exposes three direction choices:

- Auto
- Away / Direction 1
- City / Direction 2

The meaning differs by region.

### Victoria

Victoria uses app-friendly direction wording:

- `Auto`: do not filter by GTFS direction.
- `Away`: use direction id `0`.
- `City`: use direction id `1`.

Victorian UI copy explains this as:

- City means travelling towards Flinders Street.
- Away means travelling out from the city.

Victorian result direction text is:

- direction id `1`: `towards the city`
- direction id `0`: `away from the city`

This is Melbourne-specific and assumes Flinders Street is the city anchor.

### Queensland

Queensland does not currently use the Melbourne-style city/away wording.

Queensland UI copy uses:

- `Auto`
- `Direction 1`
- `Direction 2`

The direction ids still map through the shared override model:

- `Direction 1`: direction id `0`
- `Direction 2`: direction id `1`

Queensland result direction text currently prefers the terminal station:

- `towards <terminal station>`

This avoids incorrectly implying that one direction is always “city” or “away”. Queensland services and naming are different from Melbourne, and a future refinement should use TransLink-specific route/direction terminology if available.

## Victoria Versus Queensland

### Database

Victoria:

- Database actor: `VictorianTrainGTFSDatabase`
- Bundled database: `gtfs_victorian_train.sqlite3`
- Train route type used by locator: `400`
- Excludes `Replacement Bus`
- Local time zone: `Australia/Melbourne`

Queensland:

- Database actor: `GTFSDatabase`
- Bundled database: `gtfs_seq.sqlite3`
- Train route type used by locator: `2`
- Same database also powers Queensland buses
- Local time zone: `Australia/Brisbane`

Be careful when changing `GTFSDatabase`: it is shared between Queensland buses and Queensland trains.

### Realtime

Victoria:

- Realtime service: `VictorianTrainRealtimeService`
- Uses Victorian Open Data GTFS-RT train trip updates.
- Requires the configured Victorian realtime API key.
- If no key is available, Locate Me falls back to schedule-only matching.

Queensland:

- Realtime service: `QueenslandTrainRealtimeService`
- Uses TransLink SEQ rail GTFS-RT trip updates.
- No app API key is currently required in the service.
- If the feed is unavailable, Locate Me falls back to schedule-only matching.

### Saved Line Behavior

Victoria:

- The Locate tab may use the saved `trainLineName` from settings.
- The picker shows `Saved: <line>` when a saved line exists.

Queensland:

- The Locate tab does not reuse the saved Victorian `trainLineName`.
- It starts in `Auto detect`.
- The user can manually pick a Queensland rail route from the Queensland route list.

This avoids accidentally filtering Queensland candidate trips by a Victorian line name.

### UI Text

Victoria:

- Uses city/away wording.
- Mentions Flinders Street in helper text.

Queensland:

- Uses neutral Direction 1 / Direction 2 wording.
- Uses terminal station wording in results.

Do not copy Victorian city/away assumptions into Queensland without checking the data model and user expectations.

## Important Limitations

- Locate Me only runs in the foreground while the tab is open.
- It does not send background wake-up alerts.
- It assumes the user is on a train.
- It does not handle buses.
- It does not use exact track geometry because GTFS shapes are not currently available.
- Shared rail corridors can reduce confidence.
- Poor GPS accuracy can reduce confidence or produce uncertain matches.
- A stopped train between stations can be harder to distinguish from a nearby station or nearby corridor.

## Safe Change Guidelines

- Keep Victoria and Queensland behavior region-specific unless intentionally refactoring both behind a shared abstraction.
- Preserve the shared `TrainLocateResult` model unless the UI must change.
- Do not make Queensland use Victorian saved line names.
- Do not apply Melbourne city/away wording to Queensland.
- When touching `GTFSDatabase`, regression-check Queensland bus behavior because buses share that database actor.
- When touching `VictorianTrainGTFSDatabase`, regression-check Victorian train map and departure behavior.
- Prefer scheduled fallback when realtime data is missing; do not fail Locate Me only because GTFS-RT is unavailable.
- Keep location tracking foreground-only unless the product scope explicitly changes.

## Future Refactor Direction

The Victorian and Queensland locator services intentionally duplicate some scoring logic today. That was done to get Queensland support working without a broad refactor.

A future refactor could introduce a shared protocol, for example:

```swift
protocol TrainLocating {
    associatedtype Route

    func availableRoutes() async throws -> [Route]
    func locate(
        location: CLLocation,
        selectedLineName: String,
        directionOverride: TrainLocateDirectionOverride
    ) async throws -> TrainLocateResult
}
```

The scoring code could then be shared behind region adapters that provide:

- current local seconds after midnight;
- route query;
- active trip candidate query;
- trip pattern query;
- realtime trip updates;
- direction wording.

Do this only when both regions are stable enough that shared abstractions will reduce risk rather than hide region-specific rules.
