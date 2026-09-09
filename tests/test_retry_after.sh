#!/usr/bin/env bash
# Retry-After on the usage endpoint:
#  - a 429 with the header persists .retry_at and reports the wait
#  - a live .retry_at keeps the API untouched, --refresh included
#  - an expired .retry_at asks again; a 200 clears the marker
#  - the header is read as seconds AND as an HTTP-date, and it is clamped
#  - a 429 without the header behaves as before (no marker)
source "$(dirname "$0")/lib.sh"

export CLAUDEBAR_TEST_NET_QUICK_BUDGET=1
export CLAUDEBAR_TEST_NET_LONG_BUDGET=1
export CLAUDEBAR_TEST_NET_RETRY_DELAY=1

USAGE='{"five_hour":{"utilization":42,"resets_at":"2100-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2100-01-01T00:00:00Z"}}'
FRESH='{"five_hour":{"utilization":7,"resets_at":"2100-01-01T00:00:00Z"},"seven_day":{"utilization":8,"resets_at":"2100-01-01T00:00:00Z"}}'

# One stub for every case: counts calls, answers $STUB_CODE, and writes the
# response headers to the file behind `-D` the way curl does.
STUB='#!/usr/bin/env bash
cnt="$HOME/.curl_count"
n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$cnt"
hdr=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-D" ]] && hdr="$a"
    prev="$a"
done
if [[ -n "$hdr" ]]; then
    printf "HTTP/2 %s\r\n" "$STUB_CODE" > "$hdr"
    [[ -n "${STUB_RETRY_AFTER:-}" ]] && printf "retry-after: %s\r\n" "$STUB_RETRY_AFTER" >> "$hdr"
    printf "content-type: application/json\r\n\r\n" >> "$hdr"
fi
printf "%s\n%s" "${STUB_BODY:-}" "$STUB_CODE"
'

# _run <cache-spec: old|none> <retry_at-spec: none|future|past> [args...]
_run_ra() {
    local cache_spec="$1" ra_spec="$2"; shift 2
    THOME="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$THOME/.claude" "$THOME/.cache/claudebar" "$THOME/bin" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$STUB" > "$THOME/bin/curl" && chmod +x "$THOME/bin/curl" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '#!/usr/bin/env bash\nexit 0\n' > "$THOME/bin/notify-send" && chmod +x "$THOME/bin/notify-send"
    printf '%s' "$VALID_CREDS" > "$THOME/.claude/.credentials.json" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    local now; now=$(date +%s)
    if [[ "$cache_spec" == "old" ]]; then
        printf '%s' "$USAGE" > "$THOME/.cache/claudebar/usage.json"
        touch -d "@$(( now - 1200 ))" "$THOME/.cache/claudebar/usage.json"
    fi
    case "$ra_spec" in
        future) printf '%s' "$(( now + 600 ))" > "$THOME/.cache/claudebar/.retry_at" ;;
        past)   printf '%s' "$(( now - 10 ))"  > "$THOME/.cache/claudebar/.retry_at" ;;
    esac
    OUT=$(run_pinned "$THOME" "$SCRIPT" "$@"); RC=$?
    return 0
}

curl_calls() { cat "$THOME/.curl_count" 2>/dev/null || echo 0; }
_retry_at()  { cat "$THOME/.cache/claudebar/.retry_at" 2>/dev/null || echo 0; }
assert_calls()      { local c; c=$(curl_calls); [[ "$c" == "$2" ]] && _ok "$1" || _no "$1" "curl calls=$c want=$2"; }
assert_no_marker()  { [[ ! -f "$THOME/.cache/claudebar/.retry_at" ]] && _ok "$1" || _no "$1" ".retry_at present: $(_retry_at)"; }
assert_stale()      { [[ -f "$THOME/.cache/claudebar/.stale" ]] && _ok "$1" || _no "$1" ".stale missing"; }
# assert_marker_within <name> <min-seconds-ahead> <max-seconds-ahead>
assert_marker_within() {
    local now ahead; now=$(date +%s); ahead=$(( $(_retry_at) - now ))
    (( ahead >= $2 && ahead <= $3 )) && _ok "$1" || _no "$1" "marker is ${ahead}s ahead, want $2..$3"
}

