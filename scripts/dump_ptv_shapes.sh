#!/usr/bin/env bash
#
# Captures real PTV Timetable API v3 response shapes so PTVModels.swift can be
# tightened against ground truth instead of guessed field names.
#
# Credentials stay on this machine — they are read from the environment and
# only ever sent to timetableapi.ptv.vic.gov.au.
#
# Usage:
#   export PTV_DEVID=...
#   export PTV_APIKEY=...
#   ./scripts/dump_ptv_shapes.sh [output_dir]
#
set -euo pipefail

BASE="https://timetableapi.ptv.vic.gov.au"
OUT="${1:-./ptv-shapes}"

: "${PTV_DEVID:?Set PTV_DEVID to your userID}"
: "${PTV_APIKEY:?Set PTV_APIKEY to your API key}"

mkdir -p "$OUT"

sign_url() {
  local endpoint="$1"
  local sep="?"
  [[ "$endpoint" == *\?* ]] && sep="&"
  local request="${endpoint}${sep}devid=${PTV_DEVID}"
  local sig
  sig=$(printf '%s' "$request" \
        | openssl dgst -sha1 -hmac "$PTV_APIKEY" \
        | sed 's/^.*= //' \
        | tr '[:lower:]' '[:upper:]')
  printf '%s%s&signature=%s' "$BASE" "$request" "$sig"
}

capture() {
  local name="$1" endpoint="$2"
  local url; url="$(sign_url "$endpoint")"
  local body code
  body=$(curl -sS -w $'\n%{http_code}' "$url")
  code=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq '.' > "$OUT/$name.json" 2>/dev/null || printf '%s' "$body" > "$OUT/$name.json"
  else
    printf '%s' "$body" > "$OUT/$name.json"
  fi

  printf '%-26s HTTP %-4s → %s\n' "$name" "$code" "$OUT/$name.json"

  # Print the top-level keys of the first object in each collection so field
  # names are visible without opening the files.
  if command -v jq >/dev/null 2>&1 && [[ "$code" == "200" ]]; then
    jq -r '
      to_entries[]
      | select(.value | (type == "array" and length > 0) or (type == "object" and length > 0))
      | "    \(.key): " + (
          if (.value | type) == "array" then (.value[0] | keys | join(", "))
          else (.value | to_entries[0].value | if type == "object" then (keys | join(", ")) else tostring end)
          end
        )
    ' "$OUT/$name.json" 2>/dev/null | head -8 || true
  fi
}

echo "Capturing PTV response shapes into $OUT/"
echo ""

capture "route_types"       "/v3/route_types"
capture "routes_train"      "/v3/routes?route_types=0"
capture "routes_bus"        "/v3/routes?route_types=2"

# Flinders Street — a stop guaranteed to have train departures.
capture "departures_train"  "/v3/departures/route_type/0/stop/1071?max_results=3&expand=Route&expand=Direction&expand=Run&expand=Disruption"
capture "disruptions_stop"  "/v3/disruptions/stop/1071"

# Melbourne CBD coordinates — exercises the nearby-stops endpoint for both modes.
capture "stops_near_train"  "/v3/stops/location/-37.8183,144.9671?route_types=0&max_distance=500"
capture "stops_near_bus"    "/v3/stops/location/-37.8183,144.9671?route_types=2&max_distance=500"

echo ""
echo "Now grab a run_ref from departures_train.json and capture a stopping pattern:"
echo "  ./scripts/dump_ptv_shapes.sh  # then:"
echo "  RUN_REF=<ref>; curl -sS \"\$(…)\"  # or add a capture line for /v3/pattern/run/\$RUN_REF/route_type/0"
