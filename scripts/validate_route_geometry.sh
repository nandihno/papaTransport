#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK" <<'PY'
import pathlib, sqlite3, sys, zipfile
root = pathlib.Path(sys.argv[1])
files = {
    "stops.txt": "stop_id,stop_name,stop_code,stop_lat,stop_lon,location_type,parent_station\ns1,One,1,-27.1,153.1,0,\ns2,Two,2,-27.3,153.3,0,\n",
    "routes.txt": "route_id,route_short_name,route_long_name,route_type\nb,100,Bus,3\nr,RED,Train,2\n",
    "trips.txt": "trip_id,route_id,service_id,trip_headsign,direction_id,shape_id\nbus-trip,b,daily,City,0,b-shape\ntrain-trip,r,daily,Coast,1,r-shape\n",
    "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\nbus-trip,10:00:00,10:00:00,s1,1\nbus-trip,10:30:00,10:30:00,s2,2\ntrain-trip,11:00:00,11:00:00,s1,1\ntrain-trip,11:30:00,11:30:00,s2,2\n",
    "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\ndaily,1,1,1,1,1,1,1,20000101,21000101\n",
    "calendar_dates.txt": "service_id,date,exception_type\ndaily,20000101,1\n",
    "shapes.txt": "shape_pt_sequence,shape_id,shape_pt_lon,shape_pt_lat\n3,b-shape, 153.3, -27.3\n1,b-shape, 153.1, -27.1\n2,b-shape, 153.2, -27.2\n2,r-shape,153.5,-27.5\n1,r-shape,153.4,-27.4\n",
}
invalid = [
    ("garbage-lat", "garbage", "153.2", "2"),
    ("garbage-lon", "-27.2", "garbage", "2"),
    ("nonfinite-lat", "NaN", "153.2", "2"),
    ("nonfinite-lon", "-27.2", "Infinity", "2"),
    ("overflow-lat", "1e999", "153.2", "2"),
    ("range-lat", "91", "153.2", "2"),
    ("range-lon", "-27.2", "181", "2"),
    ("negative-sequence", "-27.2", "153.2", "-1"),
    ("fraction-sequence", "-27.2", "153.2", "2.5"),
    ("huge-sequence", "-27.2", "153.2", "999999999999999999999999999999"),
    ("missing-sequence", "-27.2", "153.2", ""),
    ("garbage-sequence", "-27.2", "153.2", "two"),
]
for shape, lat, lon, sequence in invalid:
    files["trips.txt"] += f"{shape},b,daily,City,0,{shape}\n"
    files["shapes.txt"] += f"1,{shape},153.1,-27.1\n{sequence},{shape},{lon},{lat}\n3,{shape},153.3,-27.3\n"
(root / "invalid-shapes.txt").write_text("\n".join(row[0] for row in invalid))
for include in [True, False]:
    with zipfile.ZipFile(root / ("with-shapes.zip" if include else "without-shapes.zip"), "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            if name == "shapes.txt" and not include:
                continue
            if name == "trips.txt" and not include:
                content = "\n".join(",".join(line.split(",")[:-1]) for line in content.splitlines()) + "\n"
            archive.writestr(name, content)
db = sqlite3.connect(root / "legacy.sqlite3")
db.execute("CREATE TABLE trips (trip_id TEXT)")
db.close()
db = sqlite3.connect(root / "malformed.sqlite3")
db.executescript("""
CREATE TABLE trips (trip_id TEXT, shape_id TEXT);
CREATE TABLE shapes (shape_id TEXT, shape_pt_lat REAL, shape_pt_lon REAL, shape_pt_sequence INTEGER);
INSERT INTO trips VALUES ('bad-coordinate','a'), ('bad-sequence','b'), ('duplicate-sequence','c');
INSERT INTO shapes VALUES ('a',-27.1,153.1,1), ('a','garbage',153.2,2), ('a',-27.3,153.3,3);
INSERT INTO shapes VALUES ('b',-27.1,153.1,-1), ('b',-27.2,153.2,2);
INSERT INTO shapes VALUES ('c',-27.1,153.1,1), ('c',-27.2,153.2,1);
""")
db.close()
PY

# Add a private test opener to a scratch copy; production DB locations
# and user data are never touched by the checks.
cp "$REPO_ROOT/PapaTransport/Services/GTFSDatabase.swift" "$WORK/GTFSDatabase.swift"
cat >> "$WORK/GTFSDatabase.swift" <<'SWIFT'

extension GTFSDatabase {
    func openForValidation(_ validationPath: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(validationPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw GTFSDBError.openFailed
        }
        db = handle
        isImported = true
    }
}
SWIFT

xcrun swiftc -module-cache-path "$WORK/module-cache" -parse-as-library \
    "$REPO_ROOT/PapaTransport/Models/GTFSSharedModels.swift" \
    "$REPO_ROOT/PapaTransport/Services/GTFSDownloadProgress.swift" \
    "$REPO_ROOT/PapaTransport/Services/GTFS/CSVRowReader.swift" \
    "$REPO_ROOT/PapaTransport/Services/GTFS/ZipArchive.swift" \
    "$REPO_ROOT/PapaTransport/Services/GTFS/GTFSFeedImporter.swift" \
    "$REPO_ROOT/PapaTransport/Services/PTV/PTVModels.swift" \
    "$REPO_ROOT/PapaTransport/Services/PTV/PTVGeopath.swift" \
    "$WORK/GTFSDatabase.swift" \
    "$REPO_ROOT/scripts/validate_route_geometry.swift" -o "$WORK/checks"
"$WORK/checks" "$WORK"

# Run the real shell builder in an isolated repository-shaped directory.
mkdir -p "$WORK/builder/scripts"
cp "$REPO_ROOT/scripts/build_seq_db.sh" "$WORK/builder/scripts/"
for fixture in with-shapes without-shapes; do
    bash "$WORK/builder/scripts/build_seq_db.sh" "$WORK/$fixture.zip" > "$WORK/builder.log"
    DB="$WORK/builder/PapaTransport/db/transport/queensland/gtfs_seq.sqlite3"
    actual=$(sqlite3 "$DB" "SELECT COUNT(*) FROM shapes;")
    if [[ "$fixture" == with-shapes ]]; then expected=5; else expected=0; fi
    [[ "$actual" == "$expected" ]]
    [[ $(sqlite3 "$DB" "SELECT COUNT(*) FROM shapes WHERE shape_id NOT IN ('b-shape', 'r-shape');") == 0 ]]
done
echo "Passed: shell database builder with reordered columns, optional shapes/shape_id, strict numeric validation and whole-shape rejection for malformed points."