# --- 429 with the header: marker persisted, wait reported -------------------
STUB_CODE=429 STUB_RETRY_AFTER=990 \
STUB_BODY='{"error":{"type":"rate_limit_error","message":"Rate limited."}}' \
    _run_ra old none
assert_exit0          "429 + header: exit 0"
assert_json_valid     "429 + header: valid JSON"
assert_text_has       "429 + header: shows cached pct" "42%"
assert_text_has       "429 + header: shows the pause mark" ""
assert_stale          "429 + header: .stale persisted"
assert_marker_within  "429 + header: .retry_at ~990s ahead" 960 995
assert_tip_has        "429 + header: tooltip reports the wait" "Retry at"
assert_calls          "429 + header: asked once" 1
rm -rf "$THOME"

# --- A live marker keeps the API untouched ---------------------------------
STUB_CODE=200 STUB_BODY="$FRESH" _run_ra old future
assert_exit0       "live marker: exit 0"
assert_json_valid  "live marker: valid JSON"
assert_text_has    "live marker: serves the cache" "42%"
assert_text_has    "live marker: shows the pause mark" ""
assert_calls       "live marker: did NOT ask" 0
rm -rf "$THOME"

# --- ...and --refresh does not get a free pass ------------------------------
STUB_CODE=200 STUB_BODY="$FRESH" _run_ra old future --refresh
assert_exit0   "live marker + --refresh: exit 0"
assert_calls   "live marker + --refresh: did NOT ask" 0
rm -rf "$THOME"

# --- An expired marker asks again; a 200 clears it -------------------------
STUB_CODE=200 STUB_BODY="$FRESH" _run_ra old past
assert_exit0       "expired marker: exit 0"
assert_text_has    "expired marker: fresh data" "7%"
assert_calls       "expired marker: asked once" 1
assert_no_marker   "expired marker: cleared by the 200"
rm -rf "$THOME"

# --- The header as an HTTP-date --------------------------------------------
# LC_ALL=C on the way IN: an HTTP-date is English by definition (RFC 9110), and
# rendering the fixture through the caller's locale writes a header no server
# ever sends ("mié, 09 sep 2026") and no parser accepts.
STUB_CODE=429 STUB_RETRY_AFTER="$(LC_ALL=C date -u -d '+300 seconds' '+%a, %d %b %Y %H:%M:%S GMT')" \
STUB_BODY='{"error":{"message":"Rate limited."}}' \
    _run_ra old none
assert_marker_within "HTTP-date header: .retry_at ~300s ahead" 280 305
rm -rf "$THOME"

# --- A hostile value is clamped, not honored -------------------------------
STUB_CODE=429 STUB_RETRY_AFTER=999999999 \
STUB_BODY='{"error":{"message":"Rate limited."}}' \
    _run_ra old none
assert_marker_within "absurd header: clamped to 6 h" 21500 21600
rm -rf "$THOME"

# --- No header: the old behavior, untouched --------------------------------
STUB_CODE=429 STUB_BODY='{"error":{"message":"Rate limited."}}' _run_ra old none
assert_exit0      "429 without header: exit 0"
assert_text_has   "429 without header: shows cached pct" "42%"
assert_stale      "429 without header: .stale persisted"
assert_no_marker  "429 without header: no marker written"
rm -rf "$THOME"

# --- Blocked with nothing cached still emits valid JSON, exit 0 ------------
STUB_CODE=200 STUB_BODY="$FRESH" _run_ra none future
assert_exit0      "blocked, no cache: exit 0"
assert_json_valid "blocked, no cache: valid JSON"
assert_tip_has    "blocked, no cache: tooltip explains the wait" "wait until"
assert_calls      "blocked, no cache: did NOT ask" 0
rm -rf "$THOME"

finish
