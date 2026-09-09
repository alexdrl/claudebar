#!/usr/bin/env bash
# --desktop-fallback: the two main percentages from the local history of the
# Claude desktop app when the API cannot answer.
#  - off by default: nothing changes
#  - a sample newer than the cache replaces it, with no pause mark and a footer
#    that names the source
#  - a sample that is not newer, or that is not there, or that is not readable,
#    leaves the old behavior alone
#  - an old sample is used but keeps the pause mark
#  - a 200 from the API always wins
source "$(dirname "$0")/lib.sh"

export CLAUDEBAR_TEST_NET_QUICK_BUDGET=1
export CLAUDEBAR_TEST_NET_LONG_BUDGET=1
export CLAUDEBAR_TEST_NET_RETRY_DELAY=1

CACHED='{"five_hour":{"utilization":99,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":98,"resets_at":"2030-01-01T00:00:00Z"}}'
FRESH_API='{"five_hour":{"utilization":11,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":12,"resets_at":"2030-01-01T00:00:00Z"}}'

# A curl stub that answers $STUB_CODE, or fails when the code is empty.
STUB='#!/usr/bin/env bash
if [[ -z "${STUB_CODE:-}" ]]; then exit 1; fi
printf "%s\n%s" "${STUB_BODY:-}" "$STUB_CODE"
'

# _run_df <cache-age-seconds|none> <sample-age-seconds|none|bad|fifo> [args...]
_run_df() {
    local cache_age="$1" sample="$2"; shift 2
    THOME="$(mktemp -d)" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    mkdir -p "$THOME/.claude" "$THOME/.cache/claudebar" "$THOME/bin" \
             "$THOME/.config/Claude" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '%s' "$STUB" > "$THOME/bin/curl" && chmod +x "$THOME/bin/curl" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    printf '#!/usr/bin/env bash\nexit 0\n' > "$THOME/bin/notify-send" && chmod +x "$THOME/bin/notify-send"
    printf '%s' "$VALID_CREDS" > "$THOME/.claude/.credentials.json" || { echo "HARNESS SETUP FAILED" >&2; exit 1; }
    local now hist; now=$(date +%s)
    hist="$THOME/.config/Claude/plan-usage-history.json"
    if [[ "$cache_age" != "none" ]]; then
        printf '%s' "$CACHED" > "$THOME/.cache/claudebar/usage.json"
        touch -d "@$(( now - cache_age ))" "$THOME/.cache/claudebar/usage.json"
    fi
    case "$sample" in
        none) : ;;
        bad)  printf 'not json at all' > "$hist" ;;
        fifo) mkfifo "$hist" ;;
        *)    printf '{"version":2,"samples":[{"t":%s,"org":"o","u":{"fh":7,"sd":60}},{"t":%s,"org":"o","u":{"fh":16,"sd":69,"xu":19.4}}]}' \
                  "$(( (now - sample - 900) * 1000 ))" "$(( (now - sample) * 1000 ))" > "$hist" ;;
    esac
    OUT=$(run_pinned "$THOME" "$SCRIPT" "$@"); RC=$?
    return 0
}

assert_no_pause() { _plain .text | grep -qF "" && _no "$1" "the pause mark is there: $(_plain .text)" || _ok "$1"; }

# --- Off by default --------------------------------------------------------
_run_df 7200 300
assert_exit0     "off by default: exit 0"
assert_text_has  "off by default: the stale cache" "99%"
assert_text_has  "off by default: keeps the pause mark" ""
rm -rf "$THOME"

# --- A newer sample replaces the cache -------------------------------------
_run_df 7200 300 --desktop-fallback
assert_exit0      "fresh sample: exit 0"
assert_json_valid "fresh sample: valid JSON"
assert_text_has   "fresh sample: the sample, not the cache" "16%"
assert_no_pause   "fresh sample: no pause mark"
assert_tip_has    "fresh sample: the footer names the source" "from the desktop app"
rm -rf "$THOME"

_run_df 7200 300 --desktop-fallback --json
assert_jq_value "fresh sample: not stale in JSON"    '.stale'          'false'
assert_jq_value "fresh sample: no reason in JSON"    '.stale_reason'   'null'
assert_jq_value "fresh sample: session from sample"  '.windows[0].used_pct' '16'
assert_jq_value "fresh sample: weekly from sample"   '.windows[1].used_pct' '69'
assert_jq_value "fresh sample: no reset time"        '.windows[0].reset_at' 'null'
rm -rf "$THOME"

# --- A sample that is not newer than the cache is refused ------------------
_run_df 300 7200 --desktop-fallback
assert_text_has "older sample: the cache stays" "99%"
assert_text_has "older sample: keeps the pause mark" ""
rm -rf "$THOME"

# --- An old sample is used, and says so ------------------------------------
_run_df 10800 7200 --desktop-fallback
assert_text_has "old sample: the sample is used" "16%"
assert_text_has "old sample: keeps the pause mark" ""
assert_tip_has  "old sample: the footer says it is old" "from the desktop app, and old"
rm -rf "$THOME"

# --- No file, or nothing readable in it ------------------------------------
_run_df 7200 none --desktop-fallback
assert_exit0    "no file: exit 0"
assert_text_has "no file: the cache stays" "99%"
rm -rf "$THOME"

_run_df 7200 bad --desktop-fallback
assert_exit0    "malformed file: exit 0"
assert_text_has "malformed file: the cache stays" "99%"
rm -rf "$THOME"

# A FIFO on that path must not park the script: read_bounded opens O_NONBLOCK
# and `[[ -f ]]` is false for a FIFO. The plugin runs inside a long-lived
# process, so a blocking read takes the whole shell with it.
_run_df 7200 fifo --desktop-fallback
assert_exit0    "FIFO: exit 0"
assert_text_has "FIFO: the cache stays" "99%"
rm -rf "$THOME"

# --- A 200 from the API always wins ---------------------------------------
STUB_CODE=200 STUB_BODY="$FRESH_API" _run_df 7200 300 --desktop-fallback
assert_text_has "API answers: the API payload" "11%"
assert_no_pause "API answers: no pause mark"
rm -rf "$THOME"

finish
