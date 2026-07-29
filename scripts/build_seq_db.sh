#!/usr/bin/env bash
#
# Rebuild the bundled Queensland (SEQ/TransLink) GTFS database.
#
# TransLink publishes no timetable query API — only a static GTFS zip and
# GTFS-realtime overlays — so the schedule has to live in a local database.
# This script is the reproducible way to produce it.
#
# The output schema must stay byte-compatible with what GTFSDatabase.swift
# expects, including two non-obvious details:
#   * stop_times carries precomputed *_seconds columns (seconds since local
#     midnight, and GTFS legitimately exceeds 86400 for after-midnight trips).
#   * stops.route_type is denormalised to 3 for bus stops only; everything
#     else — including every rail stop — keeps -1. Rail must be filtered by
#     joining through routes. See CLAUDE.md.
#
# Usage:
#   scripts/build_seq_db.sh              # download the current feed and build
#   scripts/build_seq_db.sh path/to.zip  # build from an already-downloaded zip
#
set -euo pipefail

FEED_URL="https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/PapaTransport/db/transport/queensland/gtfs_seq.sqlite3"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v sqlite3 >/dev/null || { echo "error: sqlite3 not found"; exit 1; }

# ---------------------------------------------------------------- fetch

if [[ $# -ge 1 ]]; then
    ZIP="$1"
    [[ -f "$ZIP" ]] || { echo "error: no such file: $ZIP"; exit 1; }
    echo "==> Using local zip: $ZIP"
else
    ZIP="$WORK/SEQ_GTFS.zip"
    echo "==> Downloading $FEED_URL"
    curl -fSL --progress-bar -o "$ZIP" "$FEED_URL"
    published=$(curl -sI "$FEED_URL" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
    [[ -n "$published" ]] && echo "    feed published: $published"
fi

echo "==> Extracting"
unzip -q -o "$ZIP" -d "$WORK/gtfs"
for required in stops routes trips stop_times calendar calendar_dates; do
    [[ -f "$WORK/gtfs/$required.txt" ]] || { echo "error: $required.txt missing from feed"; exit 1; }
done

# ---------------------------------------------------------------- build

DB="$WORK/gtfs_seq.sqlite3"
echo "==> Building SQLite database"

# Stage each file into a raw_* table first. sqlite3's --csv import derives the
# staging columns from the header row, so the real INSERTs below can select by
# column *name* and stay correct if TransLink reorders or adds columns.
sqlite3 "$DB" <<SQL
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
.mode csv
.import '$WORK/gtfs/stops.txt'          raw_stops
.import '$WORK/gtfs/routes.txt'         raw_routes
.import '$WORK/gtfs/trips.txt'          raw_trips
.import '$WORK/gtfs/stop_times.txt'     raw_stop_times
.import '$WORK/gtfs/calendar.txt'       raw_calendar
.import '$WORK/gtfs/calendar_dates.txt' raw_calendar_dates
SQL

sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TABLE stops (
    stop_id TEXT PRIMARY KEY,
    stop_name TEXT NOT NULL,
    stop_code TEXT,
    stop_lat REAL NOT NULL,
    stop_lon REAL NOT NULL,
    location_type INTEGER DEFAULT 0,
    parent_station TEXT,
    route_type INTEGER DEFAULT -1
);
CREATE TABLE routes (
    route_id TEXT PRIMARY KEY,
    route_short_name TEXT,
    route_long_name TEXT,
    route_type INTEGER NOT NULL
);
CREATE TABLE trips (
    trip_id TEXT PRIMARY KEY,
    route_id TEXT NOT NULL,
    service_id TEXT NOT NULL,
    trip_headsign TEXT,
    direction_id INTEGER DEFAULT 0
);
CREATE TABLE stop_times (
    trip_id TEXT NOT NULL,
    stop_id TEXT NOT NULL,
    arrival_time TEXT,
    departure_time TEXT,
    stop_sequence INTEGER NOT NULL,
    arrival_seconds INTEGER,
    departure_seconds INTEGER
);
CREATE TABLE calendar (
    service_id TEXT PRIMARY KEY,
    monday INTEGER, tuesday INTEGER, wednesday INTEGER,
    thursday INTEGER, friday INTEGER, saturday INTEGER, sunday INTEGER,
    start_date TEXT, end_date TEXT
);
CREATE TABLE calendar_dates (
    service_id TEXT NOT NULL,
    date TEXT NOT NULL,
    exception_type INTEGER NOT NULL
);

INSERT OR REPLACE INTO stops
SELECT stop_id, stop_name, NULLIF(stop_code, ''),
       CAST(stop_lat AS REAL), CAST(stop_lon AS REAL),
       CAST(NULLIF(location_type, '') AS INTEGER),
       NULLIF(parent_station, ''),
       -1
FROM raw_stops
WHERE NULLIF(stop_lat, '') IS NOT NULL AND NULLIF(stop_lon, '') IS NOT NULL;

INSERT OR REPLACE INTO routes
SELECT route_id, NULLIF(route_short_name, ''), NULLIF(route_long_name, ''),
       CAST(route_type AS INTEGER)
FROM raw_routes;

INSERT OR REPLACE INTO trips
SELECT trip_id, route_id, service_id, NULLIF(trip_headsign, ''),
       CAST(NULLIF(direction_id, '') AS INTEGER)
FROM raw_trips;

-- HH:MM:SS -> seconds since midnight. Sliced from the right so both "7:05:00"
-- and the after-midnight "24:04:00" parse correctly; blanks stay NULL.
INSERT INTO stop_times
SELECT trip_id, stop_id,
       NULLIF(arrival_time, ''), NULLIF(departure_time, ''),
       CAST(stop_sequence AS INTEGER),
       CASE WHEN arrival_time = '' THEN NULL ELSE
            CAST(substr(arrival_time, 1, length(arrival_time) - 6) AS INTEGER) * 3600
          + CAST(substr(arrival_time, -5, 2) AS INTEGER) * 60
          + CAST(substr(arrival_time, -2, 2) AS INTEGER) END,
       CASE WHEN departure_time = '' THEN NULL ELSE
            CAST(substr(departure_time, 1, length(departure_time) - 6) AS INTEGER) * 3600
          + CAST(substr(departure_time, -5, 2) AS INTEGER) * 60
          + CAST(substr(departure_time, -2, 2) AS INTEGER) END
FROM raw_stop_times;

INSERT OR REPLACE INTO calendar
SELECT service_id,
       CAST(monday AS INTEGER), CAST(tuesday AS INTEGER), CAST(wednesday AS INTEGER),
       CAST(thursday AS INTEGER), CAST(friday AS INTEGER), CAST(saturday AS INTEGER),
       CAST(sunday AS INTEGER), start_date, end_date
FROM raw_calendar;

INSERT INTO calendar_dates
SELECT service_id, date, CAST(exception_type AS INTEGER) FROM raw_calendar_dates;

-- The denormalisation GTFSDatabase relies on: bus stops only.
UPDATE stops SET route_type = 3 WHERE stop_id IN (
    SELECT DISTINCT st.stop_id
    FROM stop_times st
    JOIN trips t  ON t.trip_id  = st.trip_id
    JOIN routes r ON r.route_id = t.route_id
    WHERE r.route_type = 3
);

DROP TABLE raw_stops;
DROP TABLE raw_routes;
DROP TABLE raw_trips;
DROP TABLE raw_stop_times;
DROP TABLE raw_calendar;
DROP TABLE raw_calendar_dates;

CREATE INDEX idx_stop_times_stop ON stop_times(stop_id, departure_seconds);
CREATE INDEX idx_stop_times_trip ON stop_times(trip_id);
CREATE INDEX idx_trips_route ON trips(route_id);
CREATE INDEX idx_trips_service ON trips(service_id);
CREATE INDEX idx_stops_location ON stops(stop_lat, stop_lon);
CREATE INDEX idx_calendar_dates_date ON calendar_dates(date);

VACUUM;
-- Populates sqlite_stat1 so the planner picks the right index on the 2.7M-row
-- stop_times table. The only schema difference from a hand-built database.
ANALYZE;
SQL

# ---------------------------------------------------------------- verify

echo "==> Verifying"
fail=0
check() {
    local label="$1" actual="$2" min="$3"
    if [[ "$actual" -lt "$min" ]]; then
        echo "    FAIL  $label = $actual (expected >= $min)"; fail=1
    else
        printf "    ok    %-22s %s\n" "$label" "$actual"
    fi
}
for t in stops routes trips stop_times calendar; do
    check "$t" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM $t;")" 1
done
check "bus stops (route_type=3)" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM stops WHERE route_type = 3;")" 1
check "rail stops (via routes)" "$(sqlite3 "$DB" \
    "SELECT COUNT(DISTINCT st.stop_id) FROM stop_times st
       JOIN trips t ON t.trip_id = st.trip_id
       JOIN routes r ON r.route_id = t.route_id
      WHERE r.route_type = 2;")" 1

valid_from=$(sqlite3 "$DB" "SELECT MIN(start_date) FROM calendar;")
valid_to=$(sqlite3 "$DB"   "SELECT MAX(end_date)   FROM calendar;")
today=$(date +%Y%m%d)
if [[ "$today" < "$valid_from" || "$today" > "$valid_to" ]]; then
    echo "    FAIL  feed does not cover today ($today)"; fail=1
else
    echo "    ok    covers today          $today"
fi

[[ $fail -eq 0 ]] || { echo "==> Build FAILED verification, not installing"; exit 1; }

# ---------------------------------------------------------------- install

mkdir -p "$(dirname "$DEST")"

# The backup must NOT live beside the database. PapaTransport/db/ is an Xcode
# synchronized file group, so anything dropped in there is copied into the app
# bundle — a stray .backup would silently add ~320 MB to the shipped app.
BACKUP_DIR="$REPO_ROOT/_archive/queensland-backups"
if [[ -f "$DEST" ]]; then
    mkdir -p "$BACKUP_DIR"
    BACKUP="$BACKUP_DIR/gtfs_seq-$(date +%Y%m%d-%H%M%S).sqlite3"
    mv "$DEST" "$BACKUP"
    echo "==> Previous database moved to ${BACKUP#$REPO_ROOT/}"
fi
mv "$DB" "$DEST"

# Provenance record sitting alongside the database. Nothing reads it at
# runtime, but a stale manifest is worse than none — it would misreport the
# checksum of whatever database is actually installed.
echo "==> Writing manifest.json"
{
    printf '{\n'
    printf '  "dataset": "queensland-bus",\n'
    printf '  "sourceUrl": "%s",\n' "$FEED_URL"
    printf '  "modeFolder": "SEQ",\n'
    printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    printf '  "sqliteFile": "gtfs_seq.sqlite3",\n'
    printf '  "sha256": "%s",\n' "$(shasum -a 256 "$DEST" | cut -d' ' -f1)"
    printf '  "validFrom": "%s",\n' "$valid_from"
    printf '  "validTo": "%s",\n' "$valid_to"
    printf '  "rowCounts": {\n'
    first=1
    for t in stops routes trips stop_times calendar calendar_dates; do
        [[ $first -eq 1 ]] || printf ',\n'
        first=0
        printf '    "%s": %s' "$t" "$(sqlite3 "$DEST" "SELECT COUNT(*) FROM $t;")"
    done
    printf '\n  },\n'
    printf '  "notes": [\n'
    printf '    "Built by scripts/build_seq_db.sh from the TransLink South East Queensland GTFS static ZIP.",\n'
    printf '    "Schema and index names match the contract in GTFSDatabase.swift and GTFSFeedImporter.swift."\n'
    printf '  ]\n'
    printf '}\n'
} > "$(dirname "$DEST")/manifest.json"

echo
echo "==> Done: $DEST"
echo "    size:  $(du -h "$DEST" | cut -f1)"
echo "    valid: $valid_from -> $valid_to"
echo
echo "    The app will stop returning departures the day after $valid_to."
echo "    Rerun this script before then, or let the in-app refresh handle it."
